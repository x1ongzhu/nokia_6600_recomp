#!/bin/sh
# test_round72.sh - pin the app import-slot / EUser-export offset.
#
# The app-side slot 0x503b4338 is not EUser export 745.  There is a two-entry
# offset between the app import table and the EUser export table:
#
#   slot 0x503b4338  static value 0x503963dc  (ROM export 745, operator new)
#   app expects      export 747 = 0x50383c84  (CBase constructor)
#
# That is why rebinding the slot to 0x50383c84 works for both SplashScreen
# and EStart.  The old value (export 745) is operator new, which returns a
# zero-vtable block.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mkdir -p out
echo "== round 72: app import slot vs EUser export offset"
tools/build_rom_image.sh >/dev/null

.venv/bin/python - <<'PY'
import struct
d = open('out/6600_runtime.bin','rb').read()
base = 0x50000000
edata = 0x503b3794
def w(a): return struct.unpack_from('<I', d, a - base)[0]
assert w(edata + 745*4) == 0x503963dc, hex(w(edata + 745*4))
assert w(edata + 747*4) == 0x50383c84, hex(w(edata + 747*4))
assert w(0x503b4338) == 0x503963dc, hex(w(0x503b4338))
print('ok: slot 0x503b4338 holds EUser export 745 = 0x503963dc (operator new)')
print('ok: the app expects export 747 = 0x50383c84 (CBase constructor)')
print('ok: rebinding the slot to 0x50383c84 is the correct app-side fix')
PY

echo "ok: the two-entry offset explains why the ROM slot is operator new"
echo "    while both SplashScreen and EStart need the export-747 constructor"
echo "PASS: round 72 pins the app import-slot / EUser export offset"
