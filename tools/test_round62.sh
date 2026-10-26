#!/bin/sh
# test_round62.sh - app-entry foundations: allocator header, thread start,
# and the shared EUser export-table conflict.
#
# Round 62 follows the real SplashScreen entry instead of the harness's
# logo-frame shortcut.  Three concrete findings are pinned here:
#
# 1. The bring-up HLE allocator stored 'HLEH' in the word at [payload-4].
#    Guest RHeap::ReAlloc reads that word as the cell size, so it turned the
#    first realloc into a 0x484c4544-byte Mem::Copy (round-62 B7e log).  The
#    header is now compatible: [payload-8] is the HLE size, [payload-4] is
#    the guest cell size (payload+4).
#
# 2. SplashScreen calls Kern::StartThread (SVC 0x76) and polls its
#    TRequestStatus.  The bring-up DThread vtable+0x20 used to return without
#    completing it, so the app spun forever.  NK_START_HLE=1 completes [r3];
#    NK_USER_SVC_KERNEL=1 clears bit 23 on the EUser SVC 0x76 stub so the
#    kernel service table actually dispatches StartThread.
#
# 3. The kernel's EUser import map (config/imports-r29-6600.txt) patches
#    *shared* EUser export-table slots, e.g. 0x503b4f10.  The kernel needs
#    the patch because it was linked against a different EUser .def, but
#    SplashScreen's imports use the same slots: the app then sees
#    0x5038918c instead of its own export 0x50389180.  Direct-app runs must
#    not apply the kernel map; this is why the old app tests (which set
#    NK_IMPORTMAP) wandered into wild descriptors and zero vtables.
#
# Acceptance:
#   - with the kernel map, the app reaches EwSrv 0x506ca5e4 instead of the
#     0x484c4289 wild copy;
#   - without the kernel map, EUser export 0x503b4f10 stays 0x50389180 and
#     the app reaches the next frontier: a zero-vtable object at 0x80600008
#     (virtual dispatch reads 0xe59ff028), lr=0x509eef1f;
#   - the two 0-instruction dumps prove the shared-slot patch difference.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 62: app-entry allocator/thread/import fixes"
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
        NK_START_HLE=1 NK_USER_SVC_KERNEL=1 \
        NK_ENTRY=0x509eee85 NK_SP=0x80580000 "$@"
}

# A. Kernel-map run: verify the allocator no longer produces 0x484c4289 and
#    that StartThread completion advances the app into EwSrv.
common NK_BUDGET=5000 NK_MAP_LCD=1 \
    NK_IMPORTMAP=config/imports-r29-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round62_map.log 2>&1

grep -q "thread-start HLE: bring-up DThread vtable+0x20 completes" out/round62_map.log
grep -q "user SVC kernel patch: 1 SVC stubs (0x76 only)" out/round62_map.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round62_map.log
grep -q "506ca5e4 506ca5e4 506ca5e8" out/round62_map.log
if grep -q "484c4289" out/round62_map.log; then
    echo "FAIL: the 0x484c4289 wild realloc length is back" >&2
    exit 1
fi

# B. Corrected direct-app run: no kernel EUser map, so the app's shared EUser
#    slots stay as linked.  The app now reaches its zero-vtable object.
common NK_BUDGET=2000 NK_MAP_LCD=1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round62_app.log 2>&1

grep -q "^--- stop: pc left the image (5) at 0xe59ff028 ---" out/round62_app.log
grep -q "r0=0x80600008 r1=0x00000003 r2=0xe59ff028" out/round62_app.log
grep -q "lr=0x509eef1f" out/round62_app.log
if grep -q "484c4289" out/round62_app.log; then
    echo "FAIL: the 0x484c4289 wild realloc length is back" >&2
    exit 1
fi

# C/D. Prove the shared EUser export-slot conflict with two 0-instruction runs.
common NK_BUDGET=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_DUMP=0x503b4f10:4 NK_DUMP_FILE=out/round62_slot_map.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round62_slot_map.log 2>&1
common NK_BUDGET=0 \
    NK_DUMP=0x503b4f10:4 NK_DUMP_FILE=out/round62_slot_app.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round62_slot_app.log 2>&1

.venv/bin/python - <<'PY'
import struct
m = struct.unpack('<I', open('out/round62_slot_map.bin','rb').read())[0]
a = struct.unpack('<I', open('out/round62_slot_app.bin','rb').read())[0]
assert m == 0x5038918c, hex(m)
assert a == 0x50389180, hex(a)
print('ok: kernel map rewrites shared EUser slot 0x503b4f10 -> %#010x' % m)
print('ok: without the map the app still sees its linked export -> %#010x' % a)
PY

echo "ok: the allocator cell header no longer becomes a wild Mem::Copy length"
echo "ok: NK_START_HLE + NK_USER_SVC_KERNEL advance SplashScreen past the"
echo "    StartThread status wait"
echo "ok: kernel import-map patches share the EUser export table with apps;"
echo "    direct app runs must skip it"
echo "PASS: round 62 fixes the app-entry allocator/thread/import foundations"
