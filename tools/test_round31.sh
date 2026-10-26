#!/bin/sh
# test_round31.sh - inject the mask-ROM/HAL timer-queue singleton and cross
# the round-30 null call at 0x5031ef50.
#
# Round 30 ended at `[0x80001c34] -> vtable+0xc` with a null object.  The
# object is not created by the E32 image: kernel export 451 (0x5032aff8) is
# its abstract base constructor and export 344 (0x5032b33c) its setter, but
# no image imports either.  The concrete implementation is mask-ROM/HAL boot
# state.
#
# This round injects the object at the exact instruction that consumes it:
#   * call the kernel's own constructor 0x5032aff8 with a scratch stack;
#   * the base vtable (0x503383bc) has a pure-virtual slot at +0x1c
#     (`User::Panic`), which the concrete HAL subclass overrides with the
#     hardware tick getter.  Copy the vtable and substitute a zero-return
#     getter so the kernel's own 0x5032b024 runs.
#
# Acceptance:
#   - control (NK_TIMERQ_MODE=ctor): the unmodified base vtable calls the
#     pure virtual and halts at 0x50312b88 (430,945 insns);
#   - override: boot continues past 0x5031ef50, Kern::Init1 returns to the
#     kernel-start path, and a new frontier appears at 0x503a6148 (a null
#     cleanup-object call reached through SVC 0x73 / 0x503187e8).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

# Round 32 found that the null cleanup object this test pins was caused by
# B7e rejecting the real heap DThread (0x80601078) and keeping the bootstrap
# SThread at 0x802ffd00 live.  Pin the historical model explicitly so this
# acceptance stays reproducible; tools/test_round32.sh covers the fixed
# thread identity and the next frontier.
echo "== round 31: timer-queue boot-state object (historical thread model)"
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
        NK_B7E_VALID_HI=0x80400000 \
        "$@"
}

echo "== round 31 control: abstract base vtable only"
NK_TIMERQ_MODE=ctor run_boot ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round31_base.log 2>&1

grep -q "timerq: ctor 0x5032aff8 -> ok" out/round31_base.log
grep -q "undefined=0" out/round31_base.log
grep -q "unbound IAT=0" out/round31_base.log
grep -q "recoveries=0" out/round31_base.log
grep -q "irqs=1" out/round31_base.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" \
    out/round31_base.log

echo "== round 31: concrete HAL override, cross the null call"
NK_TIMERQ_MODE=override run_boot ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round31_timerq.log 2>&1

grep -q "timerq: ctor 0x5032aff8 -> ok" out/round31_timerq.log
grep -q "timerq: HAL override vtable" out/round31_timerq.log
grep -q "timerq: \[0x80001c34\] = 0x80500000 -> vtable+0xc = 0x5032b024" \
    out/round31_timerq.log
grep -q "undefined=0" out/round31_timerq.log
grep -q "unbound IAT=0" out/round31_timerq.log
grep -q "recoveries=0" out/round31_timerq.log
grep -q "irqs=1" out/round31_timerq.log
grep -q "timer: on, [1-9][0-9]* expiries" out/round31_timerq.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round31_timerq.log
grep -q "null function pointer: branch to 0 (caller lr=0x503a6148)" \
    out/round31_timerq.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round31_timerq.log)
if [ -z "$insns" ] || [ "$insns" -lt 435000 ] || [ "$insns" -gt 445000 ]; then
    echo "FAIL: timer-queue boot stopped at ${insns:-0} instructions, expected 435k..445k" >&2
    tail -40 out/round31_timerq.log >&2
    exit 1
fi

echo "ok: [0x80001c34] is created with the kernel's own constructor 0x5032aff8"
echo "    and the concrete HAL vtable overrides the pure-virtual +0x1c slot"
echo "    (User::Panic at 0x50336858, Kernel export 451 base 0x503383bc)"
echo "    Kern::Init1 returns to the kernel-start path; $insns insns total,"
echo "    1 timer IRQ, 0 undefined / 0 unbound IAT / 0 recoveries"
echo "PASS: round-31 closes the round-30 null call; the new frontier is a"
echo "      null cleanup object at 0x503a6148 (SVC 0x73 / 0x503187e8)"
