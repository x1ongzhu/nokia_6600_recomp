#!/bin/sh
# test_round85.sh - the supervisor passes a stack params block as a CBase.
#
# At the 0x00a04d08 dispatch, EUser 0x503ce690 treats r4=0x8057ffd8 as a
# CBase and reads [r4+0x14].  That word is 0x503da4cd, a code return
# address, so [r4+0x14+0xc] yields 0x00a04d08.  The "object" is actually
# EStart's stack params block, not a heap CBase.
#
# This test pins the diagnosis: the supervisor's r6/this is the stack params
# pointer, and the slot's target expects a real CBase.  The next fix is to
# construct/pass the real object, not change the target.
#
# Acceptance:
#   - watch at 0x503ce69c shows mem @0x8057ffd8 containing 503da4cd;
#   - stop pc left image at 0x00a04d08;
#   - insns=29295, framebuffer 0 pixels.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 85: supervisor passes a stack params block as a CBase"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_SWI_EXCEPTION=0 NK_DFC_EMPTY=1 \
    NK_EWSRV_SNAP=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=200000 \
    NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
    NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 \
    NK_IRQ_LOG=0 NK_TIMERQ=0 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x503da4a5 NK_SP=0x80580000 NK_MAP_LCD=1 \
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_WAIT_HLE=1 \
    NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_LR=0x5039865c \
    NK_SCHED_ENTRY=0x503da675 NK_SCHED_R0=0x8057ffc8 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x100 \
    NK_SCHED_LOG=8 NK_SCHED_AUTOCOMPLETE=1 NK_MEMCOPY_CLAMP=1 \
    NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_EXIT=1 \
    NK_WATCH=0x503ce69c NK_WATCH_HITS=1 NK_WATCH_LOG=2 NK_WATCH_MEM=r4:0x20 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round85_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round85_this.log 2>&1

grep -q "mem r4 @0x8057ffd8:" out/round85_this.log
grep -q "503da4cd" out/round85_this.log
grep -q "^--- stop: pc left the image (5) at 0x00a04d08 ---" out/round85_this.log
grep -q "insns=29295" out/round85_this.log

.venv/bin/python - <<'PY'
d = open('out/round85_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: the 0x00a04d08 dispatch sees this=0x8057ffd8 (stack params)"
echo "ok: [this+0x14]=0x503da4cd is a return address, not a vtable"
echo "ok: the slot target expects a real CBase; next fix is the object"
echo "PASS: round 85 diagnoses the supervisor stack-params-as-CBase bug"
