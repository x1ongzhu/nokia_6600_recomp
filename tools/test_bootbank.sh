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
# Acceptance (legacy raw-fragment view; kept as a regression):
#   - the image base probe decodes to 0xb0
#   - all 7 switches in fragment A measure 0xb0, all 8 in B ~0x19c
#   - the linked view runs 600k instructions with ZERO recoveries, while the
#     verbatim bank loops in the 0x1244/0x1254 switch table (it needed 9
#     stale-call recoveries on the old flat image)
#   - the linked run reaches the image-loader thread at 0x1244 and the first
#     real UPP write (0x08000008 = 0x37)
#
# Round 16 adds the page-header-free stream view (`--stream`): linked 0 is
# stream 0xb0, all switch tables bias 0, and the loader follows the real
# call path to a board/CPU detection panic at 0x624c.  The old 600k run used
# the raw B2 page header as code and is therefore not the linked path.
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

# The exact recoveries depend on which code ranges the flat image exposes;
# what matters is that the verbatim bank loops inside the 0x1244/0x1254
# switch table instead of following the loader.  (The old build needed 9
# recoveries at 0x125c; the page-header-free image resolves the stale calls
# differently but still loops.)
check "stop: budget (0) at 0x00001254" out/bootbank_raw.log \
    "the verbatim bank loops inside the switch table (control)"

# --- round 16: the page-header-free stream view ---------------------------
# Removing the 0xec-byte page headers makes the boot bank contiguous at linked
# 0 (stream 0xb0) and every switch table measures bias 0.  The loader no
# longer needs the A/B/C relocation heuristics.  On this *correct* view it
# reaches a board/CPU detection panic at linked 0x624c after ~2.1k
# instructions; the old 600k raw-fragment run was the B2 page header shifting
# the call path, not the linked code.
"$PY" recompiler/bootbank.py verify "$ROM" --stream >out/bootbank_stream_verify.log
"$PY" recompiler/bootbank.py build "$ROM" out/6600_bootbank_stream.bin \
    --stream >out/bootbank_stream_build.log
check "all linked switch tables measure bias 0" out/bootbank_stream_verify.log \
    "stream boot-bank switch tables are already linked"
check "linked loader hands off descriptor 0x80" out/bootbank_stream_verify.log \
    "stream loader descriptor is linked 0x80"

NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_stream.bin \
  NK_REGIONS=out/6600_bootregions_linear.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=10000 NK_MMIO_N=0 \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
  >out/bootbank_stream.log 2>&1 || true

check "undefined=0" out/bootbank_stream.log \
    "stream view has no undefined instruction before the board check"
check "stop: self-branch (panic halt) (7) at 0x0000624c" out/bootbank_stream.log \
    "stream view reaches the real board/CPU detection panic at 0x624c"
check "insns=2111" out/bootbank_stream.log \
    "stream view follows the linked call path (2111 instructions)"

if [ "$fail" -ne 0 ]; then
    echo "boot-bank test FAILED"
    exit 1
fi
echo "boot-bank reconstruction test OK (legacy fragment + stream views)"
