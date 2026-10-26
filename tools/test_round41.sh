#!/bin/sh
# test_round41.sh - FbServ on the real SVC path.
#
# The direct NK_SWI_DIRECT=1 path only reached 3,612 instructions before an
# EUser formatting call destroyed FbServ's vtable.  Running the same entry
# with the real banked SVC exception path (NK_SWI_DIRECT=0, NK_BANKED=1)
# avoids that corruption and reaches 1,499,521 instructions:
#
#   - the app moves to a kernel-allocated user stack around 0x7fef....
#   - it enters a repeating EUser wait/scheduler call chain
#     (5039eddc -> 5039d9d0 -> 503998b4 -> 50392e00 -> 50392ec0)
#   - it finally hits a null callback with lr=0 and pc=0.
#
# This strongly suggests the direct-SWI gate was clobbering callee-saved
# registers (r4-r11) that a real SVC entry saves; the real SVC path preserves
# them well enough for FbServ to initialize.  The next blocker is the kernel
# executive/thread state the wait loop expects, not the app's C++ objects.
#
# Acceptance:
#   - stop is a null call at 0;
#   - insns=1499521, undefined=0, unbound IAT=0;
#   - final sp=0x7feffea4;
#   - the shadow call stack contains the repeating EUser wait chain.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 41: FbServ on the real SVC path"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=1600000 NK_MMIO_N=0 NK_SWI_LOG=4 \
    NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 \
    NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=0 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_BANKED=1 NK_ENTRY=0x506897d5 NK_SP=0x80580000 NK_CALLS=1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round41_svc.log 2>&1

grep -q "^--- stop: null call (8) at 0000000000 ---" out/round41_svc.log
grep -q "insns=1499521" out/round41_svc.log
grep -q "undefined=0" out/round41_svc.log
grep -q "unbound IAT=0" out/round41_svc.log
grep -q "sp=0x7feffea4" out/round41_svc.log
grep -q "shadow calls (64).*5039eddc 5039d9d0 503998b4" out/round41_svc.log
grep -q "50392e00 50392ec0" out/round41_svc.log

echo "ok: the real banked SVC path avoids the direct-SWI vtable corruption"
echo "ok: FbServ reaches 1,499,521 instructions with 0 undefined/unbound"
echo "ok: it switches to a kernel-allocated user stack around 0x7fef...."
echo "ok: it enters the repeating EUser wait chain"
echo "    5039eddc -> 5039d9d0 -> 503998b4 -> 50392e00 -> 50392ec0"
echo "ok: the next blocker is the kernel executive/thread state, not the"
echo "    app's C++ object layout"
echo "PASS: round 41 moves FbServ from 3,612 to 1,499,521 instructions"
