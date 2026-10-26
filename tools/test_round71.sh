#!/bin/sh
# test_round71.sh - EStart global CBase rebind advances past zero-vtable.
#
# EStart's 0x503dac3c function calls slot 0x503b4338 to get a global object
# (r5=0x80600000), then calls vtable+8.  The unpatched ROM slot is operator
# new, so [r5] is zero and vtable+8 reads 0xe59ff028.  Binding it to the
# CBase constructor 0x50383c84 gives the object vtable 0x503b359c and moves
# EStart from 12,136 to 13,162 instructions.
#
# The next frontier is a bad virtual dispatch: 0x503ce69c bx r1 with
# r1=0x00a04d08 (not code).  r1 comes from [r0+0xc] where r0=[r4+0x14], so
# the forced generic CBase vtable is not the app's real class vtable.
#
# Acceptance:
#   - rebind log has 0x503b4338 -> 0x50383c84 and 0x503b6b38 -> 0x503b53f5;
#   - stop pc left image at 0x00a04d08;
#   - insns=13162, mmio 1,720 reads / 0 writes;
#   - lr=0x503ce6a1, r1=0x00a04d08;
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

echo "== round 71: EStart global CBase rebind"
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
    NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round71_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round71_estart.log 2>&1

grep -q "app import rebind: 0x503b4338 0x503963dc -> 0x50383c84" out/round71_estart.log
grep -q "app import rebind: 0x503b6b38 0000000000 -> 0x503b53f5" out/round71_estart.log
grep -q "^--- stop: pc left the image (5) at 0x00a04d08 ---" out/round71_estart.log
grep -q "insns=13162" out/round71_estart.log
grep -q "r1=0x00a04d08" out/round71_estart.log
grep -q "lr=0x503ce6a1" out/round71_estart.log

.venv/bin/python - <<'PY'
d = open('out/round71_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: rebinding EStart slot 0x503b4338 gives the global object a real"
echo "    vtable and moves EStart from 12,136 to 13,162 instructions"
echo "ok: the new frontier is a bad virtual dispatch at lr=0x503ce6a1"
echo "    (bx r1 with r1=0x00a04d08), so the forced generic CBase vtable"
echo "    is not EStart's real class vtable"
echo "PASS: round 71 advances EStart past the zero-vtable object"
