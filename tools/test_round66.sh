#!/bin/sh
# test_round66.sh - rebind the app's low allocator slot, remove 0xe59ff028.
#
# Round 64's main-path map reaches 0x509ef5fc, but its operator new(0x68)
# goes through EUser export index 2 (slot 0x503b379c).  The app expects
# User::Alloc; without the kernel map the ROM slot is a different low-ordinal
# function and returns 0.  The constructor result is then null and the
# TDes16 format path reads [0+0xc] = 0xe59ff028.
#
# This test uses a separate map (imports-app-main-alloc-6600.txt) that adds
# 0x503b379c -> 0x503988f0.  Acceptance:
#   - the rebind log lists all three slots;
#   - the run has 0 MMIO writes (the 0xe59ff028 writes are gone);
#   - it still stops in the 0x50314f78 self-loop, now the StartThread/SVC
#     frontier rather than a descriptor corruption;
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

echo "== round 66: app low allocator rebind"
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
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_MAP_LCD=1 \
    NK_APP_IMPORTMAP=config/imports-app-main-alloc-6600.txt \
    NK_ENTRY=0x509eee85 NK_SP=0x80580000 NK_BUDGET=200000 \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round66_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round66_main.log 2>&1

grep -q "app import rebind: 0x503b4338 0x503963dc -> 0x50383c84" out/round66_main.log
grep -q "app import rebind: 0x503b4980 0x50396ca8 -> 0x5038cae8" out/round66_main.log
grep -q "app import rebind: 0x503b379c 0x5038ee04 -> 0x503988f0" out/round66_main.log
grep -q "^--- stop: budget (0) at 0x50314f78 ---" out/round66_main.log
grep -q "mmio: 0 reads, 0 writes" out/round66_main.log
if grep -q "0xe59ff028" out/round66_main.log; then
    echo "FAIL: the 0xe59ff028 MMIO writes are back" >&2
    exit 1
fi

.venv/bin/python - <<'PY'
import struct
d = open('out/round66_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: the app-side low allocator slot 0x503b379c now returns a real"
echo "    User::Alloc pointer; operator new(0x68) no longer yields null"
echo "ok: the 0xe59ff028 descriptor/format writes are gone"
# C. Direct-dispatch control: bypass the banked SVC self-loop and show the
#    app main reaches EwSrv.  This is the alternative route for the next
#    round; with the EwSrv export slot 0x506ce44c snapped to 0x506ca57f it
#    hits the known 0xb5f00000 thunk jump.
env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1     NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_SWI_EXCEPTION=0 NK_DFC_EMPTY=1     NK_EWSRV_SNAP=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=5000     NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1     NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0     NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000     NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt     NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4     NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030     NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1     NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_MAP_LCD=1     NK_APP_IMPORTMAP=config/imports-app-main-alloc-6600.txt     NK_ENTRY=0x509eee85 NK_SP=0x80580000     NK_POKE=0x506ce44c:0x506ca57f     ./out/boot_kernel "$ROM" fw/6600_kernel.bin     --rom-image out/6600_runtime.bin >out/round66_direct.log 2>&1

grep -q "^--- stop: pc left the image (5) at 0xb5f00000 ---" out/round66_direct.log
grep -q "insns=1574" out/round66_direct.log
grep -q "r3=0xb5f00000" out/round66_direct.log

echo "ok: the remaining blocker is the app main's StartThread/SVC path,"
echo "    still self-looping at 0x50314f78"
echo "ok: direct dispatch bypasses that loop and reaches EwSrv; the EwSrv"
echo "    thunk still jumps to 0xb5f00000 (next round's target)"
echo "PASS: round 66 removes the null-descriptor corruption"
