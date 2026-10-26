#!/bin/sh
# test_round36.sh - MMIO provenance, and ruling out the 0x41000000 scan as
# the LCD framebuffer.
#
# Round 35 left the Init2 deadlock at RThread::Resume(0x32).  While looking
# for the display controller, the MMIO trace showed a large 16-bit fill of
# 0xffff at 0x41080000..0x41083fff and control writes at 0x41000300/0x41000304.
# Those looked like an LCD buffer, but they are the kernel's boot-region
# descriptor table: 0x41000000 holds the source descriptors, 0x41080000 the
# copied 4-byte entries (two 16-bit fields per region).  The writer is
# 0x503164cc / 0x503164d0 in the kernel, reached from 0x503163f4.
#
# This round adds PC/LR provenance to the MMIO write log (the 16-bit stores
# were invisible to the word write-watch) and pins the finding so the display
# search does not chase the region table again.
#
# Acceptance:
#   - the first 0x41080000 store is logged with pc=0x503164cc and
#     lr=0x503163f4;
#   - the 0x41000300 control write is logged with pc=0x50310bc8;
#   - the boot still reaches the 6M budget with no undefined/unbound/recovery.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 36: MMIO write provenance"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=6000000 \
    NK_MMIO_N=100000 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 NK_EXT_STUB=1 \
    NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
    NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 NK_SCHED_DEFER=1 NK_SCHED_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round36_mmio.log 2>&1

grep -q "write 0x41080000 = 0 (2) pc=0x503164cc lr=0x503163f4" \
    out/round36_mmio.log
grep -q "write 0x41000300 = 0xc000432 (4) pc=0x50310bc8" \
    out/round36_mmio.log
if grep -q "null call\|panic halt\|pc left the image" out/round36_mmio.log; then
    echo "FAIL: boot faults during the MMIO provenance run" >&2
    tail -40 out/round36_mmio.log >&2
    exit 1
fi
insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round36_mmio.log)
if [ -z "$insns" ] || [ "$insns" != "5999983" ]; then
    echo "FAIL: boot stopped at ${insns:-0} insns, expected 5999983" >&2
    tail -40 out/round36_mmio.log >&2
    exit 1
fi

echo "ok: MMIO writes now carry the writing PC/LR (16-bit stores included)"
echo "ok: the 0x41080000 fill is written at 0x503164cc (kernel boot-region"
echo "    table), not by an LCD driver"
echo "ok: 0x41000300/0x41000304 are the region-descriptor control words"
echo "    written at 0x50310bc8"
echo "ok: the 6M boot is unchanged (5,999,983 insns, no faults)"
echo "PASS: round 36 rules out the 0x41000000 scan as the framebuffer and"
echo "      leaves the LCD driver hunt to the real display path"
