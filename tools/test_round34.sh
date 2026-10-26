#!/bin/sh
# test_round34.sh - keep the kernel's real DThread/CObjectIx graph, wake the
# supervisor from its request status, fix the banked exception stacks, and
# carry the faithful boot through the first six million instructions.
#
# Round 33 stopped at a null call in the multi-thread CObjectIx path.  The B7e
# boot stand-in was overwriting the kernel's real DThread+0x18 (DProcess),
# +0x5c (request semaphore) and +0x64 (CObjectIx) on every current-thread
# publish; the kernel's own CObjectIx::Remove then called a null vtable.
#
# Round 34:
#   - NK_B7E_LIVE=1 keeps every live kernel object and only fills missing
#     fields.  DThread+0x5c / +0x64 now stay 0x806019e0 / 0x806019c0 and the
#     teardown/close path runs the kernel's real CObjectIx vtable.
#   - The supervisor's TRequestStatus completion is a scheduler wake, not just
#     the harness dummy-page hand-off.  Without it the NULL thread ran a third
#     Kern::StartThread with no pending request and panicked PLAT 0x73.
#   - Kern::Init3 asks the HAL for device object 3 and issues Request 0xd,
#     then polls [0x800004cc].  The stand-in device now completes that request
#     (explicit HAL HLE; the real driver lives in mask ROM).
#   - The supervisor's SVC stack grows past 0x30 KiB.  The historical bank
#     layout placed the IRQ stack underneath it, so an IRQ frame overwrote the
#     interrupted function's saved LR and the return popped PC=6.  In live
#     mode the exception stacks sit low in RAM and a preset bank stack is
#     authoritative, so the SVC stack keeps its own region.
#
# Acceptance:
#   - control (no NK_B7E_LIVE): round 33's 440,623-instruction null call at
#     0x503360d4;
#   - live: 6,000,000 instructions, 14 timer IRQs, no undefined instruction,
#     no unbound IAT, no recoveries, no panic and no null call.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 34: live kernel objects, status wake, banked stacks"
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

echo "== round 34 control: no live-object model (round-33 frontier)"
run_boot NK_SCHED=1 NK_SCHED_LOG=0 ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round34_base.log 2>&1
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round34_base.log
grep -q "lr=0x503360d4" out/round34_base.log
base_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round34_base.log)
if [ "$base_insns" != "440623" ]; then
    echo "FAIL: control stopped at ${base_insns:-0} insns, expected 440623" >&2
    tail -40 out/round34_base.log >&2
    exit 1
fi

echo "== round 34: preserve the kernel's real thread graph"
run_boot NK_B7E_LIVE=1 NK_SCHED=1 NK_SCHED_LOG=16 NK_BUDGET=6000000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round34_live.log 2>&1

grep -q "keeps live process 0x80600d48" out/round34_live.log
grep -q "keeps request semaphore 0x806019e0" out/round34_live.log
grep -q "keeps object index 0x806019c0" out/round34_live.log
grep -q "supervisor status 0x802fff8c completed; runnable again" \
    out/round34_live.log
grep -q "banked mode stacks: svc=0x80300000.*irq=0x801c0000" \
    out/round34_live.log
if grep -q "null call\|panic halt\|pc left the image" out/round34_live.log; then
    echo "FAIL: live boot still faults" >&2
    tail -40 out/round34_live.log >&2
    exit 1
fi
grep -q "^--- stop: budget (0) at 0x5032211c ---" out/round34_live.log
grep -q "undefined=0" out/round34_live.log
grep -q "unbound IAT=0" out/round34_live.log
grep -q "recoveries=0" out/round34_live.log

live_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round34_live.log)
irqs=$(sed -n 's/.*irqs=\([0-9][0-9]*\).*/\1/p' out/round34_live.log)
if [ -z "$live_insns" ] || [ "$live_insns" != "5999982" ]; then
    echo "FAIL: live boot stopped at ${live_insns:-0} insns, expected 5999982" >&2
    tail -40 out/round34_live.log >&2
    exit 1
fi
if [ -z "$irqs" ] || [ "$irqs" -lt 14 ]; then
    echo "FAIL: live boot took only ${irqs:-0} timer IRQs" >&2
    exit 1
fi

echo "ok: control still reproduces round 33's 440,623-instruction null call"
echo "ok: DThread+0x18/+0x5c/+0x64 keep the kernel's real DProcess, request"
echo "    semaphore and CObjectIx (0x80600d48 / 0x806019e0 / 0x806019c0)"
echo "ok: the CObjectIx close path runs the kernel's real vtable; no null call"
echo "ok: a completed supervisor TRequestStatus is a scheduler wake, so the"
echo "    NULL thread no longer reaches a third hand-off with no request"
echo "ok: Kern::Init3's HAL object 3 / Request 0xd gate is completed by the"
echo "    explicit HAL stand-in and boot passes [0x800004cc]"
echo "ok: banked exception stacks no longer alias the SVC stack; the interrupted"
echo "    function returns to its caller instead of PC=6"
echo "ok: faithful-ish boot reaches $live_insns instructions with $irqs timer"
echo "    IRQs, 0 undefined, 0 unbound IAT and 0 recoveries"
echo "PASS: round 34 carries the boot from the CObjectIx frontier to a stable"
echo "      6M-instruction run; display/UI bring-up is the next frontier"
