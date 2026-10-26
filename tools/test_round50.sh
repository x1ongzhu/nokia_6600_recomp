#!/bin/sh
# test_round50.sh - EwSrv passes its first missing-DLL call.
#
# EwSrv's veneer at 0x506c15ee loads a stale absolute function pointer from
# its missing DLL: 0x4a7846c0.  That address is unmapped, so the first call
# branches to 0.  NK_FIX_4A78=1 maps a full 64 KiB page at 0x4a780000 (the
# page size is 64 KiB, not 4 KiB) and points 0x4a7846c0 at a zero-return
# stub in the high-vector page.
#
# With the stub, the call executes:
#
#   506c15ee -> 0xffff0d00 -> 0xffff0d04 -> 506c0b14 ...
#
# EwSrv then continues to the next null pointer, so this is a concrete step
# past the first missing-DLL call, not a full window-server bring-up.
#
# Acceptance:
#   - the stub maps, and the last pcs contain 0xffff0d00/0xffff0d04;
#   - EwSrv still stops on a null call (the next unresolved pointer);
#   - the control without the stub stops at 0x506c15f2 (branch to 0).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 50: EwSrv first missing-DLL call"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

common() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_RECOVER=0 \
        NK_CALL_INFER=0 NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 \
        NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
        NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
        NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
        NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
        NK_BANKED=1 NK_ENTRY=0x506a8205 NK_SP=0x80580000 "$@"
}

common ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round50_control.log 2>&1
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round50_control.log
grep -q "506c15ee 506c15f0 506c15f2$" out/round50_control.log

common NK_FIX_4A78=1 ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round50_stub.log 2>&1
grep -q "EwSrv DLL stub: map=0" out/round50_stub.log
grep -q "EwSrv DLL stub: 0x4a7846c0" out/round50_stub.log
grep -q "ffff0d00 ffff0d04 506c0b14" out/round50_stub.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round50_stub.log

echo "ok: the missing DLL page is mapped and 0x4a7846c0 points at a"
echo "    zero-return stub"
echo "ok: EwSrv executes 0xffff0d00 -> 0xffff0d04 and returns to 0x506c0b14"
echo "ok: the next unresolved pointer still null-calls; this is the next"
echo "    window-server bring-up step"
echo "PASS: round 50 moves EwSrv past its first missing-DLL call"
