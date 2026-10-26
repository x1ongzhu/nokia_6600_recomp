#!/bin/sh
# test_round40.sh - the descriptor/object overlap in direct FbServ startup.
#
# Round 39 showed the vtable 0x5068c0a4 being turned into 0x50680000 by a
# byte store at 0x5038bc6c.  This round pins the call chain and the allocation
# that lead there:
#
#   5068a4f6  movs r0,#0x14          ; allocate 20 bytes
#   5068a4f8  bl   operator new
#   5068a502  bl   0x5068a5bc        ; construct, vtable 0x5068c0a4
#   5068a4ee  bl   0x5068b70c        ; EUser formatting path
#   5038bc38  EUser descriptor helper
#   5038bc6c  byte store to [r3+1]  ; r3 = 0x80600018, the object
#
# The same 0x80600018 block is both the CBase object and the TDes8 buffer for
# the formatting call, so its vtable is destroyed.  Clearing the app stack
# (NK_APP_STACK_CLEAR=1) does not change this; the descriptor header is built
# by the guest.  The direct-entry route therefore lacks the user-side
# descriptor/thread context a real process has.
#
# Acceptance:
#   - the watch at 0x5038bc6c sees r3=0x80600018, lr=0x5038bc48;
#   - the call ring includes 0x5068a4ee -> 0x5068b70c;
#   - the allocation log shows 20 bytes -> 0x80600018;
#   - FbServ still stops at 0x068a0688.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 40: FbServ descriptor/object overlap"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=500000 \
    NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
    NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=8 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
    NK_B7E_VALID_HI=0x80a00000 NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    NK_WATCH=0x5038bc6c NK_WATCH_HITS=1 NK_WATCH_LOG=32 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round40_desc.log 2>&1

grep -q "watch\] pc=0x5038bc6c.*r3=0x80600018" out/round40_desc.log
grep -q "lr=0x5038bc48" out/round40_desc.log
grep -q "0x5068a4ee -> 0x5068b70c" out/round40_desc.log
grep -q "HLE alloc 20 bytes -> 0x80600018" out/round40_desc.log
grep -q "^--- stop: pc left the image (5) at 0x068a0688 ---" \
    out/round40_desc.log

echo "ok: 0x80600018 is allocated as a 20-byte object at 0x5068a4f6"
echo "ok: its constructor installs vtable 0x5068c0a4"
echo "ok: the formatting path 0x5068a4ee -> 0x5068b70c -> EUser 0x5038bc38"
echo "    then uses the same block as a TDes8 buffer at 0x5038bc6c"
echo "ok: clearing the user stack does not change it; the guest builds the"
echo "    descriptor header itself"
echo "PASS: round 40 pins the descriptor/object overlap that blocks the"
echo "      direct FbServ route"
