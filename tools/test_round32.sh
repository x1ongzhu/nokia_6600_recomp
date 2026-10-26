#!/bin/sh
# test_round32.sh - the bootstrap SThread is not the live thread.
#
# Round 31's frontier (a null cleanup object at 0x503a6148) was not a missing
# TTrap/CTrapCleanup field.  TTrap is 0x4c bytes: iState[0x10] at +0x00..+0x3f,
# iNext at +0x40, iResult at +0x44, iHandler at +0x48.  The kernel's own SVC
# 0x73 service (0x503187e8) pops exactly that: r0 = [thread+0x38], next =
# [r0+0x40] back into [thread+0x38].  0x503a6120 is TTrap::UnTrap and calls
# [frame+0x48]->vtable+0xc (TTrapHandler::UnTrap).
#
# The failure was thread identity.  The bootstrap function 0x5031edc8 builds a
# stack SThread at 0x802ffd00 (sp+0x58 of its own 0x258-byte frame), and the
# init call 0x5031e594 returns a real DThread allocated from the bring-up heap
# at 0x80601078.  B7e's "is this a live pointer?" bound was hard-coded to
# 0x80400000, so it rejected the heap thread, re-published 0x802ffd00 and kept
# installing the trap graph on the stack object.  Later an EUser TFullName
# buffer (0x108 bytes, "Supervisor") was built at 0x802ffcec and overwrote the
# live thread's +0x38/+0x3c.  UnTrap then popped 0x503a43c4 - a ROM text
# address - and called [0x503a43c4+0x48]->vtable+0xc = 0.
#
# Round 32 follows the heap bound that the harness actually maps, so the real
# DThread at 0x80601078 stays live.  UnTrap pops a real stack TTrap frame and
# calls the real TCleanupTrapHandler.  The new frontier is the first blocking
# executive call: kernel-start waits for the request at [0x80001784] through
# EUser K=1208 (0x50398644, svc #0x4d); the thread that should complete it
# (0x5032fa10, name "NULL", object 0x80601830) never runs, so the service
# returns without completing it and the kernel panics KERN 6 at 0x50330aa8.
#
# Acceptance:
#   - control (NK_B7E_VALID_HI=0x80400000, the round-31 model): the live thread
#     is rejected, the stack SThread is clobbered and TTrap::UnTrap halts at
#     0x503a6148 (439,177 insns);
#   - fix: [0x800017d4] follows the heap DThread 0x80601078, UnTrap succeeds,
#     and the boot advances to the KERN 6 panic at 0x50312b88 (439,534 insns)
#     with 1 IRQ and no CPU/import faults.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 32: live DThread vs bootstrap SThread"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_boot() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
        NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=3000000 \
        NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 \
        NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
        NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
        NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
        NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
        "$@"
}

echo "== round 32 control: the round-31 0x80400000 bound rejects the heap thread"
NK_B7E_VALID_HI=0x80400000 run_boot ./out/boot_kernel "$ROM" \
    fw/6600_kernel.bin --rom-image out/6600_runtime.bin \
    >out/round32_base.log 2>&1

grep -q "null function pointer: branch to 0 (caller lr=0x503a6148)" \
    out/round32_base.log
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round32_base.log
base_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round32_base.log)
if [ "$base_insns" != "439177" ]; then
    echo "FAIL: control stopped at ${base_insns:-0} insns, expected 439177" >&2
    tail -40 out/round32_base.log >&2
    exit 1
fi

echo "== round 32: follow the real DThread into the heap (0x80601078)"
NK_B7E_VALID_HI=0x80a00000 run_boot ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round32_thread.log 2>&1

grep -q "live pointers 0x80000000..0x80a00000" out/round32_thread.log
grep -q "B7e: current thread 0x80601078 -> process 0x80003200" \
    out/round32_thread.log
if grep -q "null function pointer" out/round32_thread.log; then
    echo "FAIL: the fixed boot still takes a null call" >&2
    tail -40 out/round32_thread.log >&2
    exit 1
fi
grep -q "undefined=0" out/round32_thread.log
grep -q "unbound IAT=0" out/round32_thread.log
grep -q "recoveries=0" out/round32_thread.log
grep -q "irqs=1" out/round32_thread.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" \
    out/round32_thread.log
grep -q "regs: r0=0x00000040" out/round32_thread.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round32_thread.log)
if [ -z "$insns" ] || [ "$insns" -lt 435000 ] || [ "$insns" -gt 445000 ]; then
    echo "FAIL: thread boot stopped at ${insns:-0} instructions, expected 435k..445k" >&2
    tail -40 out/round32_thread.log >&2
    exit 1
fi

echo "ok: control (0x80400000 bound) reproduces the round-31 null cleanup call"
echo "    at 0x503a6148 after 439,177 insns"
echo "ok: default bound 0x80a00000 accepts the heap DThread 0x80601078"
echo "    (trap handler 0x80004200, cleanup 0x80004240); TTrap::UnTrap pops a"
echo "    real stack frame instead of ROM text 0x503a43c4"
echo "ok: boot advances to the first blocking executive call:"
echo "    EUser K=1208 (0x50398644, svc #0x4d) waits on [0x80001784]; no"
echo "    scheduler completes it, so KERN 6 panics at 0x50312b88 after"
echo "    $insns insns, 1 IRQ"
echo "PASS: round-32 separates the bootstrap SThread from the live DThread;"
echo "      the cleanup-frame frontier is closed, scheduler is next"
