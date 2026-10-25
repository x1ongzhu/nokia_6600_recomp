#!/bin/sh
# test_round24.sh — EUser ABI repair, real time init, object containers,
#                   process creation; 126k-instruction boot.
#
# Round 23 ended at 139,784 instructions on a soft-float underflow that was
# really a wrong EUser import.  The kernel in this ROM was linked against a
# different EUser export order than the EUser image itself; round 24 repairs
# the whole call-site-visible cluster instead of stopping at the first bad
# instruction:
#
#   - the system-time cluster: TInt64(int)/operator>>/operator*/operator/=
#     /operator<<=, TTime::SecondsFrom, TTime::MicroSecondsFrom,
#     TTime::operator+=(microseconds), TTrap::Trap;
#   - kernel object-container creation: CObjectConIx::NewL and CreateL;
#   - process-name parsing: TDesC16::Locate/Mid, TDesC8::Alloc;
#   - the HLE bump heap now has block headers and serves RHeap1::ReAlloc1
#     and RHeap::Free, so the real RHeap realloc path can copy a bump block
#     instead of reading a synthetic block header.
#
# The run now executes the real P::InitSystemTime, K::CreateObjectContainers
# and the first process creation.  It stops at the missing initial trap
# handler (USER-CBase 69, CleanupStack::PushL without a trap frame), which is
# the next boot-state frontier.
#
# Acceptance:
#   - import map applies 26 overrides;
#   - the time shift import resolves to TInt64::operator>> (0x50389fc8);
#   - CObjectConIx::NewL/CreateL are rebound (0x50385858 / 0x5038598c);
#   - the HLE heap performs at least one ReAlloc;
#   - >= 126,000 instructions, 0 undefined, 0 unbound IAT, 0 recoveries;
#   - the run stops at the kernel panic printer (0x50312b88), not a random
#     undefined instruction or an unbound import.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== flat image + boot harness"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

echo "== round 24: EUser time/object/name cluster + real RHeap realloc"
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r24-6600.txt \
NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 \
NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 \
NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=64 \
NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round24_boot.log 2>&1

grep -q "import map config/imports-r24-6600.txt: 26 slot overrides" out/round24_boot.log
grep -q "0x503b50c0 (uid 0x100039e5 ord 1611) 0x5038c9ac -> 0x50389fc8" out/round24_boot.log
grep -q "0x503b42e8 (uid 0x100039e5 ord 725) 0x50396408 -> 0x50385858" out/round24_boot.log
grep -q "0x503b3be8 (uid 0x100039e5 ord 277) 0x5039dd90 -> 0x5038598c" out/round24_boot.log
grep -q "undefined=0" out/round24_boot.log
grep -q "unbound IAT=0" out/round24_boot.log
grep -q "recoveries=0" out/round24_boot.log
grep -q "HLE realloc" out/round24_boot.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round24_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round24_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 126000 ]; then
    echo "FAIL: round-24 boot only reached ${insns:-0} instructions" >&2
    tail -40 out/round24_boot.log >&2
    exit 1
fi
echo "ok: time cluster + CObjectConIx + TDesC8::Alloc + RHeap realloc; $insns instructions"
echo "    (0 undefined, 0 unbound imports, 0 recoveries)"
echo "PASS: new frontier is the initial thread's trap frame / cleanup stack"
echo "      (USER-CBase 69 in CleanupStack::PushL during process creation)"
