#!/bin/sh
# test_round79.sh - scheduler auto-complete runs the EStart server thread.
#
# Round 78 got the scheduler to switch into the EStart server entry but the
# server blocked immediately on a wait.  Add NK_SCHED_AUTOCOMPLETE=1: after a
# switch, complete the blocked thread's status and make it runnable again.
#
# With the server body entry 0x503da675, EStart's server now runs the full
# 200,000-instruction budget in its own thread.  It ends in the EUser
# LDMDB/STMDB copy loop at 0x5038d724 with a wild destination
# (0x65d8b834 / 0x4b6d61f8), doing 646,007 MMIO reads and 642,561 writes.
#
# That is a new frontier: the scheduler/server path works, but the server's
# copy has a bad length/destination.  Framebuffer still has no pixels.
#
# Acceptance:
#   - fake thread entry 0x503da675;
#   - auto-complete log lines;
#   - stop budget at 0x5038d724;
#   - insns=200000, mmio 646007 reads / 642561 writes;
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

echo "== round 79: scheduler auto-complete runs the EStart server"
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
    NK_SCHED=1 NK_SCHED_MODE=arm NK_SCHED_FAKE=1 NK_SCHED_LR=0x5039865c \
    NK_SCHED_ENTRY=0x503da675 NK_SCHED_R0=0x8057ffc8 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_LOG=8 NK_SCHED_AUTOCOMPLETE=1 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round79_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round79_auto.log 2>&1

grep -q "sched: fake thread 0x80004600 pre-created for entry 0x503da675" out/round79_auto.log
grep -q "sched: auto-complete status 0x80530000" out/round79_auto.log
grep -q "^--- stop: budget (0) at 0x5038d724 ---" out/round79_auto.log
grep -q "insns=200000" out/round79_auto.log
grep -q "mmio: 646007 reads, 642561 writes" out/round79_auto.log

.venv/bin/python - <<'PY'
d = open('out/round79_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: NK_SCHED_AUTOCOMPLETE lets the EStart server run the full 200k"
echo "ok: it ends in the 0x5038d724 copy loop with a wild destination"
echo "    and 646,007 MMIO reads / 642,561 writes"
echo "ok: next task is the server copy length/destination, not the switch"
echo "PASS: round 79 runs the EStart server thread"
