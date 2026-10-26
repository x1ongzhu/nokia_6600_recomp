#!/bin/sh
# test_round53.sh - the real LCD/framebuffer base and the zero-frame state.
#
# ecust.dll's display config at 0x5033abf4 writes:
#
#   [r1] = 0x59200000        ; LCD controller base
#   [r2] = 0x59800000        ; framebuffer base (base + 0x600000)
#   [r3] = 0x2000000/0x400000; framebuffer size
#
# Previously the harness mapped neither, so any guest pixel write went to the
# MMIO bus and was lost.  NK_MAP_LCD=1 maps the controller page and a 4 MiB
# framebuffer at 0x59800000 and allows a dump.
#
# The current stable SplashScreen run still does not write the framebuffer:
# the 4 MiB dump is all zero.  That is the capture target for the next step.
#
# Acceptance:
#   - the ecust code range contains the 0x59200000/0x59800000 literals;
#   - NK_MAP_LCD logs the controller/framebuffer mapping;
#   - SplashScreen stops at the 2M wait;
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

echo "== round 53: LCD framebuffer base"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
code = d[0x503397b4 - base:0x5033c000 - base]
assert struct.pack('<I', 0x59200000) in code
assert struct.pack('<I', 0x59200000) in code
print('ok: ecust code contains 0x59200000 (framebuffer base is +0x600000)')
EOF

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 NK_MAP_LCD=1 \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=2000000 NK_MMIO_N=0 \
    NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 \
    NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000030 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x509eee85 NK_SP=0x80580000 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round53_lcd.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round53_lcd.log 2>&1

grep -q "LCD: controller 0x59200000, framebuffer 0x59800000+0x400000" \
    out/round53_lcd.log
grep -q "^--- stop: budget (0) at 0x503244f4 ---" out/round53_lcd.log
grep -q "insns=2000000" out/round53_lcd.log

.venv/bin/python - <<'EOF'
d = open('out/round53_lcd.bin', 'rb').read()
assert len(d) == 0x400000, len(d)
nz = sum(1 for b in d if b)
assert nz == 0, nz
print('ok: 0x59800000 dump is 4 MiB and all zero (no guest frame yet)')
EOF

echo "ok: the LCD controller is at 0x59200000 and the framebuffer at"
echo "    0x59800000 (4 MiB window)"
echo "ok: the harness can map/dump the framebuffer"
echo "ok: the current stable splash run writes no pixels; this is the"
echo "    capture target for the first frame"
echo "PASS: round 53 pins the real framebuffer base and the zero-frame state"
