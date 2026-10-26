#!/bin/sh
# test_round57.sh - the EwSrv dllref/IAT section layout.
#
# EwSrv's 64-byte dllref section at 0x506c9290 is:
#
#   0x00070001            ; iFlags=1, iNumberOfEntries=7
#   0x506980e5            ; BitGdi entry
#   0x506a815c            ; EwSrv entry
#   0x503c9485            ; EUser entry
#   0x503cfcdc
#   0x503d91a5
#   0x503da434
#   0x5037d154
#   0x00000000
#   0x5068c1b5            ; FbsCli entry
#   0x50698040
#   0x50678465
#   0x50680d4c
#   0x503b53f5
#   0x503b6b44
#   0xffffffff
#
# The six entries after the zero are not per-import IAT slots: patching the
# second veneer (0x506c1dba) to point at them does not produce a clean return.
# Slot 0x506c92b8 (0x50698040) enters BitGdi but then wild-jumps to
# 0x5155a0ca; the other slots null-call.  This negative result means the app
# needs the real ROM loader's import fixup, not a guessed slot table.
#
# Acceptance:
#   - the dllref section fields/entries match;
#   - the slot 0x506c92b8 experiment wild-jumps to 0x5155a0ca.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 57: EwSrv dllref/IAT section"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def u32(a): return struct.unpack_from('<I', d, a - base)[0]
def u16(a): return struct.unpack_from('<H', d, a - base)[0]
t = 0x506c9290
assert u16(t) == 1 and u16(t + 2) == 7
entries = [u32(t + 4 + i * 4) for i in range(7)]
assert entries[0] == 0x506980e5
assert entries[1] == 0x506a815c
assert entries[2] == 0x503c9485
assert u32(t + 0x20) == 0
assert u32(t + 0x24) == 0x5068c1b5
assert u32(t + 0x3c) == 0xffffffff
print('ok: dllref flags/count = 1/7, entries[0..2] = 0x506980e5/0x506a815c/0x503c9485')
print('ok: section tail 0, 0x5068c1b5 ... 0xffffffff')
EOF

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_FIX_4A78=1 NK_RECOVER=0 \
    NK_CALL_INFER=1 NK_BUDGET=500 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 \
    NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-ewsrv-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x506a8205 NK_SP=0x80580000 \
    NK_POKE=0x506c1dc0:0x506c92b8 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round57_slot.log 2>&1
grep -q "^--- stop: pc left the image (5) at 0x5155a0ca ---" out/round57_slot.log
grep -q "lr=0x506980cb" out/round57_slot.log

echo "ok: the six tail entries are not per-import slots; the 0x506c92b8"
echo "    patch enters BitGdi and then wild-jumps to 0x5155a0ca"
echo "ok: EwSrv needs the real ROM loader import fixup, not a guessed slot"
echo "PASS: round 57 pins the dllref section and the slot-mapping negative result"
