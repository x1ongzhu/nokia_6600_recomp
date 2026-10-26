#!/bin/sh
# test_round68.sh - skip the EwSrv call; the direct app entry still doesn't draw.
#
# Direct dispatch reaches the app's EwSrv call at 0x509ef1e4.  The ROM
# EwSrv slot 0x506ce44c points at 0x506ca5e5 (mid-function), and snapping it
# to the prologue 0x506ca57f ends in the 0xb5f00000 thunk jump.  If we HLE
# the slot to the zero-return stub 0xffff0300 instead, the call returns
# cleanly and the app's static init completes (1694 instructions) without any
# framebuffer write.
#
# That is a negative result with a clear meaning: the direct SplashScreen
# entry path does not itself draw; the splash driver must be EStart, a
# kernel-created process/thread, or an active object, not this init call.
#
# Acceptance:
#   - stop returned (2) at 0xdead0000;
#   - insns=1694, mmio 0 reads / 0 writes;
#   - framebuffer dump has no non-zero pixel.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 68: HLE EwSrv slot; direct entry does not draw"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_SWI_EXCEPTION=0 NK_DFC_EMPTY=1 \
    NK_EWSRV_SNAP=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=200000 \
    NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
    NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_MAP_LCD=1 \
    NK_APP_IMPORTMAP=config/imports-app-main-alloc-6600.txt \
    NK_ENTRY=0x509eee85 NK_SP=0x80580000 \
    NK_POKE=0x506ce44c:0xffff0300 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round68_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round68_hle.log 2>&1

grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round68_hle.log
grep -q "insns=1694" out/round68_hle.log
grep -q "mmio: 0 reads, 0 writes" out/round68_hle.log

.venv/bin/python - <<'PY'
d = open('out/round68_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

# B. EStart direct entry: the likely splash driver, but its own importer is
#    not bound yet.  It null-calls after 119 instructions at lr=0x503da5b9
#    (r5=0xe59ff028) through the stub at 0x503db628 -> slot 0x503b6b38.
env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=20000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 NK_IRQ_LOG=0 NK_TIMERQ=1 \
    NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 NK_START_HLE=1 \
    NK_USER_SVC_KERNEL=1 NK_MAP_LCD=1 NK_ENTRY=0x503da4a5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round68_estart.log 2>&1

grep -q "^--- stop: null call (8) at 0000000000 ---" out/round68_estart.log
grep -q "lr=0x503da5b9" out/round68_estart.log
grep -q "r5=0xe59ff028" out/round68_estart.log
grep -q "insns=119" out/round68_estart.log

echo "ok: HLE-ing the EwSrv slot lets the direct app entry return cleanly"
echo "ok: it still writes no LCD pixel, so the direct init path is not the"
echo "    splash driver"
echo "ok: EStart.exe (entry 0x503da4a5) is the likely driver, but its own"
echo "    import slot 0x503b6b38 is unbound (null call at lr=0x503da5b9)"
echo "PASS: round 68 rules out the direct entry and opens the EStart route"
