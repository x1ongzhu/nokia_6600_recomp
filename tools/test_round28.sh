#!/bin/sh
# test_round28.sh - the mask-ROM boot hand-off and the first kernel idle loop.
#
# Round 27 left the faithful kernel path at 108,231 instructions (USER-EXEC 3
# after the HAL timer frequency returned zero).  Round 28 recovers the boot
# state the mask ROM normally supplies *before* jumping to the E32 entry:
#
#   * [0x400000d0] = the ekern.exe TRomEntry.  The kernel reads [entry+4] to
#     find its own TRomImageHeader (iStackSize/iHeapSizeMin/iHeapSizeMax).
#   * iPrimaryFile must be a writable base: the initial TStack object is
#     iPrimaryFile + iStackSize.  A 64 KiB RAM copy of the ROMFS directory
#     (only iPrimaryFile repointed) matches the mask ROM's writable table.
#   * The initial thread's TStack base constructor is 0x503a023c, not the
#     round-27 K=1361 exception 0x503a0224.  The latter only zeroes 16 bytes
#     and the stack-size field stays 0 -> PLAT 0x51.
#   * The HAL timer channel (+0x5c) must return a non-zero frequency; 4 Hz is
#     the round-27 probe value, not recovered firmware state.
#   * Three time-cluster slots keep their ROM (static) targets; the K-3
#     targets put the ROM header's 2000-01-01 iTime out of range in
#     TTime::SecondsFrom.
#
# Two runs pin the result:
#
#   faithful 236 overrides, no WD2 HAL stand-in: the real kernel reaches
#            164,731 instructions and panics MKERN-WD2 24 ("Invalid CTSI
#            DMA"/system-time hand-off) at 0x50310b30.  That is the new
#            frontier: the time-cluster TTime conversion, not the stack.
#   idle     the same map plus round 23's WD2 time/HAL slot zero: the kernel
#            gets past Kern::Init1 and enters its idle/timer wait loop at
#            0x50310f84, spinning on [0x8000000c] until the 3,000,000
#            instruction budget.  This is the first idle-loop boot.
#
# Acceptance:
#   - bootstate.py verify passes every hand-off/stack/time/idle assertion;
#   - the boot relocation profile has 236 overrides (4 local exceptions) and
#     the boot-idle profile adds exactly the 0x503b46bc zero;
#   - faithful: >= 164,700 insns, 0 undefined/unbound/recoveries, MKERN-WD2
#     halt at 0x50312b88;
#   - idle: 3,000,000 insns, budget stop at 0x50310f88, 0
#     undefined/unbound/recoveries.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 28: boot hand-off, TStack base and time frontier"
.venv/bin/python recompiler/bootstate.py verify "$ROM" >out/round28_bootstate.log 2>&1
grep -q "PASS: round-28 boot hand-off" out/round28_bootstate.log

echo "== round 28: boot relocation profile"
.venv/bin/python recompiler/euser_reloc.py verify "$ROM" --profile boot \
    >out/round28_reloc.log 2>&1
grep -q "PASS: 229 EUser slots follow edata\[K-3\]; 4 local exception(s)" \
    out/round28_reloc.log
.venv/bin/python recompiler/euser_reloc.py build "$ROM" \
    out/imports-r28-6600.txt --profile boot >/dev/null
.venv/bin/python recompiler/euser_reloc.py build "$ROM" \
    out/imports-r28-boot-6600.txt --profile boot-idle >/dev/null
cmp out/imports-r28-6600.txt config/imports-r28-6600.txt
cmp out/imports-r28-boot-6600.txt config/imports-r28-boot-6600.txt

echo "== flat image + boot harness"
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
        "$@"
}

echo "== round 28: faithful boot profile (no WD2 HAL stand-in)"
run_boot NK_IMPORTMAP=config/imports-r28-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round28_faithful.log 2>&1

grep -q "boot handoff: superpage c4/c8/cc/d0" out/round28_faithful.log
grep -q "primary RAM: 0x50300000..0x50310000 -> 0x80900000" out/round28_faithful.log
grep -q "HAL timer frequency: vtable+0x5c" out/round28_faithful.log
grep -q "import map config/imports-r28-6600.txt: 236 slot overrides" out/round28_faithful.log
grep -q "undefined=0" out/round28_faithful.log
grep -q "unbound IAT=0" out/round28_faithful.log
grep -q "recoveries=0" out/round28_faithful.log
grep -q "^\-\-\- stop: self-branch (panic halt) (7) at 0x50312b88 ---" \
    out/round28_faithful.log

faithful=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round28_faithful.log)
if [ -z "$faithful" ] || [ "$faithful" -lt 164700 ]; then
    echo "FAIL: faithful boot only reached ${faithful:-0} instructions" >&2
    tail -40 out/round28_faithful.log >&2
    exit 1
fi

echo "== round 28: boot-idle profile (round-23 WD2 time stand-in)"
run_boot NK_IMPORTMAP=config/imports-r28-boot-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round28_idle.log 2>&1

grep -q "import map config/imports-r28-boot-6600.txt: 236 slot overrides" \
    out/round28_idle.log
grep -q "undefined=0" out/round28_idle.log
grep -q "unbound IAT=0" out/round28_idle.log
grep -q "recoveries=0" out/round28_idle.log
grep -q "^\-\-\- stop: budget (0) at 0x50310f88 ---" out/round28_idle.log

idle=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round28_idle.log)
if [ -z "$idle" ] || [ "$idle" -lt 3000000 ]; then
    echo "FAIL: boot-idle run only reached ${idle:-0} instructions" >&2
    tail -40 out/round28_idle.log >&2
    exit 1
fi

echo "ok: super-page [0x400000d0] -> ekern.exe TRomEntry -> own image header"
echo "    iPrimaryFile on a RAM copy; TStack ctor 0x503a023c (K=1361 boot)"
echo "    faithful: $faithful instructions; MKERN-WD2 24 at 0x50310b30"
echo "    idle:     $idle instructions; idle/timer wait loop at 0x50310f84"
echo "PASS: round-28 boot state reaches the kernel idle loop; the next gap is"
echo "      the initial TTime hand-off (TTime::SecondsFrom), not the stack"
