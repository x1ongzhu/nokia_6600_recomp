#!/bin/sh
# test_round23.sh — timer names, RAM page bitmap, super page, WD2 HAL.
#
# Round 23 starts from tools/test_rtc.sh's 27,470-instruction frontier and
# follows the kernel's post-extension boot into the RAM allocator, page tables
# and WD2 CTSI DMA init.  The advances are:
#
#   - the 0x40000000 super page is modelled (iTotalRamSize + iRamBootData with
#     an SRamBank list).  The E32 entry normally never runs the mask ROM's
#     bootstrap that fills it, so every read was returning zero from the MMIO
#     bus and the RAM allocator saw no banks.
#   - three more wrong-ABI EUser imports are repaired (see
#     config/imports-wd2-6600.txt): the 12-byte TDesC8 default constructor that
#     clobbered the timer state word at 0x80000b5c, DObject::Close used as
#     TDesC8::Compare, and a 2-byte array allocator used as
#     CBitMapAllocator::New.  Two page-table bitmap methods (Alloc and
#     AllocAt) are rebound to their real CBitMapAllocator implementations.
#   - the B7e stand-in now follows the kernel's real DProcess object and
#     supplies the live thread's [thread+0x5c] thread-local object.
#
# Result: 139,784 instructions, 0 undefined, 0 call fixups beyond the RTC
# callmap, 0 unbound IAT, 0 recoveries, ending in a deliberate USER-EXEC 3
# panic: the current thread has no exception handler because the direct E32
# entry skipped the scheduler's initial trap state.  That is the next frontier.
#
# Acceptance:
#   - the super page logs 6 MiB in two banks (4 MiB + 2 MiB);
#   - the import map applies 11 overrides (1 ELocl hole + 4 round-21 rebinds
#     + 6 round-23 rebinds);
#   - the run reaches 0x503994e8 with r1=3 (USER-EXEC 3);
#   - instruction count >= 139,000 and no undefined/recovery/unbound-IAT.
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

echo "== round 23: super page, RAM banks, page bitmap, WD2 CTSI DMA"
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-wd2-6600.txt \
NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 \
NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 \
NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
NK_WATCH=0x503994e8 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round23_boot.log 2>&1

grep -q "super page 0x40000000: total RAM 0x600000, 2 banks" out/round23_boot.log
grep -q "import map config/imports-wd2-6600.txt: 11 slot overrides" out/round23_boot.log
grep -q "undefined=0" out/round23_boot.log
grep -q "unbound IAT=0" out/round23_boot.log
grep -q "recoveries=0" out/round23_boot.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round23_boot.log
grep -q "\[watch\] pc=0x503994e8 .* r1=0x3 " out/round23_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round23_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 139000 ]; then
    echo "FAIL: round-23 boot only reached ${insns:-0} instructions" >&2
    tail -40 out/round23_boot.log >&2
    exit 1
fi
echo "ok: super page + RAM allocator + page tables + WD2 CTSI DMA; $insns instructions"
echo "    (0 undefined, 0 unbound imports, 0 recoveries)"
echo "PASS: next frontier is the initial thread's trap/exception state (USER-EXEC 3)"
