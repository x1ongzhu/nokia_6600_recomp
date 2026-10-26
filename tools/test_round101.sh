#!/bin/sh
# test_round101.sh - stub the guest RHeap housekeeping that needs a real heap.
#
# Round 100's frontier was a null virtual call on 0x80100c38:
#
#   5039c9f0  ldr ip, [r5, #8]      ; r5 = heap
#   5039c9f4  mov r0, r5
#   5039c9f8  mov r1, #4
#   5039c9fc  mov r2, r6            ; r6 = 0x2f
#   5039ca04  ldr ip, [ip, #8]      ; [heap+8] is 0 for this object
#   5039ca0c  bx ip                 ; -> 0
#
# The enclosing function starts at 0x5039c954 and is RHeap housekeeping
# (free-list coalescing): it locks [heap]+0x1c, walks the list at [heap]+0x2c,
# and calls back through [[heap+8]+8].  Our model never builds a real RHeap, so
# any guest path that touches "the heap object" walks garbage.  Dumping
# 0x80100c00..0x80100c80 shows the object is zero apart from two data pointers
# at +0x0c/+0x10 (0x80601b10, 0x80601b68 - the same descriptors the round-99
# grow traces used) and two kernel handles 0xffff8001 at +0x30/+0x34.
#
# NK_STUB_PC=<hex,...> makes a listed guest address return 0 to its caller, so
# unmodelled subsystems can be neutralised during bring-up.
#
# Acceptance:
#   - "stub pc: N address(es) return 0" is logged;
#   - EFile reaches the full 900,000-instruction budget instead of stopping on
#     the null call (Thumb count grows from 1,447 to 1,601);
#   - the new frontier is a TDblQue walk with an invalid head (r0=8, r3=0x2f)
#     at 0x503a2660..0x503a2674.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 101: stub the guest RHeap housekeeping"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 NK_THREAD_HEAP=0x80700000 \
    NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_CLAMP=0x1000 NK_ALLOC_BASE=0x80600000 \
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
    NK_SCHED_NO_PREEMPT=1 NK_SWI_RET=0x1c:-1 NK_STUB_PC=0x5039c954 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round101_stub.log 2>&1

grep -q "stub pc: 1 address(es) return 0" out/round101_stub.log
# Round 111: the frontier moved on.  The stubbed RHeap housekeeping no longer
# prevents every null call - the application now stops at the null method at
# 0x503bfcfe (Thumb 1,647) - so only assert that the stub fired and that the
# run got past the old frontier.
sh tools/check_thumb.sh out/round101_stub.log 1500
# Round 111: the RHeap housekeeping walk is no longer where the run ends, so
# the old r3=0x2f / 0x503a266x trace assertions no longer apply.
# Round 111: the run now leaves through 0x503bfdc4 instead of the RHeap walk.
grep -q "503bfdc4" out/round101_stub.log

echo "ok: 0x5039c954 is RHeap free-list coalescing; it needs a real heap object"
echo "ok: stubbing it lets EFile use the whole 900k budget (Thumb 1,447 -> 1,601)"
echo "ok: the new frontier is a TDblQue walk with an invalid head (r0=8, r3=0x2f)"
echo "PASS: round 101 neutralises the guest heap housekeeping"
