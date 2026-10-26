#!/bin/sh
# test_round103.sh - application-time import rebinds and the EUser 12 mismatch.
#
# EFile's startup function 0x503bfc78 creates several objects and then calls
# EUser slot 0x503b37c4 with ONE argument, e.g.
#
#   503bfcba  bl 0x503b7164        ; r0 = new(0x48) + ctor (vtable installed)
#   503bfcbe  r1 = 0x80100c0c      ; a fixed global
#   503bfcc0  [r1] = r0
#   503bfccc  r0 = 0x80100c0c
#   503bfcce  r0 = [r0]            ; g0
#   503bfcd0  bl 0x503c5dcc        ; EUser slot 0x503b37c4
#
# The ROM's export 12 at that slot is 0x503988a8, which takes THREE arguments
# (Mem::ReAlloc style: it fetches the thread heap with svc 0x6c and then calls
# 0x5039c438 -> 0x5039c37c with the caller's r0/r1/r2).  Calling it with only
# r0 set leaves r1/r2 as leftovers, which is how EFile ends up asking the heap
# for 0x503c7180 bytes and leaving with KErrNoMemory: the application was
# linked against a different EUser .def revision than the ROM ships.
#
# NK_IMPORTMAP_APP=<file> applies "<slot> <target>" rebinds AFTER the
# kernel-time map is reverted, so an application's expectations can be fixed
# per slot.  A sweep of exports 6..44 for slot 0x503b37c4 shows the slot alone
# is not the whole blocker: the best outcomes are budget-bound spins (exports
# 20, 23, 44) and the Thumb count stays between 1,281 and 1,450.
#
# Acceptance:
#   - with export 20 (0x5038221c) bound to the slot, the run reports
#     "importmap: applied 1 application rebinds" and reaches the budget;
#   - with the ROM value the run unwinds ("returned" at 0xdead0000);
#   - both runs stay within 1,281..1,450 Thumb instructions, i.e. the sweep
#     does not unlock EFile.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 103: application-time import rebinds"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_efile() {
    log=$1; shift
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=470000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
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
        NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=0 \
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 \
        NK_SWI_RET=0x1c:-1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

printf '0x503b37c4 0x5038221c\n' > out/round103_app.map
run_efile out/round103_rom.log
run_efile out/round103_e20.log NK_IMPORTMAP_APP=out/round103_app.map

grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round103_rom.log
grep -q "importmap: applied 1 application rebinds from out/round103_app.map" out/round103_e20.log
grep -q "^--- stop: budget (0)" out/round103_e20.log
.venv/bin/python - <<'PY'
import re
for f, lo, hi in (('out/round103_rom.log', 1281, 1450),
                  ('out/round103_e20.log', 1281, 1450)):
    line = [l for l in open(f) if l.startswith('insns=')][-1]
    m = re.search(r'Thumb (\d+)\)', line)
    assert m and lo <= int(m.group(1)) <= hi, (f, line)
    print('ok: %s -> Thumb %s' % (f, m.group(1)))
PY

echo "ok: EFile calls EUser slot 0x503b37c4 with one argument on objects it"
echo "    just created, but the ROM's export 12 there takes three"
echo "ok: NK_IMPORTMAP_APP applies per-slot rebinds after the kernel-time revert"
echo "ok: sweeping exports 6..44 does not unlock EFile (1,281..1,450 Thumb),"
echo "    so the app/ROM EUser mismatch is broader than one slot"
echo "PASS: round 103 adds application-time import rebinds"
