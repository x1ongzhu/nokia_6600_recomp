#!/bin/sh
# test_romimage.sh — regression check for the runtime-ROM assembler.
#
# Verifies that:
#   - the flash's packed records are recovered at 2-byte alignment (headers can
#     sit at 2 mod 4), giving the full image map instead of just the kernel's
#     direct DLL references
#   - the ROMFS tree is located (root / \System / \System\Libs / Programs) and
#     ekern.exe maps to the kernel image
#   - every placed section is disjoint (the ROMFS overlays are explicit)
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

NK_BUDGET=200000 NK_MMIO_N=0 NK_CALL_INFER=1 NK_FIXUP_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/romimage_boot.log 2>&1 || true
if grep -q "uid3 0x100058e8" out/romimage_boot.log; then
    echo "ok: flat image kernel located"
else
    echo "FAIL: flat image kernel not located"
    fail=1
fi
if grep -q "unbound IAT=0" out/romimage_boot.log && \
   grep -q "insns=[1-9][0-9][0-9] " out/romimage_boot.log; then
    echo "ok: kernel executes with all imports bound"
else
    echo "FAIL: kernel did not reach the assisted frontier"
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
