#!/bin/sh
# test_round49.sh - splash asset/loader facts.
#
# SplashScreen.mbm is a small MBM (0xd54 bytes) whose header at 0x509efae0
# has UID 0x10000041, bitmap offsets 0x10/0x8c0, width 0xb0 (176) and height
# 0xd0 (208), with mostly-white 0x7fff pixel data.  After the stable
# SplashScreen run, a RAM dump contains no MBM signature (0x10000041,
# count 2), so the app has not loaded/decoded the splash yet.
#
# EwSrv's direct null call at lr=0x506c0b15 comes from the Thumb veneer at
# 0x506c15ee; the literal it loads is 0x4a7846c0, not a valid IAT slot.  That
# is a relocation/veneer problem, not a simple unbound import.
#
# Acceptance:
#   - MBM header fields match;
#   - the stable SplashScreen run still stops at the 2M wait;
#   - the RAM dump has no MBM signature;
#   - EwSrv direct null-calls at 0x506c0b15 and the veneer literal is
#     0x4a7846c0.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 49: splash asset and loader facts"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def u32(a): return struct.unpack_from('<I', d, a - base)[0]
mbm = 0x509efae0
assert u32(mbm) == 0x10000041
assert u32(mbm + 4) == 2
assert u32(mbm + 8) == 0x10
assert u32(mbm + 0xc) == 0x8c0
assert u32(mbm + 0x20) == 0xb0   # 176
assert u32(mbm + 0x30) == 0xd0   # 208
assert u32(mbm + 0x54) == 0xff7fff7f  # mostly-white pixels
assert u32(0x506c15f4) == 0x4a7846c0  # bad veneer literal
print('ok: SplashScreen.mbm header 176x208, offsets 0x10/0x8c0')
print('ok: EwSrv veneer literal at 0x506c15f4 is 0x4a7846c0')
EOF

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 NK_RECOVER=0 \
    NK_CALL_INFER=0 NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x509eee85 NK_SP=0x80580000 \
    NK_DUMP=0x80600000:0x400000,0x7ff00000:0x100000 \
    NK_DUMP_FILE=out/round49_splashram.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round49_splash.log 2>&1
grep -q "^--- stop: budget (0) at 0x503244f4 ---" out/round49_splash.log
grep -q "insns=2000000" out/round49_splash.log

.venv/bin/python - <<'EOF'
d = open('out/round49_splashram.bin', 'rb').read()
sig = bytes.fromhex('4100001002000000')
assert sig not in d, 'MBM signature unexpectedly present in RAM'
print('ok: no MBM signature in the SplashScreen RAM dump')
EOF

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=2000000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000030 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x506a8205 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round49_ewsrv.log 2>&1
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round49_ewsrv.log
grep -q "lr=0x506c0b15" out/round49_ewsrv.log

echo "ok: the splash app still waits at the request semaphore after 2M"
echo "ok: it has not loaded the MBM (no signature in its RAM)"
echo "ok: EwSrv's null call comes from a bad veneer literal, not an unbound"
echo "    IAT slot"
echo "PASS: round 49 pins the splash asset and EwSrv relocation facts"
