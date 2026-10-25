#!/bin/sh
# test_round30.sh - the first real hardware interrupt: UPP timer 0 -> IRQ 1 ->
# the kernel's IRQ vector -> the scheduler-wake handler -> idle exits.
#
# Round 29 left the kernel polling [0x8000000c] in its idle loop.  That flag is
# set by the interrupt handler object registered for IRQ 1 (0x50310ee0); the
# handler is only reachable through the ARM IRQ vector, which the interpreter
# did not model.  Round 30 adds:
#
#   * ARM IRQ exception entry/return: SPSR_irq, banked r13/r14, LR=PC+4,
#     vector base from CP15.V (the kernel uses 0xffff0000), and the existing
#     `subs pc,lr,#4` / `ldm ...,{pc}^` return paths;
#   * an instruction-driven UPP timer/ICU model at 0x58120a00 / 0x58120100.
#     The guest programs unit 0 (control=2, reload=0x632ea) during Kern::Init1;
#     the model raises IRQ 1 when the reload expires and reports it through the
#     ICU current-IRQ register, exactly what Kern::Irq dispatches on.
#
# Acceptance:
#   - control (NK_CPSR=0x400000d3, I=1): the timer expires but no IRQ is taken;
#     idle stays at 0x5031252c and the budget stop is unchanged;
#   - IRQ run (NK_CPSR=0x40000053, I=0): one IRQ enters 0xffff0018, the kernel
#     acks timer 0, sets [0x8000000c], idle exits, and Kern::Init1 continues
#     until it calls the still-unmodelled object at [0x80001c34] (null call at
#     0x5031ef50).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 30: interpreter IRQ/timer regressions"
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/interp_selftest.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/interp_selftest
./out/interp_selftest >out/round30_interp.log 2>&1
grep -q "IRQ enters the high vector and restores SPSR/mode/stack" \
    out/round30_interp.log
grep -q "IRQ is masked while CPSR.I is set" out/round30_interp.log
grep -q "UPP timer 0 raises IRQ 1 at the guest reload and acks" \
    out/round30_interp.log
grep -q "interpreter self-test OK" out/round30_interp.log

echo "== flat image + boot harness"
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
        NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=8 \
        NK_IMPORTMAP=config/imports-r29-6600.txt \
        "$@"
}

echo "== round 30: control (timer armed, CPSR.I=1 masks the IRQ)"
NK_CPSR=0x400000d3 NK_IRQ_LOG=0 run_boot ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round30_control.log 2>&1

grep -q "undefined=0" out/round30_control.log
grep -q "unbound IAT=0" out/round30_control.log
grep -q "recoveries=0" out/round30_control.log
grep -q "irqs=0" out/round30_control.log
grep -q "timer: on, [1-9][0-9]* expiries" out/round30_control.log
grep -q "idle flag \[0x8000000c\] = 0000000000" out/round30_control.log
grep -q "^--- stop: budget (0) at 0x5031252c ---" out/round30_control.log

echo "== round 30: first timer IRQ wakes the kernel idle loop"
NK_CPSR=0x40000053 NK_IRQ_LOG=4 run_boot ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round30_irq.log 2>&1

grep -q "undefined=0" out/round30_irq.log
grep -q "unbound IAT=0" out/round30_irq.log
grep -q "recoveries=0" out/round30_irq.log
grep -q "irqs=1" out/round30_irq.log
grep -q "timer: on, [1-9][0-9]* expiries" out/round30_irq.log
grep -q "\[irq\] enter .*-> 0xffff0018" out/round30_irq.log
grep -q "idle flag \[0x8000000c\] = 0x00000001" out/round30_irq.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round30_irq.log
grep -q "null function pointer: branch to 0 (caller lr=0x5031ef54)" \
    out/round30_irq.log
irq_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round30_irq.log)
if [ -z "$irq_insns" ] || [ "$irq_insns" -lt 400000 ] || \
   [ "$irq_insns" -gt 500000 ]; then
    echo "FAIL: first IRQ landed at ${irq_insns:-0} instructions, expected 400k..500k" >&2
    tail -40 out/round30_irq.log >&2
    exit 1
fi
# The guest acknowledges unit 0 in the handler; init writes 0 once, the IRQ
# handler writes 0 again.  More than one ack proves the handler ran.
acks=$(grep -c '^\[timer\] unit 0 reg 0x8 = 0' out/round30_irq.log || true)
if [ "$acks" -lt 2 ]; then
    echo "FAIL: timer unit 0 was not acknowledged by the IRQ handler" >&2
    exit 1
fi

echo "ok: UPP timer 0 expires at the guest-programmed reload and raises IRQ 1"
echo "    IRQ enters 0xffff0018 with SPSR_irq, the kernel acks timer 0,"
echo "    [0x8000000c] becomes 1, and the idle loop at 0x50310f84 exits"
control_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round30_control.log)
echo "    control: $control_insns insns with I=1 -> budget stop at 0x5031252c"
echo "    IRQ run: $irq_insns insns -> idle exit, then a null call at"
echo "             0x5031ef50 ([0x80001c34]->vtable+0xc, object not created)"
echo "PASS: round-30 timer/IRQ path works; the next gap is the boot-state"
echo "      object at [0x80001c34] that Kern::Init1 expects after idle"
