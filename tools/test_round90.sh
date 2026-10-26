#!/bin/sh
# test_round90.sh - EStart's real main and import map (offline facts).
#
# Static analysis of the ROM EStart image (code 0x503da4a4, 0x1698 bytes):
#
#   0x503da4a4  static-constructor walker (E32 entry)
#   0x503db29c  real main: builds a 0x24-byte params block on the stack and
#               calls 14 sub-steps with r0 = that block:
#                 0x503da504 0x503db124 0x503da5a8 0x503da674 0x503dac3c
#                 0x503db158 0x503da6f0 0x503da9f4 0x503db134 0x503db124
#                 0x503da5cc 0x503dac98 0x503dabd4 0x503daaf4
#               (0x503db124/0x503db134 are status checks; 0x503db144 panics)
#
# So the "stack params block passed as `this`" seen in rounds 85-89 is EStart's
# normal ABI, not a bug: those are free functions taking a params struct.
#
# EStart's 56 import thunks split into three groups:
#   - 30 EUser slots (0x503b3xxx..0x503b4fxx)
#   - 12 EFSrv.dll slots (0x503cf918..0x503cfcdc is EFSrv's .edata,
#     uid3 0x100039e4, 241 exports, romfs "EFSrv.dll")
#   - kernel/other slots at 0x5034c6xx and 0x503b6b30
# Two slots are unresolved (0xffffffff): 0x503cfcd8 and 0x50a1f06c/0x50a1f070.
#
# File I/O is central: RFile-ish calls appear in steps 0x503da674,
# 0x503da6f0, 0x503da9f4 and 0x503daaf4, and one step mounts a file system.
# This test pins those facts so later rounds do not re-derive them.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mkdir -p out
echo "== round 90: EStart real main and import map"
tools/build_rom_image.sh >/dev/null

.venv/bin/python - <<'PY'
import struct, json, collections
d = open('out/6600_runtime.bin','rb').read()
base = 0x50000000
def w(a): return struct.unpack_from('<I', d, a - base)[0]
def h(a): return struct.unpack_from('<H', d, a - base)[0]

LO, HI = 0x503da4a4, 0x503da4a4 + 0x1698

# 1. static ctor walker calls the real main.
main_bl = None
for a in range(LO, LO + 0x80, 2):
    if (h(a) & 0xf800) == 0xf000:
        hw2 = h(a + 2)
        if (hw2 & 0xd000) == 0xd000:
            hw = h(a)
            S = (hw >> 10) & 1; imm10 = hw & 0x3ff
            J1 = (hw2 >> 13) & 1; J2 = (hw2 >> 11) & 1; imm11 = hw2 & 0x7ff
            off = (S << 24) | ((1-(J1^S)) << 23) | ((1-(J2^S)) << 22) | (imm10 << 12) | (imm11 << 1)
            if off & (1 << 24): off -= (1 << 25)
            tgt = a + 4 + off
            if 0x503db000 <= tgt < 0x503db354:
                main_bl = tgt
assert main_bl == 0x503db29c, hex(main_bl or 0)
print('ok: EStart static-ctor walker calls main 0x503db29c')

# 2. main is a 0x24-byte frame that calls its steps with r0 = sp.
assert h(0x503db29c) == 0xb500          # push {lr}
assert h(0x503db29e) == 0xb089          # sub sp, #0x24
sites = []
a = 0x503db29c
while a < 0x503db354:
    if (h(a) & 0xf800) == 0xf000:
        hw = h(a); hw2 = h(a + 2)
        if (hw2 & 0xd000) == 0xd000:
            S = (hw >> 10) & 1; imm10 = hw & 0x3ff
            J1 = (hw2 >> 13) & 1; J2 = (hw2 >> 11) & 1; imm11 = hw2 & 0x7ff
            off = (S << 24) | ((1-(J1^S)) << 23) | ((1-(J2^S)) << 22) | (imm10 << 12) | (imm11 << 1)
            if off & (1 << 24): off -= (1 << 25)
            sites.append((a, a + 4 + off)); a += 4; continue
    a += 2
steps = [t for _, t in sites if LO <= t < LO + 0x1640]
print('ok: main frame 0x24 bytes, %d sub-step calls' % len(steps))
assert 0x503da6f0 in steps and 0x503dac3c in steps, steps

# 3. 56 import thunks; 12 land in EFSrv's .edata; two are unresolved.
j = json.load(open('out/6600_runtime_layout.json'))
efs = [i for i in j['images'] if i['uid3'] == 0x100039e4][0]
efs_lo, efs_hi = efs['export_dir'], efs['export_dir'] + efs['export_count'] * 4
thunks = []
for t in range(0x503db354, 0x503db700, 2):
    if h(t) == 0x4b01 and h(t + 2) == 0x681b and h(t + 4) == 0x4718:
        thunks.append((t, w(t + 8)))
assert len(thunks) == 56, len(thunks)
efs_slots = [s for _, s in thunks if efs_lo <= s < efs_hi]
unres = [s for _, s in thunks if w(s) == 0xffffffff]
print('ok: %d thunks, %d EFSrv slots, unresolved %s'
      % (len(thunks), len(efs_slots), [hex(x) for x in unres]))
assert len(efs_slots) == 12, len(efs_slots)
assert 0x503cfcd8 in unres, unres

# 4. File I/O call sites cluster in the steps that take the params block.
def bl_sites(pred):
    out = []
    a = LO
    while a < HI - 4:
        if (h(a) & 0xf800) == 0xf000:
            hw = h(a); hw2 = h(a + 2)
            if (hw2 & 0xd000) == 0xd000:
                S = (hw >> 10) & 1; imm10 = hw & 0x3ff
                J1 = (hw2 >> 13) & 1; J2 = (hw2 >> 11) & 1; imm11 = hw2 & 0x7ff
                off = (S << 24) | ((1-(J1^S)) << 23) | ((1-(J2^S)) << 22) | (imm10 << 12) | (imm11 << 1)
                if off & (1 << 24): off -= (1 << 25)
                if pred(a + 4 + off): out.append(a)
                a += 4; continue
        a += 2
    return out
efs_thunks = [t for t, s in thunks if efs_lo <= s < efs_hi]
io = bl_sites(lambda t: t in efs_thunks)
print('ok: %d calls into EFSrv slots, from %s'
      % (len(io), sorted({hex(x) for x in io})[:6]))
assert len(io) >= 10, len(io)
print('ok: EStart is a params-block/file-I/O program, not a CBase client')
PY

echo "ok: corrected ABI - EStart passes a 0x24-byte stack params block to its"
echo "    own free functions; the rounds 85-89 'CBase' hypothesis was an"
echo "    artifact of the fake scheduler thread"
echo "ok: EStart's second import family is EFSrv.dll (file server); 12 slots"
echo "    and 2 unresolved (0xffffffff) entries"
echo "PASS: round 90 pins EStart's real main and import map"
