#!/bin/sh
# test_relayout.sh — acceptance test for the literal-pool relayout.
#
# The round-5 finding was that the packed kernel text is missing the ROM
# linker's 2-byte alignment padding.  `recompiler/relayout.py` reconstructs
# the final layout by aligning every literal pool and function start to 4
# bytes.  This test checks the two known cases (the kernel entry pool and the
# Thumb helper at 0x50312100) and then boots an experimental flat image built
# from the relaid text.
#
# Expected on the current image:
#   - entry ldr at packed 0x50310070 lands on 0x50310090 and reads 0x00046564
#   - all literal pools are 4-byte aligned after the plan
#   - the boot trace executes >250 instructions (the faithful image: 197)
#   - no undefined instruction
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
IMG=out/6600_runtime.bin
if [ ! -f "$IMG" ] || [ "$ROM" -nt "$IMG" ]; then
    tools/build_rom_image.sh "$ROM" "$IMG" >out/relayout_rom_build.log 2>&1
fi

# 1. analyse: the entry pool must move to 0x50310090.
$PY recompiler/relayout.py analyze "$ROM" --json out/6600_relayout.json \
    >out/relayout_analyze.log 2>&1
if ! grep -q "entry pool -> 0x50310090" out/relayout_analyze.log; then
    echo "FAIL: entry pool not aligned to 0x50310090"
    cat out/relayout_analyze.log
    exit 1
fi
if ! grep -q "pools aligned after plan: .*/" out/relayout_analyze.log; then
    echo "FAIL: pool alignment summary missing"
    cat out/relayout_analyze.log
    exit 1
fi
align=$(sed -n 's/.*pools aligned after plan: \([0-9]*\)\/\([0-9]*\).*/\1 \2/p' out/relayout_analyze.log)
set -- $align
if [ "$1" != "$2" ]; then
    echo "FAIL: only $1/$2 literal pools aligned"
    cat out/relayout_analyze.log
    exit 1
fi

# 2. text-only build + verify (entry literal, next function alignment).
$PY recompiler/relayout.py build "$ROM" out/6600_kernel_relaid.bin \
    >out/relayout_build.log 2>&1
$PY recompiler/relayout.py verify "$ROM" out/6600_kernel_relaid.bin \
    >out/relayout_verify.log 2>&1 || {
    echo "FAIL: relayout verify"
    cat out/relayout_verify.log
    exit 1
}

# 3. experimental flat image: relaid kernel text, kernel .data moved into the
#    free gap before the first ROMFS file.
$PY recompiler/relayout.py image "$ROM" "$IMG" out/6600_runtime_relaid.bin \
    >out/relayout_image.log 2>&1

clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_BUDGET=${NK_BUDGET:-2000000} \
NK_RECOVER=1 NK_RECOVER_LOG=${NK_RECOVER_LOG:-24} NK_RECOVER_MAX=200 \
NK_CALL_INFER=1 NK_SNAP_WINDOW_ARM=${NK_SNAP_WINDOW_ARM:-0x200} \
NK_SNAP_WINDOW_THUMB=${NK_SNAP_WINDOW_THUMB:-0x400} \
NK_SPIN=1 NK_SPIN_MAX=${NK_SPIN_MAX:-20000} NK_CODE_ONLY=1 \
NK_CALLMAP=config/callmap-6600.txt NK_MMIO_N=${NK_MMIO_N:-24} \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime_relaid.bin >out/relayout_boot.log 2>&1 || true

if grep -q "undefined instruction" out/relayout_boot.log; then
    echo "FAIL: undefined instruction reached"
    grep -n "undefined" out/relayout_boot.log | head -5
    exit 1
fi

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/relayout_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 250 ]; then
    echo "FAIL: only $insns instructions (want >= 250; faithful image is 197)"
    tail -20 out/relayout_boot.log
    exit 1
fi
if ! grep -q -- "--- stop: returned" out/relayout_boot.log; then
    echo "FAIL: kernel entry did not return through the mask-ROM stand-in"
    tail -20 out/relayout_boot.log
    exit 1
fi

echo "ok: entry pool 0x5031008e -> 0x50310090, literal 0x00046564"
echo "ok: $1/$2 literal pools 4-byte aligned after relayout"
echo "ok: relaid boot $insns instructions, no undefined instruction"
grep -E "mmio:|last pcs" out/relayout_boot.log | tail -4
echo "relayout test OK"
