#!/bin/sh
# test_round73.sh - HLE EStart's bad virtual dispatch; it falls back to a wait.
#
# Round 71's next frontier is 0x503ce69c (bx r1, r1=0x00a04d08).  The call
# comes from EStart 0x503da74a -> stub 0x503db3dc -> slot 0x503cf984, whose
# value is 0x503ce691.  EStart passes a stack descriptor, but the ROM function
# treats it as a CBase object and reads [obj+0x14] -> [0xc].
#
# HLE the slot to a zero-return stub instead: EStart then runs the full
# 200,000-instruction budget and ends in the 0x50314f78 wait loop on handle
# 0x32.  So this mismatch is part of the service-start handshake, not the
# splash draw; a scheduler/server model is the real next step.
#
# Acceptance:
#   - stop budget at 0x50314f78, insns=200000;
#   - mmio 1,720 reads / 0 writes;
#   - framebuffer 0 pixels.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 73: HLE EStart bad dispatch; wait loop remains"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=200000 NK_MMIO_N=8 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 NK_IRQ_LOG=0 \
    NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x503da4a5 NK_SP=0x80580000 NK_MAP_LCD=1 \
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_WAIT_HLE=1 \
    NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
    NK_POKE=0x503cf984:0xffff0300 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round73_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round73_hle.log 2>&1

grep -q "^--- stop: budget (0) at 0x50314f78 ---" out/round73_hle.log
grep -q "insns=200000" out/round73_hle.log
grep -q "mmio: 1720 reads, 0 writes" out/round73_hle.log

.venv/bin/python - <<'PY'
d = open('out/round73_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: HLEing slot 0x503cf984 lets EStart run 200k again"
echo "ok: it falls back to the 0x50314f78 wait loop on handle 0x32"
echo "ok: the bad virtual dispatch was part of the service-start handshake;"
echo "    the next step is a scheduler/server model, not another pixel path"
echo "PASS: round 73 rules out the bad-dispatch fix as a direct draw path"
