#!/bin/sh
# test_round84.sh - adjacent EUser slot targets do not draw either.
#
# The supervisor's 0x00a04d08 dispatch comes from slot 0x503cf984
# (0x503ce691).  The surrounding table at 0x503cf960 holds other EUser
# function pointers.  Try the neighbours (0x503ce719, 0x503c9e99,
# 0x503c9c2d): each either null-calls around 30-31k instructions or leaves
# at 0x00a04d08, and none writes a framebuffer pixel.
#
# So the blocker is the supervisor object/argument, not a one-entry slot
# target mistake.  This test pins the negative sweep.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 84: EUser slot neighbour sweep"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

for tgt in 0x503ce719 0x503c9e99 0x503c9c2d; do
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_SWI_EXCEPTION=0 \
        NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=100000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
        NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
        NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
        NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
        NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 NK_IRQ_LOG=0 \
        NK_TIMERQ=0 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
        NK_ENTRY=0x503da4a5 NK_SP=0x80580000 NK_MAP_LCD=1 \
        NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_WAIT_HLE=1 \
        NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
        NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_LR=0x5039865c \
        NK_SCHED_ENTRY=0x503da675 NK_SCHED_R0=0x8057ffc8 \
        NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x100 \
        NK_SCHED_LOG=0 NK_SCHED_AUTOCOMPLETE=1 NK_MEMCOPY_CLAMP=1 \
        NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_EXIT=1 \
        NK_POKE=0x503cf984:$tgt \
        NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round84_fb.bin \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >out/round84_$tgt.log 2>&1
    .venv/bin/python - "$tgt" <<'PY'
import sys
d = open('out/round84_fb.bin','rb').read()
n = sum(1 for b in d[:176*208*2] if b)
assert n == 0, n
PY
    grep -qE "^--- stop: (null call|pc left the image)" out/round84_$tgt.log
    echo "ok: $tgt -> no framebuffer pixels"
done

echo "ok: the adjacent EUser slot targets also fail to draw"
echo "ok: the blocker is the supervisor object/argument, not one slot value"
echo "PASS: round 84 rules out the EUser slot-neighbour sweep"
