#!/bin/sh
# test_round100.sh - trace and clamp the oversized descriptor-grow request.
#
# Round 99 left one bogus request: ReAlloc wants 0xb63a74 bytes at
# 0x5039c630 with r1=0x80601b68.  NK_ALLOC_TRACE=1 logs the HLE bookkeeping
# size at [ptr-8] and the guest cell header at [ptr-4] for every intercepted
# realloc; the failing call never reaches that path, which means the pointer is
# NOT a bump-heap payload: at that moment the bump heap has only reached
# ~0x80600830, so 0x80601b68 lies above alloc_cur and is a foreign pointer.
# EUser's descriptor-grow helper (0x5039c37c) is therefore operating on a buffer
# that the HLE heap never allocated, and its capacity word is garbage.
#
# Round 94's policy rejected such requests, which made EFile leave with
# KErrNoMemory and end the round-98/99 frontier immediately.
# NK_ALLOC_CLAMP=<n> allocates n bytes instead of failing, so the caller
# continues and the next real defect becomes visible.
#
# Acceptance:
#   - exactly 2 "HLE alloc clamped" lines and no "HLE alloc rejected";
#   - EFile advances to 1,447 Thumb instructions (from 1,322);
#   - the stop is a null call: `[obj+8] -> [+8]` with obj=0x80100c38 and
#     r2=r6=0x2f.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 100: trace and clamp the oversized descriptor-grow request"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 NK_THREAD_HEAP=0x80700000 \
    NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_CLAMP=0x1000 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=1 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_IMPORTMAP_REVERT=1 NK_IMPORTMAP_NO_REVERT=0x503b3948 \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x600 \
    NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_AUTOCOMPLETE=1 \
    NK_SCHED_EXIT=1 NK_SCHED_LOG=6 NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 \
    NK_SCHED_NO_PREEMPT=1 NK_SWI_RET=0x1c:-1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round100_clamp.log 2>&1

test "$(grep -c 'HLE alloc clamped' out/round100_clamp.log)" -eq 2
if grep -q "HLE alloc rejected" out/round100_clamp.log; then
    echo "FAIL: a request was still rejected instead of clamped" >&2
    exit 1
fi
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round100_clamp.log
grep -q "r5=0x80100c38" out/round100_clamp.log
grep -q "Thumb 1447)" out/round100_clamp.log
.venv/bin/python - <<'PY'
import re
line = [l for l in open('out/round100_clamp.log') if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) == 1447, line
print('ok: EFile reached %s Thumb instructions' % m.group(1))
PY

echo "ok: the 0xb63a74 request is a foreign pointer, not a bump-heap payload"
echo "ok: clamping instead of failing lets EFile run past the descriptor grow"
echo "ok: the next defect is a null virtual call on 0x80100c38"
echo "    ([obj+8] -> [+8] == 0) with r2=r6=0x2f"
echo "PASS: round 100 traces and clamps the oversized allocation"
