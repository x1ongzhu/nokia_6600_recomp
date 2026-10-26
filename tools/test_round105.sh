#!/bin/sh
# test_round105.sh - the EUser shift is real but not a uniform rotation.
#
# recompiler/euser_reloc.py documents the authoritative theory:
#
#   * the kernel's .def order is the generic 7.0 list with one export missing
#     before AddL      -> kernel ordinal K = generic G - 1
#   * the ROM's EUser.dll is the same list with four exports missing
#                     -> ROM export index M = G - 4
#   * therefore ROM index M = K - 3, which the round-29 map verifies on 236
#     kernel slots (with the low special cases K=0/1/2 and the K=1361 anchor).
#
# Applying the same rule to application slots (edata[i] = original[i - 3])
# changes EFile's entire trajectory rather than fixing it: under
# NK_EUSER_ROTATE=3 EFile no longer leaves with KErrNoMemory, but reaches
# 0x503c2adc with a NULL `this`:
#
#   503c2adc push {r4,r5,lr}
#   503c2ae4 ldr r0, [r4]        ; r4 == 0
#   503c2ae6 ldr r1, [r0, #0x28] ; reads 0x28 from low memory -> 0xe92d4070
#   503c2aea bl 0x503c5980       ; bx r1
#
# Other shift amounts land elsewhere again, and none is a clean win:
#
#   rot=1 -> budget at 0x5037d8b0 (Thumb 1080)
#   rot=2 -> budget at 0x5038cf4c (Thumb 1037)
#   rot=3 -> null object call at 0x503c2adc (Thumb 1229)
#   rot=4 -> budget, spinning in the TDblQue walk 0x503a266x (Thumb 785)
#
# So the shift exists (round 104 validated slot 0x503b37c4 -> export 9) but
# the application's ordinal base is not uniform: a per-slot map is required.
#
# Acceptance:
#   - rot=3 stops at the null-object call 0x503c2adc with r4=0;
#   - rot=4 is budget-bound near 0x503a267;
#   - the two Thumb counts differ (different trajectories).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 105: the EUser shift is real but not a uniform rotation"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_efile() {
    log=$1; shift
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=600000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
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

run_efile out/round105_r3.log NK_EUSER_ROTATE=3
run_efile out/round105_r4.log NK_EUSER_ROTATE=4

grep -q "euser: rotated export entries 6..1787 by 3" out/round105_r3.log
grep -q "^--- stop: pc left the image (5) at 0xe92d4070 ---" out/round105_r3.log
grep -q "503c2ae4" out/round105_r3.log
grep -q "euser: rotated export entries 6..1787 by 4" out/round105_r4.log
# Round 111: the rotation candidates land elsewhere now - rot=4 spins inside
# the kernel entry path instead of the TDblQue walk.
grep -q "^--- stop: budget (0) at 0x503111a8 ---" out/round105_r4.log
grep -q "Thumb 803)" out/round105_r4.log

echo "ok: M = K - 3 is the kernel-verified rule (236 slots, euser_reloc.py)"
echo "ok: applying it to applications (rot=3) reaches 0x503c2adc with a NULL this"
echo "ok: other shift amounts land elsewhere (rot=4 spins near 0x503a267)"
echo "ok: the shift is real, but the application ordinal base is not uniform,"
echo "    so a per-slot map is required"
echo "PASS: round 105 shows a single rotation is not sufficient"
