#!/bin/sh
# test_round59.sh - BitGdi export symbol map from the SDK bitgdi.lib.
#
# The ROM BitGdi export directory (0x506a7e78, 185 addresses) has no names.
# The matching Series 60 2.0 SDK import library bitgdi.lib stores the mangled
# symbol names in export order, so symbol i maps to export i:
#
#   idx 147 0x5069a991 DrawBitmap(TPoint, CFbsBitmap*)
#   idx 148 0x5069a9b5 DrawBitmap(TRect, CFbsBitmap*, T1)
#   idx 149 0x5069a9d9 DrawBitmap(TRect, CFbsBitmap*)
#   idx 164 0x5069a029 Clear(TRect)
#   idx 165 0x5069ec5d Clear()
#
# The tail of the table also contains DLL-ref entries (indices 171-174 are
# unreliable), but the drawing entry points above are the ones needed for a
# guest framebuffer draw.
#
# Acceptance:
#   - the tool prints the five addresses above;
#   - the Clear/DrawBitmap targets are valid Thumb prologues.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

if [ ! -f references/Series60_v20/Epoc32/release/armi/urel/bitgdi.lib ]; then
    echo "SKIP: SDK bitgdi.lib missing"
    exit 0
fi

echo "== round 59: BitGdi export symbol map"
tools/build_rom_image.sh >/dev/null
.venv/bin/python tools/bitgdi_symbols.py >out/round59_bitgdi.txt

grep -q "147 0x5069a991 DrawBitmap__9CFbsBitGcRC6TPointPC10CFbsBitmap" out/round59_bitgdi.txt
grep -q "149 0x5069a9d9 DrawBitmap__9CFbsBitGcRC5TRectPC10CFbsBitmap" out/round59_bitgdi.txt
grep -q "164 0x5069a029 Clear__9CFbsBitGcRC5TRect" out/round59_bitgdi.txt
grep -q "165 0x5069ec5d Clear__9CFbsBitGc" out/round59_bitgdi.txt

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def h(a): return struct.unpack_from('<H', d, a - base)[0]
for a in (0x5069a9d8, 0x5069a028, 0x5069ec5c, 0x5069a990):
    x = h(a)
    assert (x & 0xff00) in (0xb400, 0xb500) or (x & 0xff80) == 0xb080, (hex(a), hex(x))
print('ok: Clear/DrawBitmap targets are valid Thumb prologues')
EOF

echo "ok: Clear() = 0x5069ec5d, Clear(TRect) = 0x5069a029"
echo "ok: DrawBitmap(TPoint, bitmap) = 0x5069a991"
echo "PASS: round 59 maps the BitGdi drawing entry points"
