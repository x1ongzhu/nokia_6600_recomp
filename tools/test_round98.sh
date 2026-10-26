#!/bin/sh
# test_round98.sh - the thread trap frame and the thread heap pointer.
#
# Two pieces of per-thread boot state that the direct E32-entry boot never
# establishes, both read by kernel services:
#
#  1. svc 0x73 "UnTrap" (0x503187e8) returns [current_thread+0x38] and pops the
#     frame chain through [frame+0x40].  EUser (0x5038cb34) then reads
#     [frame+0x44] and [frame+0x48]; when [frame+0x48] is zero it restores a
#     whole context with `ldm r5, {r4..fp, sp, lr}` and branches through the
#     saved LR.  B7e left thread+0x38 zero, so that restore read address 0 and
#     jumped to 0x2c.  NK_TRAP_FRAME=1 installs one initial frame whose saved
#     LR is the exit sentinel 0xdead0000, and the thread then unwinds cleanly.
#
#  2. svc 0x6c (0x503187b8) returns [current_thread+0x34], the thread heap.
#     B7e left it zero as well, so guest allocation paths called RHeap with a
#     null allocator and the HLE allocator saw ReAlloc(heap=0, ptr=..., size=...)
#     with a pointer-sized request.  NK_THREAD_HEAP=<addr> publishes a heap.
#
# Acceptance:
#   - run A (trap frame only): stop is "returned" at 0xdead0000, no 0x2c;
#   - run B (trap frame + thread heap): no "HLE alloc rejected" at all, and the
#     next frontier is "pc left the image" at 0x3a;
#   - both runs execute > 1200 Thumb instructions.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 98: thread trap frame and thread heap"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_efile() {
    log=$1; shift
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
        NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
        NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
        NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
        NK_IMPORTMAP=config/imports-r29-6600.txt NK_IMPORTMAP_REVERT=1 \
        NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
        NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 NK_SCHED_FAKE=1 \
        NK_SCHED_ENTRY=0x503b7105 NK_SCHED_STACK=0x80560000 \
        NK_SCHED_STACK_EXTRA=0x600 NK_SCHED_STACK_FILL=0xdead0000 \
        NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=8 \
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 \
        NK_SWI_RET=0x1c:-1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

run_efile out/round98_frame.log NK_TRAP_FRAME=1
run_efile out/round98_heap.log NK_TRAP_FRAME=1 NK_THREAD_HEAP=0x80700000

grep -q "initial trap frame" out/round98_frame.log
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round98_frame.log
if grep -q "0x0000002c ---" out/round98_frame.log; then
    echo "FAIL: the null trap-frame restore is back" >&2
    exit 1
fi
grep -q "B7e: thread 0x80601830 heap 0x80700000" out/round98_heap.log
if grep -q "HLE alloc rejected" out/round98_heap.log; then
    echo "FAIL: an allocation was still rejected with the thread heap set" >&2
    exit 1
fi
grep -q "^--- stop: pc left the image (5) at 0x0000003a ---" out/round98_heap.log
for f in out/round98_frame.log out/round98_heap.log; do
    .venv/bin/python - "$f" <<'PY'
import re, sys
line = [l for l in open(sys.argv[1]) if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) > 1200, line
PY
done

echo "ok: the initial trap frame turns the null context restore at 0x2c into a"
echo "    clean unwind to the exit sentinel 0xdead0000"
echo "ok: publishing the thread heap removes the ReAlloc(heap=0, size=<pointer>)"
echo "    rejection entirely"
echo "ok: the next frontier is the null dereference at 0x3a"
echo "PASS: round 98 adds the per-thread trap frame and heap pointer"
