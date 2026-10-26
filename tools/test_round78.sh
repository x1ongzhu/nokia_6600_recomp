#!/bin/sh
# test_round78.sh - fake scheduler thread reaches EStart's server entry.
#
# The existing NK_SCHED model only knows the kernel NULL thread.  Pre-create
# a scheduler slot at 0x80004600 (NK_SCHED_FAKE=1), point the scheduler's
# next-thread global at it, and give it the EStart server entry
# (0x503db158) and a stack.  On the first wait, the scheduler now switches
# away from the supervisor into that thread instead of reporting "no runnable
# thread".
#
# The server entry runs ~100 instructions and then null-calls at
# 0x503db18f: it calls stub 0x503db454 -> slot 0x503b3d14 -> 0x503a2960
# with a missing argument/object and lands at pc=0.  That is a new frontier:
# the scheduler path works, but the server's first import/argument is not
# recovered yet.
#
# Acceptance:
#   - stop null call at 0;
#   - insns=410, lr=0x503db18f, r1=0x0000000d;
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

echo "== round 78: fake scheduler thread reaches EStart's server entry"
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
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x503da4a5 NK_SP=0x80580000 NK_MAP_LCD=1 \
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_WAIT_HLE=1 \
    NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_LR=0x5039865c \
    NK_SCHED_ENTRY=0x503db158 NK_SCHED_STACK=0x80560000 NK_SCHED_LOG=8 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round78_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round78_sched.log 2>&1

grep -q "sched: fake thread 0x80004600 pre-created" out/round78_sched.log
grep -q "sched: first switch -> NULL thread 0x80004600" out/round78_sched.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round78_sched.log
grep -q "insns=410" out/round78_sched.log
grep -q "lr=0x503db18f" out/round78_sched.log
grep -q "r1=0x0000000d" out/round78_sched.log

.venv/bin/python - <<'PY'
d = open('out/round78_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: NK_SCHED_FAKE lets the scheduler switch into EStart's server"
echo "    thread instead of reporting 'no runnable thread'"
echo "ok: the server entry then null-calls at 0x503db18f through"
echo "    0x503db454 -> slot 0x503b3d14 -> 0x503a2960"
echo "ok: next task is that server import/argument, not the scheduler switch"
echo "PASS: round 78 reaches the EStart server entry"
