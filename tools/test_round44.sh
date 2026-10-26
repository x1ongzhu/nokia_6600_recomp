#!/bin/sh
# test_round44.sh - FbServ's first SVC and the user/kernel marker.
#
# With the real SVC exception model, FbServ's first system call is:
#
#   0x50392b88  ef00006c   svc #0x6c
#
# The kernel handler at 0x50314f30 treats bit 23 of the immediate as the
# user/kernel selector.  0x6c has it clear, so the handler takes its
# kernel-side path and returns to the boot sentinel / null, not to the app.
# The flat image has bound the app's imports to the kernel-side EUser stub
# table, whose stubs lack the user marker.
#
# Marking the EUser stub table with bit 23 (NK_USER_SVC=1) is not enough: the
# handler then loads 0xe59ff028 from its dispatch table and jumps to that
# instruction word, so the user path expects a different table/entry format.
#
# Acceptance:
#   - trace shows 0x50392b88 ef00006c;
#   - real-SVC FbServ reaches the DFC-queue frontier (271 / 0xe59ff028);
#   - NK_USER_SVC=1 leaves the image at 0xe59ff028.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 44: FbServ first SVC and user/kernel marker"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

common() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_MMIO_N=0 NK_SWI_LOG=8 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
        NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
        NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
        NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
        NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000030 \
        NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
        NK_BANKED=1 NK_ENTRY=0x506897d5 NK_SP=0x80580000 "$@"
}

common NK_BUDGET=1000 NK_TRACE=1 NK_TRACE_N=200 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round44_svc.log 2>&1
grep -q "50392b88  ef00006c" out/round44_svc.log

common NK_BUDGET=1000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round44_stop.log 2>&1
grep -q "insns=271" out/round44_stop.log
grep -q "pc left the image (5) at 0xe59ff028" out/round44_stop.log
grep -q "lr=0x50315acc" out/round44_stop.log

common NK_BUDGET=1000 NK_USER_SVC=1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round44_marker.log 2>&1
grep -q "user SVC patch: 29 EUser stubs" out/round44_marker.log
grep -q "pc left the image (5) at 0xe59ff028" out/round44_marker.log

echo "ok: FbServ's first SVC is 0x50392b88 ef00006c (svc #0x6c)"
echo "ok: the handler's bit-23 selector takes the kernel path and the app"
echo "    stops at 271 instructions / 0xe59ff028 (DFC queue)"
echo "ok: setting bit 23 on the EUser stub table is not sufficient; the"
echo "    handler jumps to 0xe59ff028 from its dispatch table"
echo "PASS: round 44 pins the user/kernel SVC loader frontier"
