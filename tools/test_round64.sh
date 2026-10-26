#!/bin/sh
# test_round64.sh - the app main path and the kernel SVC-return blocker.
#
# Round 63's default app map rebinds 0x503b4338, constructs the static CBase,
# and returns cleanly (no drawing).  This test rebinds the second slot,
# 0x503b4980 (TTrap wrapper), to TTrap::Trap at 0x5038cae8.  The app then
# takes the 0x509ef5fc main/constructor path instead of the early return.
#
# That path exposes the next blocker:
#   - the first SVC 0x6c (User::Alloc, 0x503988f8) actually returns
#     correctly (0x50314f78 -> bx lr -> 0x503988fc);
#   - two MMIO writes to 0xe59ff028/0xe59ff02c come from 0x50383c74/7c
#     (caller 0x50383ec0, cleanup destination r5=0xe59ff028);
#   - after that, a later SVC falls into the 0x50314f78 bx-lr self-loop
#     with lr=0x50314f78;
#   - NK_USER_SVC_KERNEL=2 clears bit 23 on all 9 EUser SVC stubs, but does
#     not fix the loop.
#
# Acceptance:
#   - the rebind log lists both app slots;
#   - the run stops at the budget at 0x50314f78 (self-loop);
#   - the 0xe59ff028 MMIO writes are present;
#   - the framebuffer dump has no app pixels.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 64: app main path and kernel SVC return"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 \
    NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 NK_IRQ_LOG=0 \
    NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_START_HLE=1 NK_USER_SVC_KERNEL=2 NK_MAP_LCD=1 \
    NK_APP_IMPORTMAP=config/imports-app-main-6600.txt \
    NK_ENTRY=0x509eee85 NK_SP=0x80580000 NK_BUDGET=2000 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round64_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round64_main.log 2>&1

grep -q "app import rebind: 0x503b4338 0x503963dc -> 0x50383c84" out/round64_main.log
grep -q "app import rebind: 0x503b4980 0x50396ca8 -> 0x5038cae8" out/round64_main.log
grep -q "user SVC kernel patch: 9 SVC stubs (all)" out/round64_main.log
grep -q "^--- stop: budget (0) at 0x50314f78 ---" out/round64_main.log
grep -q "mmio: 0 reads, 2 writes" out/round64_main.log
grep -q "write 0xe59ff028" out/round64_main.log

.venv/bin/python - <<'PY'
import struct
d = open('out/round64_fb.bin','rb').read()
# The app wrote no pixel.  The harness's earlier HLE frame is not present
# here; the dump is the untouched framebuffer.
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer still untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: rebinding the TTrap slot makes SplashScreen take the 0x509ef5fc"
echo "    main/constructor path instead of returning after static init"
echo "ok: the first SVC 0x6c returns correctly; after the 0xe59ff028"
echo "    cleanup/destination writes, a later SVC self-loops at 0x50314f78"
echo "ok: clearing bit 23 on all EUser SVC stubs does not fix the loop;"
echo "    the next task is the 0xe59ff028 descriptor/cleanup target"
echo "PASS: round 64 exposes the app main path and the SVC-return blocker"
