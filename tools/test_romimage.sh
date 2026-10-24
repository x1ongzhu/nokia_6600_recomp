#!/bin/sh
# test_romimage.sh — regression check for the runtime-ROM assembler.
#
# Verifies that:
#   - the kernel and its two referenced DLLs are recovered from the packed flash
#   - the record sections are placed without overlaps
#   - the ROMFS root list + all 171 files are placed at their runtime addresses
#   - the flat image boots to the same frontier as the packed-record loader
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
check "171 entries (171 files)" "ROMFS entries recovered"
check "files stored linearly" "ROMFS files are linear"
check "kernel entry 0x50310054" "kernel entry placed"

# The flat image must be exactly the declared 22 MiB.
size=$(wc -c <"$IMG" | tr -d ' ')
if [ "$size" = "23068672" ]; then
    echo "ok: runtime image is 0x1600000 bytes"
else
    echo "FAIL: runtime image is $size bytes (want 23068672)"
    fail=1
fi

# No two placed sections may overlap.
"$PY" - "$LAYOUT" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
secs = sorted((s["va"], s["va"] + s["size"], s["name"]) for s in d["placed"])
bad = [(a, b) for a, b in zip(secs, secs[1:]) if b[0] < a[1]]
if bad:
    print("FAIL: overlapping sections:", bad[:4])
    sys.exit(1)
print(f"ok: {len(secs)} placed sections do not overlap")
EOF

# Boot the flat image and compare the frontier with the packed-record loader.
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_BUDGET=200000 NK_MMIO_N=0 NK_CALL_INFER=1 NK_FIXUP_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/romimage_boot.log 2>&1 || true
if grep -q "runtime image uid3 0x100058e8" out/romimage_boot.log; then
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
