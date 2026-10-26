#!/bin/sh
# test_round97.sh - the application heap is HLE-only; guest RHeap must not run.
#
# Round 96 showed EFile spinning at 0x5039c6bc while walking a real RHeap free
# list with r4=0x2f.  The cause was the HLE allocator's polite fall-through:
# RHeap1::ReAlloc1 (0x5039c630) was only intercepted for pointers the HLE bump
# heap owns, so a realloc of any other pointer ran the guest allocator, which
# then walked a free list that the HLE heap never builds.
#
# Round 97 removes every fall-through:
#   - realloc of a pointer we do not own (or of null) becomes a fresh HLE
#     block; nothing is copied because the old size is unknown;
#   - free of a pointer we do not own is a logged no-op;
#   - oversized requests still fail cleanly (round 94).
#
# After that EFile no longer enters the guest RHeap.  It now reaches the
# trap-handler restore path: 0x5038cb34 calls svc 0x73 (trap handler uninstall),
# reloads a whole context with `ldm r5, {r4..fp, sp, lr}` and branches through
# the restored LR, which is garbage (0x2c).  That trap-handler stack is the
# next frontier.
#
# Acceptance:
#   - no 0x5039c6bc spin in the last PCs;
#   - stop is "pc left the image" at 0x2c;
#   - the last PCs contain the context restore 0x5038cb70..0x5038cb78;
#   - EFile gets past the FileServer gate (Thumb > 1300).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 97: keep the guest RHeap out of the HLE heap"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=1 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=6 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_IMPORTMAP_REVERT=1 \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x600 \
    NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_AUTOCOMPLETE=1 \
    NK_SCHED_EXIT=1 NK_SCHED_LOG=8 NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 \
    NK_SCHED_NO_PREEMPT=1 NK_SWI_RET=0x1c:-1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round97_heap.log 2>&1

grep -q "^--- stop: pc left the image (5) at 0x0000002c ---" out/round97_heap.log
if grep -q "5039c6bc" out/round97_heap.log; then
    echo "FAIL: the guest RHeap free-list spin is back" >&2
    exit 1
fi
grep -q "5038cb78" out/round97_heap.log
grep -q "5038cb70" out/round97_heap.log
.venv/bin/python - <<'PY'
import re
line = [l for l in open('out/round97_heap.log') if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) > 1300, line
print('ok: EFile ran %s Thumb instructions past the FileServer gate' % m.group(1))
PY

echo "ok: realloc/free of foreign pointers no longer enter the guest RHeap"
echo "ok: the 0x5039c6bc free-list spin is gone"
echo "ok: EFile now reaches the trap-handler restore at 0x5038cb34 (svc 0x73),"
echo "    reloads a context with ldm r5 and branches to the saved LR 0x2c"
echo "ok: the trap-handler stack is the next frontier"
echo "PASS: round 97 makes the application heap HLE-only"
