#!/bin/sh
# test_round69.sh - bind EStart's first unresolved import.
#
# EStart.exe direct entry null-calls after 119 instructions through slot
# 0x503b6b38.  The slot belongs to uid3 0x100039e8; the image's real export
# table is at 0x503b6b30 (0x503b53f5 twice), while the header's export_dir
# 0x503b6b38/ordinal 2 is zero.  Bind it with imports-estart-6600.txt.
#
# Acceptance:
#   - EStart runs the 200k budget instead of null-calling at 119;
#   - it stops at 0x50314f68 (SVC pre-handler path);
#   - mmio 0 reads / 0 writes, framebuffer 0 pixels;
#   - the app import rebind log shows 0x503b6b38 -> 0x503b53f5.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 69: bind EStart's first unresolved import"
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
    NK_START_HLE=1 NK_USER_SVC_KERNEL=1 \
    NK_APP_IMPORTMAP=config/imports-estart-6600.txt \
    NK_DUMP=0x59800000:0x400000 NK_DUMP_FILE=out/round69_fb.bin \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round69_estart.log 2>&1

grep -q "app import rebind: 0x503b6b38 0000000000 -> 0x503b53f5" out/round69_estart.log
grep -q "^--- stop: budget (0) at 0x50314f68 ---" out/round69_estart.log
grep -q "insns=200000" out/round69_estart.log
grep -q "mmio: 0 reads, 0 writes" out/round69_estart.log

.venv/bin/python - <<'PY'
d = open('out/round69_fb.bin','rb').read()
assert len(d) == 0x400000
nonzero = sum(1 for b in d[:176*208*2] if b)
assert nonzero == 0, nonzero
print('ok: framebuffer untouched (%d non-zero bytes)' % nonzero)
PY

echo "ok: binding EStart slot 0x503b6b38 lets it run the full 200k budget"
echo "    instead of null-calling at 119 instructions"
echo "ok: it now sits in the kernel SVC/pre-handler path at 0x50314f68"
echo "ok: no framebuffer pixels yet; next task is the wait/thread it blocks on"
echo "PASS: round 69 binds EStart's first unresolved import"
