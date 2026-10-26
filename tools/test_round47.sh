#!/bin/sh
# test_round47.sh - stable SplashScreen run after the EwSrv export snap.
#
# SplashScreen's call into EwSrv uses export slot 0x506ce7d0.  The ROM build
# stores 0x506cbf1d, two bytes before the real Thumb prologue at 0x506cbf1e,
# so the first halfword is undefined.  NK_EWSRV_SNAP=1 applies the same kind
# of export fixup the E32 loader uses (Thumb +2).
#
# With the snap, SplashScreen runs the full 2,000,000-instruction budget with
# 0 undefined/unbound/recoveries.  It ends in the request-semaphore Wait
# service (0x503244e4 -> 0x503244f4), waiting for a client/message, not on a
# CPU fault or a bad EwSrv pointer.
#
# Acceptance:
#   - "EwSrv export snap: 0x506cbf1d -> 0x506cbf1f";
#   - stop budget at 0x503244f4, insns=2000000;
#   - 0 undefined / 0 unbound IAT / 0 recoveries;
#   - the final chain is the WaitForAnyRequest service.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 47: stable SplashScreen"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 NK_RECOVER=0 \
    NK_CALL_INFER=0 NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x509eee85 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round47_splash.log 2>&1

grep -q "EwSrv export snap: 0x506cbf1d -> 0x506cbf1f" out/round47_splash.log
grep -q "^--- stop: budget (0) at 0x503244f4 ---" out/round47_splash.log
grep -q "insns=2000000" out/round47_splash.log
grep -q "undefined=0" out/round47_splash.log
grep -q "unbound IAT=0" out/round47_splash.log
grep -q "recoveries=0" out/round47_splash.log
grep -q "503244e4 503244e8 50321c18 50321c1c 50321c20 503244ec 503244f0" \
    out/round47_splash.log

echo "ok: the EwSrv export is snapped from 0x506cbf1d to the Thumb prologue"
echo "ok: SplashScreen runs the full 2,000,000-instruction budget with no"
echo "    undefined/unbound/recovery"
echo "ok: it waits in the request-semaphore service (0x503244e4..f4), not on"
echo "    a bad EwSrv pointer"
echo "PASS: round 47 stabilises the splash-screen run"
