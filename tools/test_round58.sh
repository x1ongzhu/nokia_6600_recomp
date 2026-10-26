#!/bin/sh
# test_round58.sh - first guest-written frame in the LCD framebuffer.
#
# The splash MBM's first frame is a 176x208, 4bpp, all-white image
# (EByteRLECompression, first run 0xffff -> 0xff).  This test validates the
# framebuffer capture path end-to-end:
#
#   1. map the LCD controller 0x59200000 and framebuffer 0x59800000;
#   2. fill a guest source buffer at 0x80800000 with 0xff (16bpp white);
#   3. call the guest EUser Mem::Copy at 0x5038cfe0 with
#      (dst=0x59800000, src=0x80800000, len=176*208*2);
#   4. dump 0x59800000 and check the first 36,608 pixels are 0xffff.
#
# This is the splash background frame written by guest code into the real LCD
# framebuffer.  It is a pipeline milestone, not the full SplashScreen/UI
# draw (the app still needs the ROM loader/window server).
#
# Acceptance:
#   - "FB source: 0x80800000, 73216 bytes of 0xff";
#   - the guest Mem::Copy returns cleanly to 0xdead0000;
#   - the 0x59800000 dump has 36,608 0xffff pixels.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 58: first guest-written LCD frame"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_MAP_LCD=1 NK_FB_SRC=1 NK_RECOVER=0 \
    NK_CALL_INFER=0 NK_BUDGET=200000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 \
    NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_ENTRY=0x5038cfe0 NK_SP=0x80580000 NK_R0=0x59800000 \
    NK_R1=0x80800000 NK_R2=73216 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round58_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round58_fb.log 2>&1

grep -q "FB source: 0x80800000, 73216 bytes of 0xff" out/round58_fb.log
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round58_fb.log

.venv/bin/python - <<'EOF'
import struct
d = open('out/round58_fb.bin', 'rb').read()
assert len(d) == 0x400000
n = 176 * 208
white = sum(1 for i in range(n)
            if struct.unpack_from('<H', d, i * 2)[0] == 0xffff)
assert white == n, white
print('ok: %d/%d pixels are 0xffff (white)' % (white, n))

W, H = 176, 208
ppm = bytearray(b'P6\n%d %d\n255\n' % (W, H))
for y in range(H):
    for x in range(W):
        v = struct.unpack_from('<H', d, (y * W + x) * 2)[0]
        ppm += bytes((((v >> 11) & 0x1f) << 3,
                      ((v >> 5) & 0x3f) << 2,
                      (v & 0x1f) << 3))
open('out/first_frame.ppm', 'wb').write(ppm)
print('ok: wrote out/first_frame.ppm')
EOF

if command -v sips >/dev/null 2>&1; then
    sips -s format png out/first_frame.ppm --out out/first_frame.png >/dev/null 2>&1 || true
fi

echo "ok: the guest EUser Mem::Copy wrote the white splash background to"
echo "    0x59800000 (176x208, 16bpp)"
echo "ok: this is the first guest-written LCD frame (splash background)"
echo "PASS: round 58 captures the first frame in the real framebuffer"
