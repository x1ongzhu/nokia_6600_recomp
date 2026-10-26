#!/bin/sh
# test_round52.sh - EwSrv IAT vs unrelocated veneer literal.
#
# EwSrv's IAT at 0x506c9290 contains resolved Thumb function addresses:
#
#   0x506c9294 0x506980e5
#   0x506c9298 0x506a815c
#   0x506c929c 0x503c9485
#   ...
#
# The next veneer EwSrv reaches (0x506c1dba) is:
#
#   506c1dba  4b01  ldr r3,[pc,#4]
#   506c1dbc  681b  ldr r3,[r3]
#   506c1dbe  4718  bx r3
#   506c1dc0  46c0  mov r8,r8   ; padding, not a slot
#
# The literal the veneer loads is code/padding, not an IAT slot.  The IAT is
# fine; the app code's literal pool was not relocated by the flat image
# loader.  That is the packed/relocated veneer-literal problem.
#
# Acceptance:
#   - the IAT entries and veneer bytes match;
#   - the fixed EwSrv run (callmap + missing-DLL page) reaches 0x506c1dba
#     and null-calls at lr=0x506c0a61.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 52: EwSrv IAT vs unrelocated veneer literal"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def u32(a): return struct.unpack_from('<I', d, a - base)[0]
def u16(a): return struct.unpack_from('<H', d, a - base)[0]
assert u32(0x506c9294) == 0x506980e5
assert u32(0x506c9298) == 0x506a815c
assert u32(0x506c929c) == 0x503c9485
assert u16(0x506c1dba) == 0x4b01
assert u16(0x506c1dbc) == 0x681b
assert u16(0x506c1dbe) == 0x4718
lit = u32(0x506c1dc0)
assert lit not in (0x506c9294, 0x506c9298, 0x506c929c), hex(lit)
print('ok: IAT 0x506c9294/98/9c = 0x506980e5/0x506a815c/0x503c9485')
print('ok: veneer 0x506c1dba loads %#x (padding), not an IAT slot' % lit)
EOF

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_FIX_4A78=1 NK_RECOVER=0 \
    NK_CALL_INFER=1 NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-ewsrv-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x506a8205 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round52_ewsrv.log 2>&1

grep -q "call: callmap 0x506a821a -> 0x506c0a4a (Thumb)" out/round52_ewsrv.log
grep -q "506c1dba 506c1dbc 506c1dbe" out/round52_ewsrv.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round52_ewsrv.log
grep -q "lr=0x506c0a61" out/round52_ewsrv.log

echo "ok: EwSrv reaches the veneer and stops because its literal is padding"
echo "ok: this is an unrelocated app literal pool, not a missing IAT entry"
echo "PASS: round 52 pins the EwSrv veneer-literal loader frontier"
