#!/bin/sh
# test_round56.sh - the app literals look like link-time addresses.
#
# EwSrv's veneer literal 0x4a7846c0 is not a resolved IAT slot.  If the ROM
# DLLs were linked at 0x4a780000 and later placed at their flat-image
# addresses, the relocation delta is (image.code - 0x4a780000).  Applying it
# to 0x4a7846c0 lands on valid Thumb prologues in several images:
#
#   uid 0x10003c77 -> 0x505bf774  b510
#   uid 0x10f9a40  -> 0x50815a74  b570
#   uid 0x1000a859 -> 0x50a6d6f4  b5f0
#   ...
#
# That is evidence for a missing ROM-loader relocation/import fixup, not a
# single bad import.  The 0x40b846c0 literal does not match this base, so each
# DLL may have its own link base.
#
# Acceptance:
#   - at least three images have a prologue-looking relocated target;
#   - the targets are inside the image code range;
#   - 0x40b846c0 does not match the 0x4a780000 base (per-DLL bases).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 56: link-time literal relocation lead"
tools/build_rom_image.sh >/dev/null

.venv/bin/python - <<'EOF'
import json, struct
j = json.load(open('out/6600_runtime_layout.json'))
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def h(a): return struct.unpack_from('<H', d, a - base)[0]
def prologue(a):
    x = h(a)
    return (x & 0xff00) in (0xb400, 0xb500) or (x & 0xff80) == 0xb080

matches = []
for im in j['images']:
    c, cs = im['code'], im['code_size']
    if not (0x50000000 <= c < 0x51600000):
        continue
    t = (0x4a7846c0 + (c - 0x4a780000)) & 0xffffffff
    if c <= t < c + cs and prologue(t):
        matches.append((im['uid3'], t, h(t)))
assert len(matches) >= 3, matches
for uid, t, x in matches[:6]:
    print('ok: uid %#x -> %#x (prologue %#x)' % (uid, t, x))

bad = []
for im in j['images']:
    c, cs = im['code'], im['code_size']
    if not (0x50000000 <= c < 0x51600000):
        continue
    t = (0x40b846c0 + (c - 0x4a780000)) & 0xffffffff
    if c <= t < c + cs and prologue(t):
        bad.append((im['uid3'], t))
assert not bad, bad
print('ok: 0x40b846c0 does not match the 0x4a780000 base (per-DLL bases)')
EOF

echo "ok: app literals behave like link-time addresses, not resolved slots"
echo "ok: a missing ROM-loader relocation/import fixup explains the bad"
echo "    veneer literals"
echo "PASS: round 56 pins the link-time literal relocation lead"
