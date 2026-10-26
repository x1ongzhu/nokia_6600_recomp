#!/bin/sh
# test_round63.sh - first app-side EUser import rebind.
#
# Round 62 ended at SplashScreen's static-init virtual dispatch:
#   operator new(4) -> 0x80600008 (vtable 0)
#   ldr r2,[0+8] -> 0xe59ff028, lr=0x509eef1f
#
# The app's import slot 0x503b4338 expects a CHeartbeat-style constructor:
# it later dispatches through the returned object's vtable+8 with r1=3.
# The ROM slot currently holds operator new (0x503963dc), which returns a
# zeroed object.  ROM export index 747 (0x50383c84) is the matching
# constructor: it allocates a 0x10-byte CBase, installs vtable 0x503b359c,
# allocates a 0x40-byte backing store, and performs the same vtable+8/r1=3
# call internally.
#
# NK_APP_IMPORTMAP rewrites only the app's named slots, after the flat image
# load.  It is deliberately separate from NK_IMPORTMAP (the kernel map), which
# patches shared EUser export slots and must be omitted for direct app runs.
#
# Acceptance:
#   - without the app map the run still stops at 0xe59ff028 (round-62
#     frontier);
#   - with the app map the rebind log shows 0x503b4338: 0x503963dc ->
#     0x50383c84;
#   - the app's static init completes and returns to 0xdead0000 in 360
#     instructions;
#   - 0x80600008 now holds vtable 0x503b359c (not 0), and the slot dump
#     confirms the rebind.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 63: app-side EUser import rebind"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

common() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=0 NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_EWSRV_SNAP=1 \
        NK_RECOVER=0 NK_CALL_INFER=0 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 \
        NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
        NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
        NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
        NK_TIMER=0 NK_TIMER_LOG=0 NK_CPSR=0x40000030 NK_IRQ_LOG=0 \
        NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
        NK_START_HLE=1 NK_USER_SVC_KERNEL=1 NK_MAP_LCD=1 \
        NK_ENTRY=0x509eee85 NK_SP=0x80580000 "$@"
}

# A. Control: no app rebind.
common NK_BUDGET=3000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round63_control.log 2>&1
grep -q "^--- stop: pc left the image (5) at 0xe59ff028 ---" out/round63_control.log
grep -q "lr=0x509eef1f" out/round63_control.log

# B. Rebind the app slot and run static init to completion.
common NK_BUDGET=5000 \
    NK_APP_IMPORTMAP=config/imports-app-6600.txt \
    NK_DUMP=0x80600000:0x80,0x503b4338:4 \
    NK_DUMP_FILE=out/round63_rebind.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round63_rebind.log 2>&1

grep -q "app import rebind: 0x503b4338 0x503963dc -> 0x50383c84" out/round63_rebind.log
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round63_rebind.log
grep -q "insns=360" out/round63_rebind.log
grep -q "r2=0x80600020 r3=0x503b359c" out/round63_rebind.log

.venv/bin/python - <<'PY'
import struct
d = open('out/round63_rebind.bin','rb').read()
vt = struct.unpack_from('<I', d, 8)[0]
slot = struct.unpack_from('<I', d, 0x80)[0]
assert vt == 0x503b359c, hex(vt)
assert slot == 0x50383c84, hex(slot)
print('ok: object 0x80600008 vtable = %#010x (CBase constructed)' % vt)
print('ok: app slot 0x503b4338 = %#010x (rebind persisted)' % slot)
PY

echo "ok: without the app map SplashScreen still crashes on the zero-vtable"
echo "    object at 0x509eef12 (round-62 frontier)"
echo "ok: the app-side rebind constructs the CBase (vtable 0x503b359c) and"
echo "    static init returns cleanly to 0xdead0000"
echo "ok: no framebuffer writes yet; the real splash main/active object is"
echo "    the next app-driven frontier"
echo "PASS: round 63 rebinds the first app EUser import"
