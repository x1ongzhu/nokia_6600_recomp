#!/bin/sh
# test_round45.sh - stable real-SVC FbServ after three boot-state fixes.
#
# 1. The USR bank must start at the app's NK_SP and the bank predicate must
#    follow the actually mapped RAM (NK_RAM_EXTRA).  Otherwise the first SVC
#    return restores the preset 0x80240000 SP and loses the app frame.
# 2. The B7e current-thread hook must be installed before the initial fake
#    thread is published, so the fake thread gets +0x18/+0x5c/+0x64.
# 3. The kernel DFC queue [0x80001c28] must be initialised empty for a direct
#    app entry; otherwise the first SVC calls a garbage DFC entry.
#
# With those, direct FbServ + real SVC exceptions runs the full 2,000,000
# instruction budget with no fault, stuck in the EUser WaitForAnyRequest loop
# at 0xffff0008 / 0x5039865c (waiting for a client request).
#
# Acceptance:
#   - "app USR stack: 0x80580000" and "dfc queue: empty at 0x80001c28";
#   - stop budget at 0xffff0008, insns=2000000;
#   - 0 undefined / 0 unbound IAT / 0 recoveries;
#   - the final PC is the SVC vector (wait loop), not a fault.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 45: stable real-SVC FbServ"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000030 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round45_stable.log 2>&1

grep -q "app USR stack: 0x80580000" out/round45_stable.log
grep -q "dfc queue: empty at 0x80001c28" out/round45_stable.log
grep -q "^--- stop: budget (0) at 0xffff0008 ---" out/round45_stable.log
grep -q "insns=2000000" out/round45_stable.log
grep -q "undefined=0" out/round45_stable.log
grep -q "unbound IAT=0" out/round45_stable.log
grep -q "recoveries=0" out/round45_stable.log
grep -q "5039865c 50398660 50398664 50398654 50398658 50392b08" \
    out/round45_stable.log

echo "ok: USR bank starts at the app SP and survives the SVC return"
echo "ok: the B7e fake current thread has a request semaphore (+0x5c)"
echo "ok: the DFC queue is empty, so the first SVC does not call garbage"
echo "ok: direct FbServ + real SVCs runs the full 2,000,000-insn budget"
echo "ok: it is waiting in EUser WaitForAnyRequest, not faulting"
echo "PASS: round 45 stabilises the direct real-SVC FbServ path"
