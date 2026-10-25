#!/bin/sh
# test_round25.sh — real initial CTrapCleanup state + descriptor/cobject ABI.
#
# Round 24 stopped at USER-CBase 69 (EClnNoTrapHandlerInstalled) because the
# direct E32 entry skips the user-side startup that calls CTrapCleanup::New().
# Round 25 builds the real object graph instead of a no-op handler:
#
#   TCleanupTrapHandler (vptr 0x503b3518 -> EUser Trap/UnTrap/Leave)
#   CCleanup            (vptr 0x503b36a4, iBase/iTop/iNext, one level marker)
#
# and publishes it at SThread::iTrapHandler (+0x3c) for every thread the
# kernel publishes.  CleanupStack::PushL now runs the real CCleanup code.
#
# Getting past that exposed four more call-site ABI mismatches, all pinned by
# the caller's argument shape:
#
#   - TDes16::Copy(const TDesC16&)         0x503b42c8 -> 0x50388408
#   - CObjectCon::FindByName(TBuf<128>&)   0x503b3e28 -> 0x50385650
#   - User::Alloc (DProcess::New, 0xdc)     0x503b379c -> 0x503988f0
#   - TBufBase8(int) (DProcess name, max 8) 0x503b4bec -> 0x50388b24
#
# The run now allocates and constructs the real initial DProcess.  It stops
# while the fresh process is closed through DProcess vtable +0xc: kernel import
# 0x503b4410 resolves to EUser index 799, which in this ROM is the object-close
# panic helper (KERN-NO-SESSION 52).  That vtable slot is the next ABI map item.
#
# Acceptance:
#   - the import map applies 30 overrides;
#   - every published thread gets a trap handler / cleanup stack;
#   - TDes16::Copy / FindByName / User::Alloc / TBufBase8 rebinds are applied;
#   - the DProcess constructor runs (process object 0x806008b8);
#   - >= 125,000 instructions, 0 undefined, 0 unbound IAT, 0 recoveries;
#   - the watch at the close panic helper (0x5039e328) fires with reason 52.
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

run_boot() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
        NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r25-6600.txt \
        NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 \
        NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 \
        NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
        NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        "$@"
}

echo "== round 25: initial trap/cleanup + process-construction ABI"
run_boot ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round25_boot.log 2>&1

grep -q "import map config/imports-r25-6600.txt: 30 slot overrides" out/round25_boot.log
grep -q "trap handler 0x80004100, cleanup 0x80004140" out/round25_boot.log
grep -q "0x503b42c8 (uid 0x100039e5 ord 717) 0x50394ba0 -> 0x50388408" out/round25_boot.log
grep -q "0x503b3e28 (uid 0x100039e5 ord 421) 0x503947b0 -> 0x50385650" out/round25_boot.log
grep -q "0x503b379c (uid 0x100039e5 ord 2) 0x5038ee04 -> 0x503988f0" out/round25_boot.log
grep -q "0x503b4bec (uid 0x100039e5 ord 1302) 0x50391800 -> 0x50388b24" out/round25_boot.log
grep -q "undefined=0" out/round25_boot.log
grep -q "unbound IAT=0" out/round25_boot.log
grep -q "recoveries=0" out/round25_boot.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round25_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round25_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 125000 ]; then
    echo "FAIL: round-25 boot only reached ${insns:-0} instructions" >&2
    tail -40 out/round25_boot.log >&2
    exit 1
fi

echo "== round 25: close-vtable frontier (KERN-NO-SESSION 52)"
run_boot NK_WATCH=0x5039e328 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round25_watch.log 2>&1
grep -q "\[watch\] pc=0x5039e328 .*r1=0x34" out/round25_watch.log

echo "ok: real CTrapCleanup graph + TDes16::Copy + FindByName + User::Alloc"
echo "    + TBufBase8; $insns instructions"
echo "    (0 undefined, 0 unbound imports, 0 recoveries)"
echo "PASS: new frontier is DProcess vtable +0xc / EUser ordinal 799"
echo "      (fresh process close reaches KERN-NO-SESSION 52)"
