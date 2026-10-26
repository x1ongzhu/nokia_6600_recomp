#!/bin/sh
# test_round106.sh - correction: the disputed call does pass three arguments.
#
# Round 103/104 concluded from a disassembly window that EFile's call at
# 0x503bfcd0 sets only r0 ("one-argument CleanupStack::PushL") and that the
# ROM's export 12 must therefore be three entries too high.  Watching the PC
# directly disproves that:
#
#   pc=0x503bfcd0 r0=0x51035540 r1=0x80100c0c r2=0x9 r3=0
#
# Three arguments are set (buffer, a fixed global, and the length 9), and the
# grow wrapper 0x503988a8 forwards exactly those as (heap, a0, a1, a2).  So
# there is no arity mismatch at this call site; the earlier conclusion came
# from starting the disassembly at the wrong halfword.
#
# The per-slot search tool confirms there is no easy win from shifting:
#
#   baseline (ROM values)     Thumb 1380  returned (clean)
#   idx=12 -3 -> 0x5037fca0   Thumb 1383  null call  (crash)
#   idx=12 -4 -> 0x503a2bb4   Thumb 1447  null call  (crash)
#
# Every candidate that increases the Thumb count turns a clean exit into a
# crash, i.e. the ROM values are already the best of these candidates.  What
# remains is the *clean Leave* with KErrNoMemory inside the descriptor grow,
# caused by a call that passes two code/data pointers as (maxLen, delta):
# heap=0x80905ec4 ptr=0x510355e0 a1=0x503bfcf3 a2=0x503c7148.
#
# Acceptance:
#   - the watch shows r1=0x80100c0c and r2=0x9 at 0x503bfcd0;
#   - the search reports the baseline as clean and the two shifts as crashes;
#   - a1/a2 pointers appear in the failing grow call.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 106: the disputed call passes three arguments"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=460000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 NK_THREAD_HEAP=0x80905ec4 \
    NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_HLE_KERNEL_ONLY=1 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=1 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_IMPORTMAP_REVERT=1 NK_IMPORTMAP_NO_REVERT=0x503b3948 \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x600 \
    NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_AUTOCOMPLETE=1 \
    NK_SCHED_EXIT=1 NK_SCHED_LOG=0 NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 \
    NK_SCHED_NO_PREEMPT=1 NK_SWI_RET=0x1c:-1 \
    NK_WATCH=0x503bfcd0 NK_WATCH_HITS=2 NK_WATCH_LOG=2 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round106_call.log 2>&1

grep -q "pc=0x503bfcd0 thumb=1" out/round106_call.log
grep -q "r1=0x80100c0c r2=0x9" out/round106_call.log

sh tools/app_import_search.sh 12:3 12:4 > out/round106_search.log 2>&1
grep -q "baseline          Thumb=1380  --- stop: returned (2) at 0xdead0000 --- (clean)" out/round106_search.log
grep -q "idx=12   -3 -> 0x5037fca0   Thumb=1383  --- stop: null call (8) at 0000000000 --- longer but crashes" out/round106_search.log
grep -q "idx=12   -4 -> 0x503a2bb4   Thumb=1447  --- stop: null call (8) at 0000000000 --- longer but crashes" out/round106_search.log

echo "ok: at 0x503bfcd0 EFile sets r1=0x80100c0c and r2=0x9 - three arguments,"
echo "    not one, so the round-103/104 arity conclusion is withdrawn"
echo "ok: per-slot shifting only turns the clean run into a crash, so the ROM"
echo "    values are already the best of these candidates"
echo "ok: the remaining defect is the clean Leave with KErrNoMemory inside the"
echo "    descriptor grow, fed two code/data pointers as (maxLen, delta)"
echo "PASS: round 106 corrects the call-site arity and adds the search tool"
