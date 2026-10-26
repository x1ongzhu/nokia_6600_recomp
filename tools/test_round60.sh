#!/bin/sh
# test_round60.sh - CFbsBitmap::Create is blocked by the same loader fixup.
#
# With the BitGdi/FbsCli symbol map we can call CFbsBitmap::Create
# (FbsCli export 147, 0x5068cb91) on a zeroed guest object:
#
#   r0 = 0x80810000 (CFbsBitmap object), r1 = 176, r2 = 208, r3 = 7
#
# It runs into FbsCli code and then an unresolved veneer at 0x506dd80c,
# which loads the placeholder 0xe59ff028 and branches there with
# lr=0x506dd80d.  So the bitmap/Gc constructors are blocked by the same
# ROM-loader import fixup as EwSrv, not by the BitGdi symbol map.
#
# Acceptance:
#   - the run stops at 0xe59ff028 with lr=0x506dd80d;
#   - the last pcs show 0x506dd804/0x506dd806/0x506dd808.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 60: CFbsBitmap::Create loader blocker"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_MAP_LCD=1 NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=200000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_ENTRY=0x5068cb90 NK_SP=0x80580000 NK_R0=0x80810000 \
    NK_R1=176 NK_R2=208 NK_R3=7 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round60_create.log 2>&1

grep -q "^--- stop: pc left the image (5) at 0xe59ff028 ---" out/round60_create.log
grep -q "lr=0x506dd80d" out/round60_create.log
grep -q "506dd804 506dd806 506dd808" out/round60_create.log

echo "ok: CFbsBitmap::Create reaches an unresolved veneer at 0x506dd80c"
echo "ok: it branches to the placeholder 0xe59ff028 with lr=0x506dd80d"
echo "ok: BitGdi/FbsCli constructors need the same ROM-loader import fixup"
echo "PASS: round 60 pins the bitmap-constructor loader blocker"
