#!/bin/sh
# test_round48.sh - the two remaining splash/window-server blockers.
#
# 1. SplashScreen's wait can be made to return with NK_WAIT_HLE=1: the
#    semaphore-Wait stub completes [r5] and returns 0.  The app then leaves
#    WaitForAnyRequest and reaches the next real blocker.  Historical note:
#    before round 62 this path entered a wild descriptor copy at 0x5038d2d4
#    with a 0x484c4289 length; round 62 showed that length came from the HLE
#    allocator's private 'HLEH' cell header, not from the window server.  With
#    the header fixed, the same run reaches EwSrv's unrelocated jump-table
#    target at 0x506ca5e4 and null-calls.  That is the current app frontier.
#
# 2. Running EwSrv.exe directly (entry 0x506a8205) null-calls at
#    pc=0, lr=0x506c0b15 after a handful of instructions, so EwSrv's own
#    imports/vtables are not initialised either.
#
# Acceptance:
#   - SplashScreen + NK_WAIT_HLE leaves the wait, reaches EwSrv 0x506ca5e4,
#     and stops on a null call at 0 with lr=0x509ef1e9;
#   - EwSrv direct stops on a null call at 0 with lr=0x506c0b15.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 48: splash wait and window-server blockers"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

common() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_RECOVER=0 \
        NK_CALL_INFER=0 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
        NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
        NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
        NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
        NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
        NK_BANKED=1 "$@"
}

common NK_BUDGET=5000000 NK_EWSRV_SNAP=1 NK_WAIT_HLE=1 \
    NK_ENTRY=0x509eee85 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round48_wait.log 2>&1
grep -q "EwSrv export snap" out/round48_wait.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round48_wait.log
grep -q "undefined=0" out/round48_wait.log
grep -q "506ca5e4 506ca5e4 506ca5e8" out/round48_wait.log
grep -q "lr=0x509ef1e9" out/round48_wait.log
if grep -q "5038d2d4 5038d2d8 5038d2dc" out/round48_wait.log; then
    echo "FAIL: the round-48 wild descriptor copy reappeared" >&2
    exit 1
fi

common NK_BUDGET=2000000 NK_ENTRY=0x506a8205 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round48_ewsrv.log 2>&1
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round48_ewsrv.log
grep -q "lr=0x506c0b15" out/round48_ewsrv.log

echo "ok: NK_WAIT_HLE leaves WaitForAnyRequest; with the round-62 allocator"
echo "    header the old 0x5038d2d4 wild copy is gone and the app reaches the"
echo "    EwSrv jump table at 0x506ca5e4"
echo "ok: direct EwSrv.exe null-calls at 0x506c0b15; its imports/vtables are"
echo "    not initialised either"
echo "PASS: round 48 pins the splash wait and the current EwSrv app frontier"
