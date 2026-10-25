#!/bin/sh
# test_romimage.sh — regression check for the runtime-ROM assembler.
#
# Verifies that:
#   - the flash's packed records are recovered at 2-byte alignment (headers can
#     sit at 2 mod 4), giving the full image map instead of just the kernel's
#     direct DLL references
#   - the ROMFS tree is located (root / \System / \System\Libs / Programs) and
#     ekern.exe maps to the kernel image.  Round 19 corrected the names: the
#     586-entry list below the kernel is \System\Libs (the boot image table),
#     \System\Programs is the 55-entry server list, and the 171-entry
#     AcmClassController list is \System\Libs\Plugins.
#   - every placed section is disjoint (the ROMFS directory block stays linear)
#   - the flat image boots and the kernel's imports are all bound
#
# It does not assert *where* the kernel frontier is: that moves as the ROM
# linker / interworking work progresses.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi

PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi

mkdir -p out
IMG=out/romimage_test.bin
LAYOUT=out/romimage_test.json
LOG=out/romimage_test.log

"$PY" recompiler/romimage.py scan "$ROM" >"$LOG" 2>&1
"$PY" recompiler/romimage.py build "$ROM" "$IMG" --json "$LAYOUT" \
    >>"$LOG" 2>&1
NAMES_LOG=out/romimage_names.log
"$PY" recompiler/romimage.py names "$ROM" --all >"$NAMES_LOG" 2>&1
TREE_LOG=out/romimage_tree.log
"$PY" recompiler/romimage.py tree "$ROM" >"$TREE_LOG" 2>&1

fail=0
check() {
    if grep -q "$1" "$LOG"; then
        echo "ok: $2"
    else
        echo "FAIL: $2"
        fail=1
    fi
}

check "uid3 0x100058e8" "kernel record recovered"
check "uid3 0x100065a5" "first referenced DLL recovered"
check "uid3 0x100039e5" "second referenced DLL recovered"
check "plausible" "2-byte-aligned header scan reported"
check "ekern.exe -> uid3 0x100058e8" "ekern.exe maps to the kernel record"
check "root       file" "packed root directory located"
check "programs   file" "\\System\\Programs directory located"
check "kernel entry 0x50310054" "kernel entry placed"
check "libs       file 0x301f70  586 entries" \
    "full \\System\\Libs directory recovered (586 entries)"
check "programs   file 0x307a14   55 entries" \
    "\\System\\Programs is the 55-entry server list"
if grep -q "Libs\\\\ekern.exe" "$NAMES_LOG"; then
    echo "ok: Libs names include ekern.exe (the ROM header's iPrimaryFile)"
else
    echo "FAIL: Libs names lost ekern.exe"
    fail=1
fi
if grep -q "Libs\\\\EStart.exe" "$NAMES_LOG" && \
   grep -q "Libs\\\\BIGINT.DLL" "$NAMES_LOG"; then
    echo "ok: full Libs image table is present (EStart.exe, BIGINT.DLL)"
else
    echo "FAIL: Libs image table is incomplete"
    fail=1
fi
if grep -q "63 app directories, 63 resolved" "$TREE_LOG"; then
    echo "ok: full \\System\\Apps tree recovered (63/63)"
else
    echo "FAIL: app tree is incomplete"
    fail=1
fi
for app in snakeex mixpix About; do
    if grep -q "  $app " "$TREE_LOG"; then
        echo "ok: app directory $app located"
    else
        echo "FAIL: app directory $app not located"
        fail=1
    fi
done

# Image placement must cover the whole boot set, not just the reachable three.
imgs=$(sed -n 's/.*sections from \([0-9][0-9]*\) images.*/\1/p' "$LOG" | head -1)
if [ -n "$imgs" ] && [ "$imgs" -ge 700 ]; then
    echo "ok: $imgs packed images placed"
else
    echo "FAIL: expected >= 700 placed images (got '$imgs')"
    fail=1
fi

# The flat image must be exactly the declared 22 MiB.
size=$(wc -c <"$IMG" | tr -d ' ')
if [ "$size" = "23068672" ]; then
    echo "ok: runtime image is 0x1600000 bytes"
else
    echo "FAIL: runtime image is $size bytes (want 23068672)"
    fail=1
fi

# The app E32Image files must be copied whole from their packed file records.
"$PY" - "$LAYOUT" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
secs = {s["name"]: s for s in d["placed"]}
for name, va, size in (("romfs_e32_SnakeEx.app", 0x5147f060, 0x7ddc),
                       ("romfs_e32_mixpix.app", 0x514ace40, 0xd718),
                       ("romfs_data_About.aif", 0x50a209c0, 0x27c),
                       ("romfs_data_About.mbm", 0x50a20c40, 0xcf8)):
    s = secs.get(name)
    if not s:
        print(f"FAIL: {name} not placed")
        sys.exit(1)
    if s["va"] != va or s["size"] != size:
        print(f"FAIL: {name} at {s['va']:#x}+{s['size']:#x}, want {va:#x}+{size:#x}")
        sys.exit(1)
print("ok: SnakeEx.app and mixpix.app placed at their runtime addresses")
EOF
check "ROMFS app companions: 85 AIF/MBM files placed" \
    "app AIF/MBM companions placed"

# No two non-overlay placed sections may overlap.
"$PY" - "$LAYOUT" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
secs = sorted((s["va"], s["va"] + s["size"], s["name"]) for s in d["placed"]
              if not s.get("overlay"))
bad = [(a, b) for a, b in zip(secs, secs[1:]) if b[0] < a[1]]
if bad:
    print("FAIL: overlapping sections:", bad[:4])
    sys.exit(1)
over = sum(1 for s in d["placed"] if s.get("overlay"))
print(f"ok: {len(secs)} placed sections do not overlap ({over} ROMFS overlays)")
EOF

# Boot the flat image; the kernel's imports must all bind.
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_KERNEL_VECTORS=1 NK_BUDGET=1000000 NK_MMIO_N=0 NK_CALL_INFER=0 \
NK_RECOVER=0 NK_FIXUP_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/romimage_boot.log 2>&1 || true
if grep -q "uid3 0x100058e8" out/romimage_boot.log; then
    echo "ok: flat image kernel located"
else
    echo "FAIL: flat image kernel not located"
    fail=1
fi
insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/romimage_boot.log)
if grep -q "unbound IAT=0" out/romimage_boot.log && \
   [ -n "$insns" ] && [ "$insns" -ge 900000 ]; then
    echo "ok: real kernel entry executes ($insns instructions, imports bound)"
else
    echo "FAIL: kernel did not reach the real boot frontier"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "--- $LOG ---"
    sed -n '1,40p' "$LOG"
    echo "--- out/romimage_boot.log ---"
    tail -20 out/romimage_boot.log
    exit 1
fi
echo "runtime ROM image test OK"
