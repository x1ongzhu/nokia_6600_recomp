#!/bin/sh
# test_round95.sh - kernel-time import rebinds must not leak into an app thread.
#
# EUser's export table doubles as the import slot table for every ROM image:
# a ROM importer's stub is `ldr rX,[pc]; ldr rX,[rX]; bx rX` and the literal
# points straight at an EUser .edata entry.  config/imports-r29-6600.txt
# rebinds 236 of those entries so that the kernel (linked against a different
# EUser .def) calls the functions it expects.  An application running in the
# same boot then calls the wrong EUser function with its own arguments:
# EFile passed 0x503bfcf3 (a code address) and 0x503c7148 (its ctor table) as
# descriptor lengths, which grew a buffer to 0x503c7168 bytes and tripped the
# round-94 allocation cap.
#
# NK_IMPORTMAP_REVERT=1 records each original slot value while patching and
# restores all of them when the first application thread is resumed.
#
# Acceptance:
#   - control run: "HLE alloc rejected: 0x503c7168 bytes" appears;
#   - revert run: "importmap: reverted 236 kernel-time rebinds" and no
#     allocation rejection at all;
#   - revert run reaches the instruction budget;
#   - both runs: the kernel hand-off arm and the Thumb entry are active.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 95: keep kernel-time import rebinds out of the app thread"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_efile() {
    log=$1; shift
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
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

run_efile out/round95_control.log
run_efile out/round95_revert.log NK_IMPORTMAP_REVERT=1

grep -q "HLE alloc rejected: 0x503c7168 bytes" out/round95_control.log
if grep -q "HLE alloc rejected" out/round95_revert.log; then
    echo "FAIL: an allocation was still rejected with the rebinds reverted" >&2
    exit 1
fi
grep -q "importmap: reverted 236 kernel-time rebinds for the app thread" out/round95_revert.log
grep -q "^--- stop: budget (0)" out/round95_revert.log
grep -q "handoff arm: re-arm \[0x80001784\]" out/round95_revert.log
grep -q "cpsr 0x40000073" out/round95_revert.log
grep -q "Thumb 868)" out/round95_revert.log

echo "ok: the kernel map rewrites 236 EUser export slots that an app also uses"
echo "ok: without the revert EFile grows a buffer to 0x503c7168 bytes"
echo "ok: with NK_IMPORTMAP_REVERT=1 no allocation is anomalous; EFile reaches"
echo "    a blocking wait after 868 Thumb instructions and the boot continues"
echo "    to the budget"
echo "PASS: round 95 separates kernel-time and app-time import resolution"
