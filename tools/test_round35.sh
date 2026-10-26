#!/bin/sh
# test_round35.sh - let the thread-start hand-off return before preempting,
# and pin the remaining Init2 deadlock.
#
# Round 34 reached a stable 6M-instruction run, but the 2M scheduler dump showed
# a deadlock: the supervisor was blocked at 0x50330a98 with its TRequestStatus
# still KRequestPending (0x80000001), while the NULL thread ran Kern::Init3 and
# never performed another start hand-off.  The reason was the switch itself:
# sched_yield_hook preempted the NULL thread at 0x503183bc, i.e. *inside* the
# hand-off, before it returned through 0x5033130c.  The supervisor's next
# request was therefore never consumed.
#
# NK_SCHED_DEFER=1 holds the preemption until the hand-off reaches its return
# site 0x5033130c (or 2000 instructions elapse).  The hand-off now completes
# and the supervisor runs ~20k more instructions between blocks (460k vs 442k).
# The remaining deadlock is precise: the supervisor's final wait at 464,336 is
# pending, the NULL thread is running its Init3 timing loop, and only two
# DThread objects exist (supervisor 0x80601078, NULL 0x80601830).  The missing
# piece is the handle-0x32 thread-start completion / DFC thread, not a CPU
# fault.
#
# Acceptance:
#   - control (no defer): switch #3 resumes the NULL thread at 0x503183bc
#     (frozen mid-hand-off), the round-34 frontier;
#   - defer: switch #3 resumes at 0x5033130c and the hand-off returns;
#   - both runs reach the 6M budget with no undefined instruction, no unbound
#     IAT, no recoveries and 14 timer IRQs;
#   - the final sched-slot dump pins the deadlock: supervisor state=3 with
#     status value 0x80000001, NULL thread state=2.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 35: hand-off completion and the Init3 deadlock"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_boot() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
        NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=6000000 \
        NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
        NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
        NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
        NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
        NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
        NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 "$@"
}

echo "== round 35 control: no defer (round-34 mid-hand-off switch)"
run_boot NK_SCHED_LOG=12 ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round35_base.log 2>&1
grep -q "switch #3 -> thread 0x80601830 pc 0x503183bc" out/round35_base.log
grep -q "^--- stop: budget (0) at 0x5032211c ---" out/round35_base.log
base_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round35_base.log)
if [ "$base_insns" != "5999982" ]; then
    echo "FAIL: control stopped at ${base_insns:-0} insns, expected 5999982" >&2
    tail -40 out/round35_base.log >&2
    exit 1
fi

echo "== round 35: defer preemption until the hand-off returns"
run_boot NK_SCHED_DEFER=1 NK_SCHED_LOG=24 ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round35_defer.log 2>&1

grep -q "switch #3 -> thread 0x80601830 pc 0x5033130c" out/round35_defer.log
grep -q "supervisor status 0x802fff8c completed; runnable again" \
    out/round35_defer.log
if grep -q "null call\|panic halt\|pc left the image" out/round35_defer.log; then
    echo "FAIL: deferred run faults" >&2
    tail -40 out/round35_defer.log >&2
    exit 1
fi
grep -q "^--- stop: budget (0) at 0x50312720 ---" out/round35_defer.log
grep -q "undefined=0" out/round35_defer.log
grep -q "unbound IAT=0" out/round35_defer.log
grep -q "recoveries=0" out/round35_defer.log
grep -q "sched slots: pending-slot=0x802fff8c" out/round35_defer.log
grep -q "\[0x80601078 state=3 status=0x802fff8c" out/round35_defer.log
grep -q "val=0x80000001\]" out/round35_defer.log
grep -q "\[0x80601830 state=2" out/round35_defer.log

defer_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round35_defer.log)
irqs=$(sed -n 's/.*irqs=\([0-9][0-9]*\).*/\1/p' out/round35_defer.log)
if [ -z "$defer_insns" ] || [ "$defer_insns" != "5999983" ]; then
    echo "FAIL: deferred run stopped at ${defer_insns:-0} insns, expected 5999982" >&2
    tail -40 out/round35_defer.log >&2
    exit 1
fi
if [ -z "$irqs" ] || [ "$irqs" -lt 14 ]; then
    echo "FAIL: deferred run took only ${irqs:-0} timer IRQs" >&2
    exit 1
fi

echo "ok: control still freezes the NULL thread at 0x503183bc mid-hand-off"
echo "ok: defer lets the hand-off reach its return site 0x5033130c, so the"
echo "    guest's start bookkeeping runs to completion"
echo "ok: the supervisor runs ~20k instructions further between switches"
echo "    (460,289 vs 441,434) before its next wait"
echo "ok: both runs reach the 6M budget with 14 timer IRQs, 0 undefined,"
echo "    0 unbound IAT and 0 recoveries"
echo "ok: the final sched slots pin the remaining deadlock: supervisor blocked"
echo "    with status 0x80000001, NULL thread running Init3 (0x5032211c loop)"
echo "PASS: round 35 makes the hand-off completion faithful and isolates the"
echo "      next blocker to the handle-0x32 thread-start / DFC path"
