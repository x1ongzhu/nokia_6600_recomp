#!/bin/sh
# test_round110.sh - model the mask-ROM hand-off after a clean kernel boot.
#
# Round 109 was blocked because every application test stopped before the app
# thread started: the kernel halted at 0x50312b88 after 126,895 instructions.
# The diagnosis is that nothing was broken - the kernel was *booting*.  Its
# entry function 0x50310054 ends with
#
#   50312b7c  mov r1, #0x150000
#   50312b80  bl 0x50312f00
#   50312b84  bl 0x50310c3c          ; Kern::Init2
#   50312b88  b 0x50312b88           ; never returns
#
# and on the device the *mask ROM* starts the first application once the
# kernel is up.  The harness used to rely on the kernel getting stuck in the
# Kern::Init2 retry loop (0x50330a88) and hijacking it there, which happened at
# ~439,000 instructions.  When the kernel boots cleanly that never happens, so
# no hand-off was ever triggered.
#
# NK_HANDOFF_PC (default 0x50312b88) makes the scheduler treat that
# instruction as the mask-ROM hand-off: it drives the same wait-any-request
# block the kernel uses when it is stuck, which performs the first switch to
# the pre-created application thread.  Set NK_HANDOFF_PC=0 to disable.
#
# Acceptance:
#   - the run reports "sched: mask-ROM hand-off at pc 0x50312b88" at
#     insns=126,894;
#   - the application thread is dispatched (EFile runs, Thumb > 1,000);
#   - the stop is no longer the kernel self-branch 0x50312b88.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 110: mask-ROM hand-off after a clean kernel boot"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_efile() {
    log=$1; shift
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
        NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
        NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 NK_SCHED_FAKE=1 \
        NK_SCHED_ENTRY=0x503b7105 NK_SCHED_STACK=0x80560000 \
        NK_SCHED_STACK_EXTRA=0x600 NK_SCHED_STACK_FILL=0xdead0000 \
        NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=6 \
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 \
        NK_SWI_RET=0x1c:-1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

printf '0x503b37c4 0x5037fca0\n' > out/round110_push.map
run_efile out/round110_off.log NK_HANDOFF_PC=0 NK_IMPORTMAP_APP=out/round110_push.map
run_efile out/round110_on.log NK_IMPORTMAP_APP=out/round110_push.map

# Without the trigger the kernel simply halts.
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round110_off.log
# With it the mask-ROM hand-off runs and the application thread starts.
grep -q "sched: mask-ROM hand-off at pc 0x50312b88 (insns=126894)" out/round110_on.log
if grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round110_on.log; then
    echo "FAIL: the application thread was not dispatched" >&2
    exit 1
fi
.venv/bin/python - <<'PY'
import re
txt = open('out/round110_on.log').read()
m = re.search(r'Thumb (\d+)', txt)
assert m and int(m.group(1)) > 1000, m.group(0) if m else 'no Thumb count'
print('ok: application thread dispatched, Thumb %s' % m.group(1))
PY

echo "ok: a clean kernel boot halts at 0x50312b88 (it never returns)"
echo "ok: NK_HANDOFF_PC models the mask-ROM hand-off there (126,894 insns)"
echo "ok: the application thread now starts, so rounds 102..109 can run again"
echo "PASS: round 110 restores the application hand-off"
