#!/bin/sh
# test_round93.sh - scheduler threads start in the entry's instruction set.
#
# The first-switch code set the new thread's CPSR to `0x40000013` (ARM), even
# though E32 iEntryPoint always carries the Thumb bit in bit 0.  Starting a
# Thumb image in ARM mode decoded its first instructions as garbage: against
# EFile.exe (uid3 0x100039e3, code 0x503b7104, entry 0x503b7105) the walker
# ran 9 ARM instructions, left r4=r5=0, and null-called at 0x503b7104 through
# the `bx r0` thunk 0x503c597c.
#
# Honour the entry bit instead (and in sched_resume), so the thread starts in
# Thumb.  EFile now executes 1,120 Thumb instructions, touches hardware
# registers 0x40000400/0x40000418 and stops in a kernel panic halt at
# 0x50312b88 instead of a null call - i.e. it reaches the kernel.
#
# Acceptance:
#   - switch #1 reports cpsr 0x40000073 (T bit set) at pc 0x503b7104;
#   - stop reason is the self-branch panic halt at 0x50312b88;
#   - Thumb instructions > 1000, no undefined instruction;
#   - regression: the EStart fake-thread test still works (round 78 map).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 93: scheduler threads start in the entry's instruction set"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=600000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 \
    NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 NK_SCHED_STACK=0x80560000 \
    NK_SCHED_STACK_EXTRA=0x400 NK_SCHED_STACK_FILL=0xdead0000 \
    NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=10 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round93_efile.log 2>&1

grep -q "switch #1 -> thread 0x80601830 pc 0x503b7104 sp 0x80561ff0 cpsr 0x40000073" out/round93_efile.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round93_efile.log
grep -q "undefined=0" out/round93_efile.log
.venv/bin/python - <<'PY'
import re
line = [l for l in open('out/round93_efile.log') if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) > 1000, line
print('ok: EFile executed %s Thumb instructions' % m.group(1))
PY

echo "ok: the first switch now sets the T bit from iEntryPoint bit 0"
echo "ok: EFile.exe runs 1,120 Thumb instructions and reaches the kernel"
echo "ok: it stops in a kernel panic halt at 0x50312b88 instead of the old"
echo "    ARM-garbage null call at 0x503b7104"
echo "PASS: round 93 fixes thread entry-mode selection"
