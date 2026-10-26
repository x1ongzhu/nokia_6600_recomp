#!/bin/sh
# test_round102.sh - run the application thread on the kernel's real RHeap.
#
# Before round 98 every guest allocation went through the HLE bump allocator.
# The logs show that guest code already passed a real heap pointer around:
# 0x80905ec4 is the RHeap the kernel created during boot ("heap 0x80905ec4" in
# tools/test_round95.sh's control run).  Round 101 then found guest RHeap
# housekeeping (0x5039c954) crashing on a heap object the harness never built.
#
# The kernel itself cannot run without the HLE allocator: with NK_ALLOC_HLE=0
# from the start it panics at 12,595 instructions (PLAT fault halt at
# 0x50312b88).  NK_ALLOC_HLE_KERNEL_ONLY=1 therefore disables the HLE allocator
# only once an application thread is dispatched, so:
#   - the kernel keeps the HLE heap it needs to boot;
#   - the application thread uses the kernel's real RHeap (NK_THREAD_HEAP).
#
# With that, guest alloc/free/coalesce/realloc all run for real: no stub, no
# clamp, no null call.  EFile leaves with KErrNoMemory (-4) instead, through the
# round-98 trap frame (UnTrap returns 0x80004500), because its descriptor-grow
# still receives a pointer-sized length (delta 0x80561f28, a stack address).
#
# Acceptance:
#   - "alloc hle: disabled for the application thread";
#   - stop is "returned" at 0xdead0000 (clean unwind, no fault);
#   - UnTrap returns the round-98 frame 0x80004500 and the leave error is
#     r4=0xfffffffc (KErrNoMemory);
#   - Thumb count 1,380.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 102: run the application thread on the real RHeap"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 \
    NK_THREAD_HEAP=0x80905ec4 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_HLE_KERNEL_ONLY=1 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=1 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_IMPORTMAP_REVERT=1 NK_IMPORTMAP_NO_REVERT=0x503b3948 \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x600 \
    NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_AUTOCOMPLETE=1 \
    NK_SCHED_EXIT=1 NK_SCHED_LOG=6 NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 \
    NK_SCHED_NO_PREEMPT=1 NK_SWI_RET=0x1c:-1 \
    NK_WATCH=0x5038cb44 NK_WATCH_HITS=1 NK_WATCH_LOG=6 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round102_realheap.log 2>&1

grep -q "alloc hle: disabled for the application thread" out/round102_realheap.log
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round102_realheap.log
if grep -qE "^--- stop: (null call|self-branch|pc left)" out/round102_realheap.log; then
    echo "FAIL: the application thread faulted on the real heap" >&2
    exit 1
fi
grep -q "r0=0x80004500" out/round102_realheap.log
grep -q "r4=0xfffffffc" out/round102_realheap.log
grep -q "Thumb 1380)" out/round102_realheap.log
if grep -q "HLE alloc clamped" out/round102_realheap.log; then
    echo "FAIL: the clamp is still active for the app thread" >&2
    exit 1
fi

echo "ok: the kernel keeps its HLE heap (it panics at 12,595 instructions"
echo "    without it) while the application thread runs on the real RHeap"
echo "ok: guest alloc/free/coalesce/realloc run for real - no stub, no clamp,"
echo "    no fault"
echo "ok: EFile leaves with KErrNoMemory (-4) through the round-98 trap frame"
echo "    because its descriptor grow still gets a stack address as a length"
echo "PASS: round 102 puts the application thread on the real heap"
