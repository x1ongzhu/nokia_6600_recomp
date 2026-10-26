#!/bin/sh
# test_round61.sh - the Nokia logo frame, written through the guest path.
#
# Round 58 proved the framebuffer path with a plain white source.  The real
# SplashScreen.mbm resource (ROM MBM at 0x509efae0) contains a 176x208
# EByteRLE8 bitmap whose payload is not all white: its first frame has the
# NOKIA logo in the lower rows.  The FbsServ/CFbsBitmap loader is still
# blocked by the unrelocated ROM veneers (rounds 55-60), so this round
# materialises the firmware bitmap as a guest RGB565 buffer and lets the real
# guest EUser Mem::Copy (0x5038cfe0) write it to the real LCD framebuffer at
# 0x59800000.
#
# Acceptance:
#   - the guest-memory MBM header decodes as bitmap 0, 176x208, EByteRLE8,
#     36608 pixels;
#   - 1,449 pixels are non-white, bbox x=0..173, y=159..178 (the logo);
#   - the guest Mem::Copy returns cleanly to 0xdead0000;
#   - the dumped framebuffer has the exact RGB565 FNV-1a hash of the frame;
#   - docs/assets/nokia_logo_frame.png is regenerated from that dump.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out docs/assets

echo "== round 61: Nokia logo frame from SplashScreen.mbm"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_MAP_LCD=1 NK_FB_MBM=1 NK_RECOVER=0 \
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
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round61_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round61_logo.log 2>&1

grep -q "FB MBM: SplashScreen.mbm @ 0x509efae0, bitmap 0 176x208, EByteRLE8, 36608 pixels" \
    out/round61_logo.log
grep -q "FB MBM: src 0x80800000, non-white 1449, bbox x=0..173 y=159..178, RGB565 fnv1a=0xd10ed2d0" \
    out/round61_logo.log
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round61_logo.log

.venv/bin/python - <<'PY'
import struct, zlib
W, H = 176, 208
N = W * H
d = open('out/round61_fb.bin', 'rb').read()
assert len(d) == 0x400000, len(d)
pix = struct.unpack_from('<%dH' % N, d, 0)

white = sum(1 for v in pix if v == 0xffff)
assert white == 35159, white
nonwhite = [(i % W, i // W) for i, v in enumerate(pix) if v != 0xffff]
assert len(nonwhite) == 1449, len(nonwhite)
x0 = min(x for x, y in nonwhite); x1 = max(x for x, y in nonwhite)
y0 = min(y for x, y in nonwhite); y1 = max(y for x, y in nonwhite)
assert (x0, x1, y0, y1) == (0, 173, 159, 178), (x0, x1, y0, y1)

h = 2166136261
for v in pix:
    h = ((h ^ (v & 0xff)) * 16777619) & 0xffffffff
    h = ((h ^ (v >> 8)) * 16777619) & 0xffffffff
assert h == 0xd10ed2d0, hex(h)
print('ok: %d/%d pixels are white, %d are the logo' % (white, N, len(nonwhite)))
print('ok: logo bbox x=%d..%d y=%d..%d, RGB565 fnv1a=%#010x' % (x0, x1, y0, y1, h))

# Expand RGB565 to RGB888 and write a real PNG (no host drawing, no PIL).
rgb = bytearray()
for v in pix:
    r = (v >> 11) & 0x1f
    g = (v >> 5) & 0x3f
    b = v & 0x1f
    rgb += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))

def write_png(path, w, h, rgb, scale=1):
    raw = bytearray()
    for y in range(h):
        row = rgb[(y * w) * 3:((y + 1) * w) * 3]
        if scale > 1:
            row = b''.join(row[x * 3:x * 3 + 3] * scale for x in range(w))
        for _ in range(scale):
            raw += b'\x00' + row
    if scale > 1:
        w *= scale
        h *= scale
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    open(path, 'wb').write(png)
    return len(png)

n1 = write_png('docs/assets/nokia_logo_frame.png', W, H, rgb)
n3 = write_png('docs/assets/nokia_logo_frame_3x.png', W, H, rgb, scale=3)
print('ok: wrote docs/assets/nokia_logo_frame.png (%d bytes)' % n1)
print('ok: wrote docs/assets/nokia_logo_frame_3x.png (%d bytes)' % n3)
PY

echo "ok: the real SplashScreen.mbm logo pixels were copied by guest EUser"
echo "     Mem::Copy into the 0x59800000 LCD framebuffer"
echo "PASS: round 61 shows the Nokia logo frame"
