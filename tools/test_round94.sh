#!/bin/sh
# test_round94.sh - EFile gets past the kernel start hand-off, then follows a
# null heap pointer.
#
# Two harness fixes:
#
#  1. NK_HANDOFF_ARM=1.  DThread::StartThread (vtable+0x20 = 0x50321088)
#     stores its argument at this+0xf8 and tail-branches to the kernel start
#     hand-off 0x50318398, which consumes the pending TRequestStatus at
#     [0x80001784].  After the first switch that slot was already consumed, so
#     the hand-off raised a PLAT fault with reason 0x73 and the kernel halted
#     at 0x50312b88.  Re-arming the slot before the hand-off removes that
#     fault and EFile now runs into the EUser heap instead.
#
#  2. NK_ALLOC_MAX (default 0x100000).  EFile called ReAlloc with a byte count
#     of 0x503c7168 - one of its own rodata table addresses - which used to
#     poison the bump heap and be reported as a bogus "undefined instruction".
#     Such requests now fail cleanly (the guest sees a null result).
#
# After fix 2 the guest follows the null result and leaves the image at 0x2c,
# which is the next frontier.
#
# Acceptance:
#   - no PLAT fault / no halt at 0x50312b88;
#   - "HLE alloc rejected: 0x503c7168" is logged;
#   - stop reason is "pc left the image" at 0x0000002c;
#   - Thumb instruction count > 1000 (EFile really ran).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 94: EFile passes the kernel start hand-off"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 \
    NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 NK_SCHED_STACK=0x80560000 \
    NK_SCHED_STACK_EXTRA=0x400 NK_SCHED_STACK_FILL=0xdead0000 \
    NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=6 \
    NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round94_efile.log 2>&1

grep -q "handoff arm: re-arm \[0x80001784\]" out/round94_efile.log
if grep -q "self-branch (panic halt)" out/round94_efile.log; then
    echo "FAIL: the PLAT-fault halt is back" >&2
    exit 1
fi
grep -q "HLE alloc rejected: 0x503c7168 bytes" out/round94_efile.log
grep -q "^--- stop: pc left the image (5) at 0x0000002c ---" out/round94_efile.log
.venv/bin/python - <<'PY'
import re
line = [l for l in open('out/round94_efile.log') if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) > 1000, line
print('ok: EFile executed %s Thumb instructions' % m.group(1))
PY

echo "ok: re-arming [0x80001784] removes the PLAT-fault 0x73 halt at 0x50312b88"
echo "ok: the pointer-sized ReAlloc (0x503c7168 bytes) now fails cleanly"
echo "ok: the next frontier is the null heap pointer the guest follows to 0x2c"
echo "PASS: round 94 pushes EFile through the kernel start hand-off"
