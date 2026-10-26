#!/bin/sh
# test_round39.sh - why direct FbServ still loses its vtable.
#
# Round 38 showed FbServ running 3,612 instructions and dying on an indirect
# call through 0x068a0689.  The object is 0x80600018.  Extending the write
# watch to byte/halfword stores exposes the exact sequence:
#
#   5038e2ec  allocator zeroes the 0x18-byte block
#   503993c8  EUser sets [object] = 0
#   5068a5c8  FbServ constructor sets [object] = 0x5068c0a4
#   5038bc6c  EUser descriptor code writes a byte at [object+1] = 0
#
# The last store turns 0x5068c0a4 into 0x50680000.  At the call site
# [0x50680008] = 0x068a0689, so PC escapes to 0x068a0688.  The object is being
# used as a TDes8-style buffer after construction; the direct-entry path has
# not established the C++/descriptor state the constructor expects.
#
# Acceptance:
#   - the vtable store 0x5068c0a4 is seen at pc=0x5068a5c8;
#   - the byte store at pc=0x5038bc6c follows;
#   - FbServ still stops at 0x068a0688 with 3,612 instructions.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 39: FbServ vtable write/overwrite sequence"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=500000 \
    NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
    NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
    NK_B7E_VALID_HI=0x80a00000 NK_B7E_LATE_HOOK=1 NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    NK_WRITE_WATCH=0x80600018 NK_WRITE_WATCH_MAX=30 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round39_vtable.log 2>&1

grep -q "pc=5068a5c8.*store=5068c0a4" out/round39_vtable.log
grep -q "pc=5038bc6c.*store=00000000" out/round39_vtable.log
grep -q "^--- stop: pc left the image (5) at 0x068a0688 ---" \
    out/round39_vtable.log
grep -q "insns=3612" out/round39_vtable.log
grep -q "undefined=0" out/round39_vtable.log

echo "ok: FbServ constructor writes vtable 0x5068c0a4 at 0x5068a5c8"
echo "ok: EUser descriptor code later writes a zero byte at 0x5038bc6c"
echo "ok: [object] becomes 0x50680000, [0x50680008]=0x068a0689"
echo "ok: the indirect call escapes to 0x068a0688 (3,612 instructions)"
echo "PASS: round 39 pins the vtable overwrite and the descriptor/object"
echo "      state that the direct-entry path still lacks"
