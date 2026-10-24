#!/bin/sh
# test_bootbank.sh — verify the linked boot-bank reconstruction.
#
# The first 64 KiB of the flash is the UPP secondary boot bank.  It is stored
# as fragments that were linked for different bases, so the verbatim flash copy
# hands the loader an absolute address that lands 0xb0 bytes below the function
# it belongs to.  recompiler/bootbank.py measures the fragment biases from the
# compiler's switch tables (and from the mask-ROM `sub r1, pc, #...` anchor)
# and rebuilds the linked view.
#
# Acceptance:
#   - the image base probe decodes to 0xb0
#   - all 7 switches in fragment A measure 0xb0, all 8 in B ~0x19c
#   - the linked view runs 600k instructions with ZERO recoveries, while the
#     verbatim bank needs 9 stale-call recoveries and loops at 0x125c
#   - the linked run reaches the image-loader thread at 0x1244 and the first
#     real UPP write (0x08000008 = 0x37)
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

# The linked low view is booted on top of the flat runtime image.
IMG=out/6600_runtime.bin
if [ ! -f "$IMG" ] || [ "$ROM" -nt "$IMG" ]; then
    tools/build_rom_image.sh "$ROM" "$IMG" >out/bootbank_romimage.log 2>&1
fi

"$PY" recompiler/bootbank.py analyze "$ROM" >out/bootbank_analyze.log
"$PY" recompiler/bootbank.py verify "$ROM" >out/bootbank_verify.log
"$PY" recompiler/bootbank.py build "$ROM" out/6600_bootbank_linked.bin \
    >out/bootbank_build.log

clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

fail=0
check() {
    if grep -q "$1" "$2"; then echo "ok: $3"; else echo "FAIL: $3"; fail=1; fi
}

check "reloc addend (0x3b0): 0xb0" out/bootbank_analyze.log \
    "the 0x3b0 helper adds the 0xb0 relocation addend"
check "B bias: 0x19c" out/bootbank_analyze.log \
    "fragment B switch tables measure bias 0x19c"
check "0x6b14" out/bootbank_analyze.log \
    "provisional fragment C is reported (bias 0x374)"

# The linked view: the real boot path, no call repair needed.
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  NK_WATCH=0x1244 NK_WATCH_HITS=1 NK_WATCH_LOG=1 \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
  >out/bootbank_linked.log 2>&1 || true

check "recoveries=0" out/bootbank_linked.log \
    "the linked view needs no stale-call recovery"
check "undefined=0" out/bootbank_linked.log "no undefined instruction"
check "insns=600000" out/bootbank_linked.log \
    "the loader runs the full 600k-instruction budget"
check "write 0x08000008 = 0x37" out/bootbank_linked.log \
    "reaches the first UPP register write"
check "pc=0x00001244" out/bootbank_linked.log \
    "the image-loader thread runs at linked 0x1244"
check "stop: budget (0) at 0x00001a1c" out/bootbank_linked.log \
    "the new frontier is the descriptor lookup loop"

# Negative control: the verbatim bank trips over the biased absolute calls.
NK_LOW_ROM=1 NK_ENTRY=0x3bc NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=400000 \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
  >out/bootbank_raw.log 2>&1 || true

check "recoveries=9" out/bootbank_raw.log \
    "the verbatim bank still needs 9 recoveries (control)"
check "stop: budget (0) at 0x0000125c" out/bootbank_raw.log \
    "the verbatim bank loops inside the switch table (control)"

if [ "$fail" -ne 0 ]; then
    echo "boot-bank test FAILED"
    exit 1
fi
echo "boot-bank reconstruction test OK"
