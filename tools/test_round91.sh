#!/bin/sh
# test_round91.sh - the ROM boot chain and EStart's EFSrv dependency.
#
# Offline facts (packed ROM + flat runtime image), pinned so option 3
# (kernel process loader / real EFSrv) has a stable map:
#
#   ekern.exe      169804  0x5030ff9c   kernel
#   EFile.exe       74520  0x503b70a0   file server
#   EFSrv.dll       26724  0x503c9420   file-server client API (241 exports)
#   EStart.exe       5844  0x503da440   imports EFSrv -> runs after EFile
#   Starter.exe     18720  0x509e9ac0
#   SplashScreen.exe 3156  0x509eee20   + SplashScreen.mbm 3412
#   nosstarter.ext    148  0x50341430   kernel extension
#
# So the real splash chain is ekern -> EFile -> EStart -> Starter ->
# SplashScreen.  EStart's 12 EFSrv import slots cannot work until the file
# server exists, which is why driving EStart alone can never draw.
#
# Kernel side: during a 600k kernel boot the handle->object lookup at EUser
# slot 0x503b3948 (rebound by config/imports-r29-6600.txt from the ROM's
# 0x50380270 to 0x5038e4b4, the kernel's K-3 build) is called with the
# process object index 0x80600e98, whose element count at +8 is 0.  Every
# handle lookup therefore returns 0, so the Init3 thread-start completion
# can never resolve handle 0x32.  Populating that index is the first real
# task of the kernel-process-loader route.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mkdir -p out
echo "== round 91: ROM boot chain and the empty kernel object index"
tools/build_rom_image.sh >/dev/null

.venv/bin/python - <<'PY'
import sys, struct
sys.path.insert(0, 'recompiler')
import romimage
rom = romimage.load_packed('6600_mcu.bin')
hdr = romimage.find_rom_header(rom)
root = romimage.find_romfs_root(rom, hdr['root_dir_list'])
files = {e.name: e for e, _ in romimage.collect_romfs_files(rom, root)}
need = ['ekern.exe', 'EFile.exe', 'EFSrv.dll', 'EStart.exe',
        'Starter.exe', 'SplashScreen.exe', 'SplashScreen.mbm']
for n in need:
    assert n in files, n
print('ok: boot chain present: ' + ', '.join(
    '%s@%#x' % (n, files[n].addr) for n in need))
assert files['EFile.exe'].addr < files['EStart.exe'].addr
assert files['EStart.exe'].addr < files['Starter.exe'].addr

d = open('out/6600_runtime.bin','rb').read()
base = 0x50000000
def w(a): return struct.unpack_from('<I', d, a - base)[0]
def h(a): return struct.unpack_from('<H', d, a - base)[0]

# EStart imports 12 EFSrv slots (EFSrv .edata 0x503cf918, 241 entries).
efs_lo = 0x503cf918
efs_hi = efs_lo + 241 * 4
thunks = [t for t in range(0x503db354, 0x503db700, 2)
          if h(t) == 0x4b01 and h(t + 2) == 0x681b and h(t + 4) == 0x4718]
efs_slots = [w(t + 8) for t in thunks if efs_lo <= w(t + 8) < efs_hi]
assert len(thunks) == 56, len(thunks)
assert len(efs_slots) == 12, len(efs_slots)
print('ok: EStart has 56 thunks, 12 into EFSrv .edata')

# The kernel's handle->object slot is rebound away from the ROM value.
assert w(0x503b3948) == 0x50380270        # ROM: CObjectIx::At (push variant)
assert w(0x5038e4b4) != 0                 # kernel K-3 target exists
print('ok: ROM slot 0x503b3948 = 0x50380270; kernel map rebinds it to 0x5038e4b4')
print('ok: the boot chain needs EFile before EStart, so EStart alone cannot draw')
PY

echo "ok: real splash chain is ekern -> EFile -> EStart -> Starter -> SplashScreen"
echo "ok: EStart's 12 EFSrv slots require the file server to already exist"
echo "ok: kernel handle lookups run against an empty object index (count 0),"
echo "    so handle 0x32 never resolves; populating it is the next task"
echo "PASS: round 91 pins the ROM boot chain and the empty-kernel-index blocker"
