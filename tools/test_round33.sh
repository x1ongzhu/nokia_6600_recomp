#!/bin/sh
# test_round33.sh - first scheduler switch: the NULL thread runs and the
# kernel-start wait returns.
#
# Round 32 stopped at Kern::Init2's first blocking executive call:
#   [0x80001784] = &TRequestStatus (KRequestPending)
#   EUser K=1208 -> 0x50398644 -> svc #0x4d
#   [sp] still pending -> KERN 6 panic @ 0x50330aa8
#
# Round 33 re-reads that path:
#   - kernel service table[0x4d] = 0x503244e4 calls
#     current_thread->[0x5c]->vtable[0x20]; [thread+0x5c] is the request
#     semaphore created by 0x503311c8 (constructor 0x50320ac0), so the call is
#     WaitForAnyRequest, not "complete the request";
#   - 0x503309e4 (Init2) created the NULL thread at 0x5032fa10: object
#     0x80601830, entry 0x5031f144 (literal 0x5032faf4), 0x2000-byte stack;
#   - DThread vtable+0x20 (0x50321088) -> 0x50318398 completes the pending
#     start request and publishes the new current thread.  The NULL thread
#     itself runs that hand-off once the scheduler starts it.
#
# The harness model (NK_SCHED=1):
#   - blocks the supervisor at the Init2 wait (LR 0x50330a98) instead of
#     completing the SWI inline;
#   - saves/restores a full context per thread (r0-r15, CPSR and the
#     interpreter's shadow call stack);
#   - starts the NULL thread on the harness stack at its real entry 0x5031f144;
#   - re-arms [0x80001784] with a pending hand-off status so the guest
#     0x50318398 path runs for every Kern::StartThread (svc #0x76) call;
#   - preempts the NULL thread back to the supervisor as soon as the hand-off
#     wakes it (the higher-priority thread).
#
# Acceptance:
#   - control (no NK_SCHED): the round-32 KERN 6 panic at 0x50312b88;
#   - NK_SCHED: WaitForAnyRequest blocks, the first switch starts the NULL
#     thread at 0x5031f144, the start hand-off completes the request, the
#     supervisor resumes at 0x50330a98 and KERN 6 does not happen.  The new
#     frontier is a null call in the multi-thread CObjectIx/B7e path at
#     0x503360d4 (440,623 insns).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 33: first scheduler switch"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_boot() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
        NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=3000000 \
        NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 \
        NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
        NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
        NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
        NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
        NK_B7E_VALID_HI=0x80a00000 "$@"
}

echo "== round 33 control: no scheduler (round-32 KERN 6 frontier)"
run_boot ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round33_base.log 2>&1
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" \
    out/round33_base.log
base_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round33_base.log)
if [ "$base_insns" != "439534" ]; then
    echo "FAIL: control stopped at ${base_insns:-0} insns, expected 439534" >&2
    tail -40 out/round33_base.log >&2
    exit 1
fi

echo "== round 33: switch to the kernel's NULL thread"
NK_SCHED=1 NK_SCHED_LOG=16 run_boot ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round33_sched.log 2>&1

grep -q "sched: thread 0x80601078 blocks on svc #0x4d (status 0x802fff8c" \
    out/round33_sched.log
grep -q "sched: first switch -> NULL thread 0x80601830, entry 0x5031f144" \
    out/round33_sched.log
grep -q "sched: switch #1 -> thread 0x80601830 pc 0x5031f144" \
    out/round33_sched.log
grep -q "sched: thread-start hand-off consumed; re-armed" \
    out/round33_sched.log
grep -q "sched: preempt 0x80601830 -> supervisor 0x80601078 at pc 0x50330a98" \
    out/round33_sched.log
grep -q "sched: startup request 0x802fff8c completed" out/round33_sched.log
if grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" \
        out/round33_sched.log; then
    echo "FAIL: the KERN 6 panic survived the scheduler switch" >&2
    tail -40 out/round33_sched.log >&2
    exit 1
fi
grep -q "undefined=0" out/round33_sched.log
grep -q "unbound IAT=0" out/round33_sched.log
grep -q "recoveries=0" out/round33_sched.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round33_sched.log
grep -q "lr=0x503360d4" out/round33_sched.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round33_sched.log)
if [ -z "$insns" ] || [ "$insns" -le 440300 ] || [ "$insns" -gt 445000 ]; then
    echo "FAIL: scheduler boot stopped at ${insns:-0} instructions, expected >440300" >&2
    tail -40 out/round33_sched.log >&2
    exit 1
fi

echo "ok: control reproduces the round-32 KERN 6 halt at 0x50312b88 (439,534)"
echo "ok: svc #0x4d blocks the supervisor on thread+0x5c (request semaphore)"
echo "ok: first switch starts the NULL thread 0x80601830 at its real entry"
echo "    0x5031f144 on a 0x2000-byte kernel stack"
echo "ok: the guest's own start hand-off (0x50321088 -> 0x50318398) consumes the"
echo "    re-armed TRequestStatus; the supervisor resumes at 0x50330a98 with"
echo "    [sp] == 0, so KERN 6 no longer fires"
echo "ok: boot advances to $insns insns and the next frontier is a null call in"
echo "    the multi-thread CObjectIx/B7e path at 0x503360d4 (LR)"
echo "PASS: round 33 closes the first blocking executive call; run-queue and"
echo "      CObjectIx multi-thread state are next"
