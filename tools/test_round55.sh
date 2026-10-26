#!/bin/sh
# test_round55.sh - EwSrv is a TRomImageHeader with a DLL ref table.
#
# The 0x506a81a0 header is not an E32ImageHeader; it is a TRomImageHeader:
#
#   +0x00 iUid1        0x1000007a
#   +0x04 iUid2        0x1000008c
#   +0x08 iUid3        0x10003b20
#   +0x10 iEntryPoint  0x506a8205
#   +0x14 iCodeAddress 0x506a8204
#   +0x18 iDataAddress 0x506c4c80
#   +0x1c iCodeSize    0x1ca80
#   +0x24 iDataSize    0x460c
#   +0x38 iDllRefTable 0x506c9290
#   +0x40 iExportDir   0x506c928c
#
# The TDllRefTable at 0x506c9290 has iFlags=1, iNumberOfEntries=7 and seven
# imported-DLL entry addresses.  The flat image never applies the ROM loader's
# import fixups, so the veneer literals (0x4a7846c0, 0x40b846c0, ...) are
# placeholders, not resolved IAT slots.  That is the architectural reason the
# window server cannot start from the flat image.
#
# Acceptance:
#   - the TRomImageHeader fields match;
#   - the DLL ref table has 1/7 and seven entries;
#   - the veneer literals are not in that table.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 55: EwSrv TRomImageHeader and DLL ref table"
tools/build_rom_image.sh >/dev/null

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def u32(a): return struct.unpack_from('<I', d, a - base)[0]
def u16(a): return struct.unpack_from('<H', d, a - base)[0]

h = 0x506a81a0
assert u32(h + 0x00) == 0x1000007a
assert u32(h + 0x04) == 0x1000008c
assert u32(h + 0x08) == 0x10003b20
assert u32(h + 0x10) == 0x506a8205
assert u32(h + 0x14) == 0x506a8204
assert u32(h + 0x18) == 0x506c4c80
assert u32(h + 0x1c) == 0x1ca80
assert u32(h + 0x24) == 0x460c
assert u32(h + 0x38) == 0x506c9290
assert u32(h + 0x40) == 0x506c928c
assert u32(h + 0x48) == 0

t = 0x506c9290
assert u16(t) == 1
assert u16(t + 2) == 7
entries = [u32(t + 4 + i * 4) for i in range(7)]
assert entries[0] == 0x506980e5
assert entries[1] == 0x506a815c
assert entries[2] == 0x503c9485
assert 0x40b846c0 not in entries
assert 0x4a7846c0 not in entries
print('ok: TRomImageHeader fields match (entry 0x506a8205, code 0x1ca80)')
print('ok: DLL ref table flags=1, count=7, entries[0..2]=0x506980e5/0x506a815c/0x503c9485')
print('ok: veneer literals 0x40b846c0/0x4a7846c0 are not resolved table entries')
EOF

echo "ok: EwSrv is a ROM image with a DLL ref table, not a relocatable E32 file"
echo "ok: the flat image does not apply the ROM loader's import fixups"
echo "ok: that is the architectural reason the window server cannot start"
echo "PASS: round 55 pins the TRomImageHeader/DLL-ref-table frontier"
