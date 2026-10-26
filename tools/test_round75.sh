#!/bin/sh
# test_round75.sh - exiting EStart's wait just retries StartThread.
#
# Round 74 fixed the nested SVC return and left EStart at 0x50398660, the
# wait-status check ([r5] == KRequestPending).  NOP the loop branch at
# 0x50398664 (0xe1a00000) so the wrapper exits even though the status is
# still pending.  EStart then immediately returns to 0x503998b0, the
# RThread::Resume/StartThread SVC 0x76 call, with handle 0x32.
#
# So the wait is for a real started thread, not just a status write.  The
# next step is a DThread/server object for handle 0x32, not another status
# HLE.
#
# Acceptance:
#   - stop budget at 0x503998b0;
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

echo "== round 75: exiting the wait retries StartThread"
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
    NK_POKE=0x503cf984:0xffff0300,0x50398664:0xe1a00000 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round75_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round75_waitexit.log 2>&1

grep -q "^--- stop: budget (0) at 0x503998b0 ---" out/round75_waitexit.log
grep -q "insns=200000" out/round75_waitexit.log
grep -q "mmio: 1720 reads, 0 writes" out/round75_waitexit.log

.venv/bin/python - <<'PY'
d = open('out/round75_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: NOP-ing the wait-status branch makes EStart exit the wait"
echo "ok: it immediately retries StartThread at 0x503998b0 (handle 0x32)"
echo "ok: the wait is for a real started thread; the next step is a"
echo "    DThread/server object for handle 0x32, not another status HLE"
echo "PASS: round 75 shows the wait needs a real thread/server"
