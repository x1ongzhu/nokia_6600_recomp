#!/bin/sh
# test_round82.sh - server returns, supervisor resumes, still hits 0x00a04d08.
#
# Round 81's server epilogue popped 0 because its frame sat outside the fake
# stack.  Add NK_SCHED_STACK_EXTRA (map/fill extra words above the initial sp)
# plus NK_SCHED_EXIT (when a fake thread returns to 0xdead0000, retire it and
# resume the supervisor).  With a 0x100-word sentinel extension:
#
#   - the server returns cleanly to 0xdead0000 after 26,652 instructions;
#   - the scheduler resumes the supervisor;
#   - the supervisor then hits the old 0x00a04d08 bad dispatch at 29,295
#     instructions, with 3,441 MMIO reads / 22,928 writes.
#
# So the server run/return path works; the supervisor's 0x00a04d08 dispatch
# is still the blocker.  Framebuffer has no pixels.
#
# Acceptance:
#   - stop pc left image at 0x00a04d08;
#   - insns=29295, mmio 3441 reads / 22928 writes;
#   - sched slot 0x80004600 state=0 (retired);
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

echo "== round 82: server returns, supervisor resumes"
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
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round82_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round82_exit.log 2>&1

grep -q "^--- stop: pc left the image (5) at 0x00a04d08 ---" out/round82_exit.log
grep -q "insns=29295" out/round82_exit.log
grep -q "mmio: 3441 reads, 22928 writes" out/round82_exit.log
grep -q "\[0x80004600 state=0" out/round82_exit.log

.venv/bin/python - <<'PY'
d = open('out/round82_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: the extra sentinel extension lets the EStart server return cleanly"
echo "ok: NK_SCHED_EXIT retires the server and resumes the supervisor"
echo "ok: the supervisor then hits 0x00a04d08 after 29,295 instructions"
echo "ok: the 0x00a04d08 dispatch is still the next blocker"
echo "PASS: round 82 completes the server run/return cycle"
