#!/bin/sh
# test_round37.sh - static display-chain inventory.
#
# The first frame needs FbServ.exe, not just a framebuffer model.  This test
# pins the ROMFS files and runtime addresses so the display work does not
# drift: FbServ.exe, FbsCli.dll, BitGdi.dll and the variant driver ecust.dll.
# It also pins the two hardware constants in ecust.dll (0x59E00010 and
# 0x59200000) and the already-ruled-out 0x41000000 boot-region table.
#
# Acceptance:
#   - the four display-chain files exist at their runtime addresses;
#   - ecust.dll code contains literals 0x59E00010 and 0x59200000;
#   - the 0x41080000 literal is absent from ecust.dll code (boot-region table
#     is kernel code, not the variant display driver);
#   - docs/DISPLAY.md records the chain.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
tools/build_rom_image.sh >/dev/null

.venv/bin/python - <<'EOF'
import json, struct, sys
sys.path.insert(0, 'recompiler')
import pagestream, romimage

raw = open('6600_mcu.bin', 'rb').read()
stream = pagestream.build(raw)
root = romimage.find_romfs_root(stream, 0x50300000)
assert root, 'ROMFS root not found'
files = {e.name: e for e, _ in romimage.collect_romfs_files(stream, root)}

want = {
    'FbServ.exe': 0x50689770,
    'FbsCli.dll': 0x5068c150,
    'BitGdi.dll': 0x50698080,
    'ecust.dll': 0x50339750,
}
for name, addr in want.items():
    assert name in files, 'missing ' + name
    e = files[name]
    assert e.addr == addr, '%s at %#x, expected %#x' % (name, e.addr, addr)
    print('ok: %s @ %#x (%#x bytes)' % (name, e.addr, e.size))

d = open('out/6600_runtime.bin', 'rb').read()
base = 0x50000000
def u32(a): return struct.unpack_from('<I', d, a - base)[0]

# ecust.dll E32 header: code/title/uid3.
hdr = 0x50339750
assert u32(hdr + 8) == 0x100058e7, 'ecust uid3'
code = u32(hdr + 0x14)
size = u32(hdr + 0x1c)
assert code == 0x503397b4, 'ecust code %#x' % code
blob = d[code - base:code - base + size]
for lit in (0x59E00010, 0x59200000):
    assert struct.pack('<I', lit) in blob, 'ecust missing %#x' % lit
    print('ok: ecust.dll references %#x' % lit)
assert struct.pack('<I', 0x41080000) not in blob, \
    '0x41080000 is not a variant driver constant'
print('ok: 0x41080000 is absent from ecust.dll (kernel boot-region table)')

assert u32(0x50689770 + 8) == 0x10003a16, 'FbServ uid3'
assert u32(0x50689770 + 0x10) == 0x506897d5, 'FbServ entry'
assert u32(0x5068c150 + 8) == 0x10003a15, 'FbsCli uid3'
assert u32(0x50698080 + 8) == 0x10003b18, 'BitGdi uid3'
print('ok: FbServ/FbsCli/BitGdi uid3 + entry match the display chain')
EOF

grep -q "FbServ.exe" docs/DISPLAY.md
grep -q "59E00010" docs/DISPLAY.md
echo "ok: docs/DISPLAY.md records the chain and hardware candidates"
echo "PASS: round 37 pins the static display chain and rules out the"
echo "      0x41000000 boot-region table as a variant driver constant"
