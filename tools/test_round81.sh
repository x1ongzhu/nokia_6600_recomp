#!/bin/sh
# test_round81.sh - a return sentinel alone does not fix the server epilogue.
#
# Round 80's server reaches 0x503da6ee (bx r0) with r0=0.  That is the
# epilogue of the server body at 0x503da674: it pops {r4,r5,r6} then pops
# the return address into r0.  The fake scheduler stack was zero-filled, so
# the pop yields 0 and the bx null-calls.
#
# Fill the fake stack with 0xdead0000 (NK_SCHED_STACK_FILL) instead.  The
# epilogue still pops 0 (sp=0x80562020 is outside the 0x80560000..0x80562000
# fake stack), so the entry needs a real StartThread frame/callback, not a
# sentinel.
#
# Acceptance:
#   - same stop null call at 0;
#   - insns=26652, mmio 3441 reads / 22928 writes;
#   - lr=0x503da6d5, r3=0xe59ff028;
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

echo "== round 81: stack sentinel does not fix the server epilogue"
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
    NK_SCHED=1 NK_SCHED_MODE=arm NK_SCHED_FAKE=1 NK_SCHED_LR=0x5039865c \
    NK_SCHED_ENTRY=0x503da675 NK_SCHED_R0=0x8057ffc8 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_LOG=8 NK_SCHED_AUTOCOMPLETE=1 \
    NK_MEMCOPY_CLAMP=1 NK_SCHED_STACK_FILL=0xdead0000 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round81_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round81_fill.log 2>&1

grep -q "^--- stop: null call (8) at 0000000000 ---" out/round81_fill.log
grep -q "insns=26652" out/round81_fill.log
grep -q "mmio: 3441 reads, 22928 writes" out/round81_fill.log
grep -q "lr=0x503da6d5" out/round81_fill.log
grep -q "r3=0xe59ff028" out/round81_fill.log

.venv/bin/python - <<'PY'
d = open('out/round81_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: filling the fake stack with 0xdead0000 still leaves r0=0 at"
echo "    the 0x503da6ee epilogue (sp=0x80562020 is outside the stack)"
echo "ok: the server entry needs a real StartThread frame/callback, not"
echo "    just a return sentinel"
echo "PASS: round 81 rules out the stack-sentinel shortcut"
