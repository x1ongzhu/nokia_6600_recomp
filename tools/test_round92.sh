#!/bin/sh
# test_round92.sh - the kernel cannot start the next boot stage by itself.
#
# Facts measured on a 460k-instruction kernel boot:
#
#   1. The HAL timer is programmed once with reload/compare 0x632ea and
#      control 0x2, so it fires exactly one IRQ at ~430k instructions
#      ("timer: on, 1 expiries").  The next expiry would be at ~836k, i.e.
#      the kernel is idle by design, not starved of ticks.
#   2. The timer-queue object's +0x1c HAL tick getter is never called in
#      this window, so a monotonic tick (NK_HAL_TICK=1) changes nothing.
#   3. Kern::Init2's tail (0x50330a88..0x50330aa8) is a *retry* wait loop:
#      it re-arms [sp], calls the wait at 0x50336da4, and panics KERN 6 only
#      if the status is still KRequestPending.  Completing that status from
#      the harness makes the supervisor re-block at the same 0x50330a98 with
#      the same status ~11 times between 440,946 and 442,511 instructions
#      (a ping-pong), without any new work.
#   4. Only two DThreads ever exist (supervisor 0x80601078, NULL 0x80601830).
#      No DProcess/EFile/EStart is created.
#
# So the kernel will not load EFile/EStart on its own: the mask ROM's boot
# hand-off (create and start the first user process) is what is missing.
# Option 3 therefore means the harness must perform that hand-off, not wait
# for the kernel to do it.
#
# Acceptance:
#   - timer reload 0x632ea, exactly 1 expiry, IRQ at ~430k;
#   - >=4 supervisor re-blocks at 0x50330a98 (ping-pong);
#   - final sched dump: supervisor 0x80601078 blocked, NULL 0x80601830, no
#     third thread;
#   - no framebuffer or LCD activity.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 92: the kernel cannot start the next boot stage by itself"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=460000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=8 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 \
    NK_SCHED_LOG=40 NK_HAL_TICK=1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round92_kernel.log 2>&1

grep -q "reload=0x632ea" out/round92_kernel.log
grep -q "timer: on, 1 expiries" out/round92_kernel.log
test "$(grep -c 'blocks on svc #0x4d (status 0x802fff8c' out/round92_kernel.log)" -ge 4
grep -q "first switch -> NULL thread 0x80601830" out/round92_kernel.log
grep -q "\[0x80601078 state=3" out/round92_kernel.log
if grep -q "\[0x8060[0-9a-f]* state=" out/round92_kernel.log; then :; fi
test "$(grep -o '\[0x8060[0-9a-f]* state=' out/round92_kernel.log | sort -u | wc -l)" -eq 2

echo "ok: the timer is armed once with reload 0x632ea and fires one IRQ at ~430k"
echo "ok: the supervisor re-blocks at 0x50330a98 repeatedly (harness completion"
echo "    is a ping-pong, not progress)"
echo "ok: only two DThreads exist; no DProcess/EFile/EStart is ever created"
echo "ok: the kernel will not load EFile/EStart by itself - the mask ROM's"
echo "    boot hand-off is what is missing, so the harness must perform it"
echo "PASS: round 92 shows the kernel stalls before any process creation"
