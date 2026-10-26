#!/bin/sh
# test_round38.sh - direct FbServ startup, and the Thumb-entry CPSR fix.
#
# The kernel path is still blocked at RThread::Resume(0x32).  As an
# alternative route to the first frame, this harness can start the original
# FbServ.exe entry directly in the flat image.  FbServ is Thumb code at
# 0x506897d5, but NK_CPSR=0x40000053 used to clear the T bit, so the
# interpreter decoded the prologue as ARM and only recovered mid-function.
# The entry mode is now authoritative: a Thumb NK_ENTRY forces CPSR.T.
#
# With that fix FbServ runs 3,612 instructions and reaches its object
# initialization at 0x5068a572.  The object 0x80600018 has vtable
# 0x50680000 and [vtable+8] = 0x068a0689, so the indirect call leaves the
# image at 0x068a0688.  That is the next blocker: the app's constructors /
# DLL imports are not initialized by the direct-entry path.
#
# Acceptance:
#   - entry override reports Thumb;
#   - cpsr override is 0x40000073 (T=1) even though NK_CPSR was 0x40000053;
#   - FbServ executes 3,612 instructions, 0 undefined, 0 unbound IAT;
#   - stop is a PC escape at 0x068a0688 with lr=0x5068a57f.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 38: direct FbServ startup (Thumb entry)"
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
    NK_B7E_VALID_HI=0x80a00000 NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round38_fbserv.log 2>&1

grep -q "entry override: 0x506897d5 (Thumb)" out/round38_fbserv.log
grep -q "cpsr override: 0x40000073 (Thumb entry)" out/round38_fbserv.log
grep -q "^--- stop: budget (0) at 0x5038d658 ---" \
    out/round38_fbserv.log
grep -q "insns=500000" out/round38_fbserv.log
grep -q "undefined=0" out/round38_fbserv.log
grep -q "unbound IAT=0" out/round38_fbserv.log
grep -q "recoveries=0" out/round38_fbserv.log

echo "ok: a Thumb NK_ENTRY keeps CPSR.T even when NK_CPSR omits it"
echo "ok: FbServ starts at 0x506897d5 and runs the full 500,000-insn budget"
echo "ok: the early vtable escape is gone after the B7e hook-order fix"
echo "ok: the new direct-path frontier is a wild 0x600000 clear (budget stop"
echo "    at 0x5038d658); the real-SVC path is the next acceptance test"
echo "PASS: round 38 direct FbServ now reaches the 500k budget"
