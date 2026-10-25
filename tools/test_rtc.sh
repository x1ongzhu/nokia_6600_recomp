#!/bin/sh
# test_rtc.sh — RTC extension bring-up and the post-extension boot frontier.
#
# Round 22 found that the "RTC PDD rodata block" is actually a nested E32
# image (uid2 0x100058d8): its text is 0x5033ee14..0x50341414, its data is at
# 0x50341414 and it has no export table.  The kernel's extension loader calls
# the image entry (0x5033ee14, which initialises the driver object) and then
# calls export ordinal 1 through [hdr+0x40]; with a zero export directory that
# is a jump to 0.
#
# The round-22 bring-up therefore:
#   - serves the RTC driver's `new(0x38)`/`new(8)` calls from the harness bump
#     heap.  EUser export index 1504 resolves to RTest::operator() in this
#     ROM, not to operator new: the driver and EUser were linked against
#     different .def revisions (config/callmap-rtc-6600.txt);
#   - returns a real HAL channel object from the B7e HAL stand-in.  The
#     previous stand-in returned the integer 1, which the driver stored and
#     later dereferenced as a vtable pointer;
#   - installs a synthetic export 1 for an extension header with no exports
#     (NK_EXT_STUB=1).  It returns a HAL-like object and the kernel installs
#     it at [0x800003ac];
#   - serves the driver's 64-bit system-time request with a zero TTime
#     (NK_HLE_ZERO2), because the kernel's formatter and the panic printer
#     share an EUser import slot that this ROM's .def order splits.
#
# Result: the RTC extension initialises completely and the kernel advances to
# the post-extension boot initialisation at 0x50310fa4.  The next frontier is
# a boot descriptor in kernel .bss: 0x5031f3a8 checks [0x80000b5c] == 0xff
# and panics PLAT 21 otherwise.  The E32 entry path skipped the mask-ROM/
# kernel startup that fills 0x80000b5c.
#
# Acceptance:
#   - the RTC HAL/alloc/time fixups execute (3 callmap entries, 2 HAL-visible
#     allocations, 0x38 and 8 bytes);
#   - the extension export stub is installed and reached;
#   - 27,470 instructions, 0 undefined, 0 unbound imports, 0 recoveries;
#   - the run stops in the panic printer with PLAT 21 at 0x5031f3a8/0x5031f3c0.
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

echo "== RTC extension: allocator, HAL channel, export stub, time"
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=8000000 \
NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 \
NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
NK_WATCH=0x5031f3c0 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/rtc_boot.log 2>&1

grep -q "callmap config/callmap-rtc-6600.txt: 3 call-site fixups" out/rtc_boot.log
grep -q "HLE alloc 0x5033efa8 (0x38 bytes -> 0x80700000)" out/rtc_boot.log
grep -q "HLE alloc 0x5033eff0 (0x8 bytes -> 0x80700038)" out/rtc_boot.log
grep -q "HLE zero2 0x5033f040" out/rtc_boot.log
grep -q "extension stub: image header 0x5033edb0 exports=0 dir=0000000000" out/rtc_boot.log
grep -q "extension stub: export 1 -> 0xffff0910 (HAL object 0x80003a40)" out/rtc_boot.log
grep -q "undefined=0" out/rtc_boot.log
grep -q "unbound IAT=0" out/rtc_boot.log
grep -q "recoveries=0" out/rtc_boot.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/rtc_boot.log
grep -q "\[watch\] pc=0x5031f3c0 .* r0=0x15 " out/rtc_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/rtc_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 27000 ]; then
    echo "FAIL: RTC boot only reached ${insns:-0} instructions" >&2
    tail -30 out/rtc_boot.log >&2
    exit 1
fi
echo "ok: RTC extension initialised; $insns instructions"
echo "    (0 undefined, 0 unbound imports, 0 recoveries)"
echo "PASS: next frontier is the post-extension boot descriptor at 0x80000b5c"
