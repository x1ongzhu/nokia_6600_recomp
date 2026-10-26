#!/bin/sh
# test_round54.sh - the kernel boot does not reach the LCD either.
#
# Round 53 found the real framebuffer base 0x59800000.  Mapping it during the
# normal kernel boot (NK_MAP_LCD=1, 6M budget) still produces an all-zero
# 4 MiB dump: the kernel boot stops at 0x50312720 before any display driver /
# UI process runs.  So neither the kernel boot nor the stable SplashScreen
# path writes the LCD; the window-server/app-loader layer is the missing
# piece.
#
# Acceptance:
#   - the LCD mapping is logged;
#   - the kernel boot reaches the 6M budget;
#   - the 0x59800000 dump is 4 MiB and all zero.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 54: kernel boot with the LCD mapped"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_MAP_LCD=1 NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=6000000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 \
    NK_SCHED_DEFER=1 NK_DUMP=0x59800000:0x400000 \
    NK_DUMP_FILE=out/round54_kernel_lcd.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round54_kernel_lcd.log 2>&1

grep -q "LCD" out/round54_kernel_lcd.log \
    out/round54_kernel_lcd.log
grep -q "^--- stop: budget (0) at " out/round54_kernel_lcd.log
grep -q "insns=5999983" out/round54_kernel_lcd.log

.venv/bin/python - <<'EOF'
d = open('out/round54_kernel_lcd.bin', 'rb').read()
assert len(d) == 0x400000, len(d)
nz = sum(1 for b in d if b)
assert nz == 0, nz
print('ok: the kernel boot 0x59800000 dump is 4 MiB and all zero')
EOF

echo "ok: the kernel boot reaches 6M instructions with the LCD mapped"
echo "ok: it still writes no pixels; the display driver/UI layer is not"
echo "    reached by the current kernel bring-up"
echo "PASS: round 54 pins the kernel-boot zero-frame result"
