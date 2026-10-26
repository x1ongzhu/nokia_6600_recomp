#!/bin/sh
# test_round86.sh - replacing the supervisor's [this+0x14] still leaves.
#
# At 0x503ce696, before EUser loads [this+0x14], the new
# NK_SUPERVISOR_OBJECT_FIX hook writes the B7e vtable (0x80003040) there.
# The 0x00a04d08 code-address dispatch disappears, but the +0xc method
# becomes the B7e zero-return stub, so the supervisor enters the EUser
# TTrap/leave path at lr=0x5038cb70 after 30,988 instructions.
#
# So the fix is not just a valid-looking vtable pointer: the object needs
# its real class vtable/method.  Framebuffer still has no pixels.
#
# Acceptance:
#   - supervisor object fix log line;
#   - stop null call at 0;
#   - insns=30988, mmio 3442 reads / 22928 writes;
#   - lr=0x5038cb70, r1=0xfffffff8;
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

echo "== round 86: supervisor [this+0x14] object fix still leaves"
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
    NK_SUPERVISOR_OBJECT_FIX=1 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round86_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round86_objfix.log 2>&1

grep -q "supervisor object fix: \[this+0x14\] -> B7e vtable" out/round86_objfix.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round86_objfix.log
grep -q "insns=30988" out/round86_objfix.log
grep -q "mmio: 3442 reads, 22928 writes" out/round86_objfix.log
grep -q "lr=0x5038cb70" out/round86_objfix.log
grep -q "r1=0xfffffff8" out/round86_objfix.log

.venv/bin/python - <<'PY'
d = open('out/round86_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: writing the B7e vtable into [this+0x14] removes 0x00a04d08"
echo "ok: but the zero-return +0xc method then enters TTrap/leave"
echo "ok: the object needs its real class vtable/method, not a stand-in"
echo "PASS: round 86 rules out the vtable-pointer-only object fix"
