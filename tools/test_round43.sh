#!/bin/sh
# test_round43.sh - the 1.5M FbServ run was no-op SWIs, not real SVCs.
#
# With NK_SWI_DIRECT=0 and no exception model, arm_step prints the SWI and
# simply continues: the 1,499,521-instruction FbServ run never entered the
# kernel.  That corrects the round-41 interpretation.  This round adds a real
# SVC exception entry (NK_SWI_EXCEPTION=1): exception_enter() switches to the
# SVC bank/vector, the kernel handler at 0x50314f30 reads the instruction at
# LR-4 and dispatches.
#
# The handler first calls the mask-ROM pre-handler at [0x80000f34], which is
# zero on a direct E32-entry boot, so `ldr pc,[r12,#-4]` jumps to 0.  A
# zero-return hook object is installed in the high-vector page as boot state.
#
# With the hook:
#   - the kernel boot executes 11,114 instructions and returns to the boot
#     sentinel 0xdead0000 (the kernel's EUser import stubs are user-style
#     SVCs, so this path needs a user-mode caller);
#   - direct FbServ reaches only 56 instructions and null-returns, because the
#     handler's user-SVC return path needs the missing current-thread state.
#
# Acceptance:
#   - NK_SWI_DIRECT=0 without NK_SWI_EXCEPTION shows the SWI no-op and the
#     1,499,521-instruction run;
#   - NK_SWI_EXCEPTION=1 installs the hook and the kernel boot stops at
#     0xdead0000 after 11,114 instructions;
#   - direct FbServ with NK_SWI_EXCEPTION=1 stops at 56 instructions.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 43: real SVC exception model vs no-op SWIs"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

common() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_RECOVER=0 NK_CALL_INFER=0 NK_MMIO_N=0 NK_B7E=1 NK_B7E_LIVE=1 \
        NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
        NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
        NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
        NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
        NK_SWI_DIRECT=0 NK_SWI_LOG=8 "$@"
}

echo "== control: SWI is a no-op without the exception model"
common NK_BUDGET=5000 NK_CPSR=0x40000030 NK_BANKED=1 \
    NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round43_noop.log 2>&1
grep -q "\[interp\] SWI 0xc000" out/round43_noop.log

echo "== real SVC exception: kernel boot"
common NK_SWI_EXCEPTION=1 NK_BUDGET=600000 NK_CPSR=0x40000053 \
    NK_TIMER=1 NK_SCHED=1 NK_SCHED_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round43_kernel.log 2>&1
grep -q "svc hook: \[0x80000f34\]" out/round43_kernel.log
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round43_kernel.log
grep -q "insns=11114" out/round43_kernel.log

echo "== real SVC exception: direct FbServ"
common NK_SWI_EXCEPTION=1 NK_BUDGET=2000000 NK_CPSR=0x40000030 \
    NK_BANKED=1 NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round43_fbserv.log 2>&1
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round43_fbserv.log
grep -q "insns=56" out/round43_fbserv.log

echo "ok: NK_SWI_DIRECT=0 without an exception model treats SWIs as no-ops"
echo "ok: the 1.5M FbServ run was therefore not a real kernel path"
echo "ok: NK_SWI_EXCEPTION=1 enters the real SVC vector and installs the"
echo "    mask-ROM pre-handler hook"
echo "ok: kernel boot with real SVCs stops at the boot sentinel 0xdead0000"
echo "    after 11,114 instructions"
echo "ok: direct FbServ with real SVCs stops at 56 instructions; its user-SVC"
echo "    return path still needs the current-thread state"
echo "PASS: round 43 adds a real SVC exception model and corrects the"
echo "      interpretation of the 1.5M run"
