#!/bin/sh
# test_round70.sh - EStart wait HLE exposes its next zero-vtable object.
#
# With imports-estart-6600.txt but no wait completion, EStart spends the
# 200k budget in the EUser wait-any-request poll at 0x50398648.  Adding
# NK_WAIT_HLE=1 completes the waiter and lets EStart run 12,136 instructions
# (1,720 MMIO reads) until it reaches a new zero-vtable object:
#
#   r5 = 0x80600000, [r5] = 0
#   0x503dac78  ldr r2,[r0,#8] -> 0xe59ff028
#   0x503dac7e  bl 0x503db35c (bx r2)
#
# The object comes from the EStart constructor path at 0x503db640 ->
# kernel export slot 0x5034c638 (static value 0x5034c74d).  Rebinding that
# slot to the EUser CBase constructor 0x50383c84 did not change this in the
# probe, so the next task is identifying the real EStart object constructor.
#
# Acceptance:
#   - stop at 0xe59ff028 with lr=0x503dac83;
#   - insns=12136, mmio 1,720 reads / 0 writes;
#   - r5=0x80600000 and r2=0xe59ff028;
#   - framebuffer has no app pixels.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 70: EStart wait HLE and the zero-vtable object"
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
    NK_APP_IMPORTMAP=config/imports-estart-nocbase-6600.txt \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round70_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round70_estart.log 2>&1

grep -q "^--- stop: pc left the image (5) at 0xe59ff028 ---" out/round70_estart.log
grep -q "insns=12136" out/round70_estart.log
grep -q "mmio: 1720 reads, 0 writes" out/round70_estart.log
grep -q "r5=0x80600000" out/round70_estart.log
grep -q "r2=0xe59ff028" out/round70_estart.log
grep -q "lr=0x503dac83" out/round70_estart.log

.venv/bin/python - <<'PY'
d = open('out/round70_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: NK_WAIT_HLE moves EStart from the 200k wait spin to 12,136"
echo "    instructions and 1,720 MMIO reads"
echo "ok: it now stops on a zero-vtable object at 0x80600000"
echo "    (vtable+8 -> 0xe59ff028, lr=0x503dac83)"
echo "ok: rebinding slot 0x5034c638 to 0x50383c84 did not fix that object;"
echo "    the real EStart constructor is the next target"
echo "PASS: round 70 exposes EStart's zero-vtable constructor frontier"
