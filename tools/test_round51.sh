#!/bin/sh
# test_round51.sh - EwSrv reaches its real prologue, then a packed veneer.
#
# EwSrv's call at 0x506a821a encodes 0x506c0b0c, which is in the middle of
# the function whose real prologue is 0x506c0a4a:
#
#   506c0a4a  push {r4-r7,lr}; mov r7,sb; mov r6,r8; push {r6,r7}
#   506c0a52  sub sp,#0xc
#   ...
#   506c0b0c  adds r0,r5,#0x14    ; mid-function
#
# The new config/callmap-ewsrv-6600.txt adds
#  0x506a821a 0x506c0a4a T
# (callmap fixups are applied only when NK_CALL_INFER=1).  With the fixup
# EwSrv enters the proper prologue and reaches the next veneer at 0x506c1dba,
# where the literal the veneer loads is code/padding, not a slot.  That is a
# packed/relocated veneer-literal problem, not a missing single import.
#
# NK_FIX_4A78 now fills the whole missing-DLL page 0x4a780000..0x4a790000
# with the zero-return stub pointer.
#
# Acceptance:
#   - the control (no callmap) null-calls at lr=0x506c0b15;
#   - the fixed run logs the callmap redirect to 0x506c0a4a and reaches
#     0x506c1dba/0x506c1dbc/0x506c1dbe, then null-calls at lr=0x506c0a61.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 51: EwSrv real prologue and packed veneer"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

common() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_FIX_4A78=1 \
        NK_RECOVER=0 NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 \
        NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
        NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
        NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
        NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000030 \
        NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
        NK_ENTRY=0x506a8205 NK_SP=0x80580000 "$@"
}

common NK_CALL_INFER=0 NK_CALLMAP=config/callmap-rtc-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round51_control.log 2>&1
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round51_control.log
grep -q "lr=0x506c0b15" out/round51_control.log

common NK_CALL_INFER=1 NK_CALLMAP=config/callmap-ewsrv-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round51_fixed.log 2>&1
grep -q "callmap config/callmap-ewsrv-6600.txt: 4 call-site fixups" \
    out/round51_fixed.log
grep -q "call: callmap 0x506a821a -> 0x506c0a4a (Thumb)" \
    out/round51_fixed.log
grep -q "506c0a4a 506c0a4c 506c0a4e 506c0a50" out/round51_fixed.log
grep -q "506c1dba 506c1dbc 506c1dbe" out/round51_fixed.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round51_fixed.log
grep -q "lr=0x506c0a61" out/round51_fixed.log

echo "ok: the control still null-calls at lr=0x506c0b15 (mid-function)"
echo "ok: the callmap redirects 0x506a821a to the real prologue 0x506c0a4a"
echo "ok: EwSrv reaches the next veneer 0x506c1dba, whose literal is"
echo "    code/padding rather than a slot"
echo "PASS: round 51 moves EwSrv to the packed-veneer frontier"
