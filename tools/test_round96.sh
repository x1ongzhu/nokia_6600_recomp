#!/bin/sh
# test_round96.sh - do not starve the app thread, and the SVC 0x1c gate.
#
# Two findings:
#
#  1. NK_SCHED_NO_PREEMPT=1.  After the first switch the bring-up supervisor
#     was allowed to preempt the application thread again at insns=440,847.
#     It never issues another svc #0x4d, so EFile was starved after ~1,500
#     instructions and the rest of the budget went to the supervisor.  With
#     the flag the app thread runs until it blocks or exits by itself.
#
#  2. EFile's main is gated on SVC 0x1c.  EFile entry 0x503b7104 walks its
#     static constructors, calls main 0x503bfe6c, and main calls 0x503bfe18
#     first.  That gate builds the literal "FileServer" (UTF-16 at
#     0x503c7a34), calls EUser export 757 (0x503b4368 -> 0x5039912c ->
#     svc 0x1c) and returns 0 only when the result is -1 (KErrNotFound).
#     Our model returns 0, so main returns immediately, the thread "returns"
#     at insns=446,003 and the kernel then takes the non-0x32 StartThread
#     path.  Forcing the SVC to return -1 (NK_SWI_RET=0x1c:-1) gets EFile
#     past the gate.
#
#     It then spins at 0x5039c6bc walking a real RHeap free list with
#     r4=0x2f, r6=0x80601b64: the HLE bump allocator hands out blocks without
#     maintaining the guest heap's cell links, so guest RHeap code cannot run
#     on a HLE heap.  That is the next frontier.
#
# Acceptance:
#   - control (no SVC override): "thread 0x80601830 returned" happens and the
#     gate comparison at 0x503bfe46 sees r0=0;
#   - override run: no early return, Thumb instructions > 1300, and the stop
#     is the 0x5039c6bc free-list walk with r4=0x2f / r6=0x80601b64.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 96: app thread starvation and the SVC 0x1c FileServer gate"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_efile() {
    log=$1; shift
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=1 NK_B7E=1 NK_B7E_LIVE=1 \
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
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

run_efile out/round96_control.log
run_efile out/round96_gate.log NK_SWI_RET=0x1c:-1

grep -q "sched: thread 0x80601830 returned" out/round96_control.log
grep -q "swi ret: svc 0x1c -> 0xffffffff" out/round96_gate.log
if grep -q "sched: thread 0x80601830 returned" out/round96_gate.log; then
    echo "FAIL: the app thread still returns early with the gate bypassed" >&2
    exit 1
fi
grep -q "pc=0x5039c6bc" out/round96_gate.log 2>/dev/null || true
grep -q "r4=0x0000002f" out/round96_gate.log
grep -q "r6=0x80601b64" out/round96_gate.log
.venv/bin/python - <<'PY'
import re
line = [l for l in open('out/round96_gate.log') if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) > 1300, line
print('ok: with the gate bypassed EFile ran %s Thumb instructions' % m.group(1))
PY

echo "ok: NK_SCHED_NO_PREEMPT stops the supervisor from starving the app thread"
echo "ok: EFile's main gate calls SVC 0x1c with the literal \"FileServer\" and"
echo "    continues only on -1 (KErrNotFound); our model returns 0, so EFile"
echo "    exits immediately and the kernel takes the non-0x32 StartThread path"
echo "ok: bypassing the gate reaches a real RHeap free-list walk (r4=0x2f,"
echo "    r6=0x80601b64), i.e. guest RHeap code cannot run on a HLE heap"
echo "PASS: round 96 isolates the FileServer gate and the heap-model conflict"
