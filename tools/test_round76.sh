#!/bin/sh
# test_round76.sh - cloning the bootstrap thread does not complete the wait.
#
# The B7e object-index fetch returns B7E_CUR_OBJ (the bootstrap DThread at
# 0x80003000) for every handle.  A clone at 0x80004600 with the same vtable
# and process/request/object-index fields, wired into the fetch literal at
# 0xffff041c, still leaves EStart's wait status at KRequestPending:
#
#   stop: budget (0) at 0x50398660
#   [r5] == 0x80000001
#
# So the missing piece is a real request/server completion, not another
# DThread-shaped object.  This test pins that negative result.
#
# Acceptance:
#   - stop budget at 0x50398660;
#   - insns=200000, mmio 1,720 reads / 0 writes;
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

echo "== round 76: DThread clone does not complete the wait"
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
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_WAIT_HLE=1 NK_NESTED_SVC=1 \
    NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
    NK_POKE=0x503cf984:0xffff0300,0xffff041c:0x80004600,0x80004600:0x80003040,0x80004614:1,0x80004618:0x80003200,0x8000465c:0x80003f00,0x80004664:0x80003300 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round76_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round76_t2.log 2>&1

grep -q "^--- stop: budget (0) at 0x50398660 ---" out/round76_t2.log
grep -q "insns=200000" out/round76_t2.log
grep -q "mmio: 1720 reads, 0 writes" out/round76_t2.log
grep -q "r3=0x80000001" out/round76_t2.log

.venv/bin/python - <<'PY'
d = open('out/round76_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: a DThread-shaped clone at 0x80004600 is still not enough"
echo "ok: the wait status remains KRequestPending at 0x50398660"
echo "ok: the next step is a real request/server completion, not another"
echo "    object-graph HLE"
echo "PASS: round 76 rules out the DThread-clone shortcut"
