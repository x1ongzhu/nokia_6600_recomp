#!/bin/sh
# test_round42.sh - the 1.5M FbServ return-context corruption.
#
# The real-SVC FbServ run reaches 1,499,521 instructions and enters the EUser
# wait chain.  The final null return is not a vtable call: at 0x5039ee14 the
# stack still contains the saved LR 0x5039edc8 at the first watched pop, but
# the final pop returns 0 after the executive call 0x5039b05c.  The saved word
# is correct at entry, so the failure is a thread/context (stack) switch, not
# a push/pop or vtable bug.
#
# Completing the EUser wait SWIs inline does not help: the direct-SWI path
# still stops at 3,360 instructions with the 0x068a0688 vtable escape, so the
# wait SWIs are not the cause of the earlier corruption either.
#
# Acceptance:
#   - real-SVC run: 1,499,521 insns, stop null call at 0, lr=0;
#   - first watched pop at 0x5039ee14 has 0x5039edc8 on the stack;
#   - direct-SWI control with 0x76..0x7b completed still stops at 3,360
#     instructions / 0x068a0688.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 42: FbServ return-context corruption"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=1600000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    NK_WATCH=0x5039ee14 NK_WATCH_HITS=1 NK_WATCH_MEM=r13:0x20 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round42_ctx.log 2>&1

grep -q "insns=1499521" out/round42_ctx.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round42_ctx.log
grep -q "lr=0000000000" out/round42_ctx.log
grep -q "mem r13 @0x[0-9a-f]*: [0-9a-f]* 5039edc8" out/round42_ctx.log

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d,0x76,0x77,0x78,0x79,0x7a,0x7b \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round42_direct.log 2>&1
grep -q "insns=3360" out/round42_direct.log
grep -q "pc=0x068a0688" out/round42_direct.log

echo "ok: real-SVC FbServ reaches 1,499,521 instructions and the wait chain"
echo "ok: the first pop at 0x5039ee14 has the correct saved LR 0x5039edc8"
echo "ok: the final pop still returns 0 after the executive call"
echo "ok: completing the EUser wait SWIs inline does not fix the direct path;"
echo "    it still stops at 3,360 instructions / 0x068a0688"
echo "PASS: round 42 shows the 1.5M blocker is a thread/context switch, not"
echo "      the app's vtable or the wait SWIs"
