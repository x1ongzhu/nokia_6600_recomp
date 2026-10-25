#!/bin/sh
# test_round27.sh - relocate the kernel's EUser imports and fix DProcess::Name.
#
# Round 27 found that the kernel image and the EUser.dll in the same ROM were
# built from different export lists:
#
#   kernel ordinal K = generic 7.0 ordinal G - 1
#   ROM EUser index  M = generic 7.0 ordinal G - 4
#   => for K >= 6 the desired symbol is at ROM export K - 3
#
# The three low ordinals are special: K=0 is the ROM memset, K=1 is Mem::Copy
# and K=2 is User::Alloc.  The ELocl export-table hole (ordinal 20) remains a
# zero-return stub.  recompiler/euser_reloc.py verifies the rule against 49
# call-site anchors and emits the two maps used here.
#
# Two runs pin the result:
#
#   full   236 overrides, NK_CALL_INFER=0 (the flat image is linked): the
#          real kernel boot path.  The K=1361 exception is the 16-byte-zeroing
#          boot-file base constructor (0x503a0224); the shifted target
#          (0x5039c148) writes at +0x7c and overruns the 0x74-byte object.
#          The run reaches 108,231 instructions and stops in the USER-EXEC 3
#          panic after a failed object-handle lookup (handle 0xffff8001 in
#          CObjectIx::At).  This is the K::Init1 initial-process/thread state.
#
#   control the same map with NK_CALL_INFER=1 snaps a valid internal EUser
#          call (0x5038ad44 -> 0x5038ad20) and reaches only 14,354
#          instructions before the MATHX panic.  It is kept as a control:
#          call inference is a packed-image aid, not linked-image truth.
#
#   HAL     the 108k USER-EXEC 3 is a division-by-zero consequence:
#          [0x800003ac]->vtable+0x5c (the HAL timer frequency) returns 0 and
#          0x503109d0 stores it at 0x800017f4; K::Init1 then divides 1,000,000
#          by it.  Poking vtable+0x5c to a constant-return stub (0x503109a0
#          returns 4) advances to 117,923 instructions and a new KERN panic
#          in the 0x5031c9d0 path.  This is the next concrete boot-state gap.
#
#   name    47 overrides: round 26's map plus the DProcess-name cluster and
#          the two TDblQueIterBase imports.  It proves the real name ABI with
#          no NK_PATCH stand-in: the process carries UIDs 1000007a/8b/b9, the
#          name is registered and CheckUniqueFullName passes.  It reaches
#          128,663 instructions and stops at a zero code-segment pointer.
#
# Acceptance:
#   - euser_reloc.py verify passes all anchors, the 232-slot K-3 rule and the
#     one local exception;
#   - the generated maps match the checked-in configs;
#   - full: 236 overrides, NK_CALL_INFER=0, 0 undefined/unbound/recoveries,
#     >= 108,000 insns, USER-EXEC 3 panic at 0x50312b88;
#   - control: NK_CALL_INFER=1, >= 14,300 insns, MATHX panic (artifact);
#   - HAL: vtable+0x5c poke, >= 117,900 insns, 0 undefined/unbound/recoveries;
#   - name: 47 overrides, correct UIDs, >= 128,600 insns, 0
#     undefined/unbound/recoveries, pc=0.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 27: EUser import relocation anchors"
.venv/bin/python recompiler/euser_reloc.py verify "$ROM" >out/round27_reloc.log 2>&1
grep -q "PASS: 232 EUser slots follow edata\[K-3\]" out/round27_reloc.log
grep -q "1 local exception" out/round27_reloc.log
grep -q "kernel EUser imports: 236" out/round27_reloc.log

echo "== round 27: regenerate the maps"
.venv/bin/python recompiler/euser_reloc.py build "$ROM" out/imports-r27-6600.txt >/dev/null
.venv/bin/python recompiler/euser_reloc.py build "$ROM" out/imports-r27-name-6600.txt --profile name >/dev/null
cmp out/imports-r27-6600.txt config/imports-r27-6600.txt
cmp out/imports-r27-name-6600.txt config/imports-r27-name-6600.txt

echo "== flat image + boot harness"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_boot() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
        NK_SWI_COMPLETE=0x4d \
        NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 \
        NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 \
        NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
        NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        "$@"
}

echo "== round 27: full EUser relocation (236 slots), linked/call-infer off"
run_boot NK_IMPORTMAP=config/imports-r27-6600.txt NK_CALL_INFER=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round27_full.log 2>&1

grep -q "import map config/imports-r27-6600.txt: 236 slot overrides" out/round27_full.log
grep -q "undefined=0" out/round27_full.log
grep -q "unbound IAT=0" out/round27_full.log
grep -q "recoveries=0" out/round27_full.log
grep -q "^\-\-\- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round27_full.log

full_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round27_full.log)
if [ -z "$full_insns" ] || [ "$full_insns" -lt 108000 ]; then
    echo "FAIL: faithful full relocation only reached ${full_insns:-0} instructions" >&2
    tail -40 out/round27_full.log >&2
    exit 1
fi

echo "== round 27: call-inference control (14,354, MATHX artifact)"
run_boot NK_IMPORTMAP=config/imports-r27-6600.txt \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round27_full_infer.log 2>&1
grep -q "^\-\-\- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round27_full_infer.log
grep -q "undefined=0" out/round27_full_infer.log
grep -q "recoveries=0" out/round27_full_infer.log
infer_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round27_full_infer.log)
if [ -z "$infer_insns" ] || [ "$infer_insns" -lt 14300 ]; then
    echo "FAIL: call-inference control only reached ${infer_insns:-0} instructions" >&2
    tail -40 out/round27_full_infer.log >&2
    exit 1
fi

echo "== round 27: HAL timer probe (vtable +0x5c -> constant 4)"
run_boot NK_IMPORTMAP=config/imports-r27-6600.txt NK_CALL_INFER=0 \
    NK_POKE=0x80003c5c:0x503109a0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round27_hal.log 2>&1
grep -q "poke 0x80003c5c = 0x503109a0" out/round27_hal.log
grep -q "undefined=0" out/round27_hal.log
grep -q "unbound IAT=0" out/round27_hal.log
grep -q "recoveries=0" out/round27_hal.log
grep -q "^\-\-\- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round27_hal.log
hal_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round27_hal.log)
if [ -z "$hal_insns" ] || [ "$hal_insns" -lt 117900 ]; then
    echo "FAIL: HAL timer probe only reached ${hal_insns:-0} instructions" >&2
    tail -40 out/round27_hal.log >&2
    exit 1
fi

echo "== round 27: DProcess name cluster (47 slots, no NK_PATCH)"
run_boot NK_IMPORTMAP=config/imports-r27-name-6600.txt \
    NK_WATCH=0x5032b5d4 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
    NK_WATCH_MEM=r1:0x30 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round27_name.log 2>&1

grep -q "import map config/imports-r27-name-6600.txt: 47 slot overrides" out/round27_name.log
grep -q "\[watch\] mem r1 @0x806008b8: .* 1000007a 1000008b 100000b9 " out/round27_name.log
grep -q "undefined=0" out/round27_name.log
grep -q "unbound IAT=0" out/round27_name.log
grep -q "recoveries=0" out/round27_name.log
grep -q "^\-\-\- stop: pc left the image (5) at 0000000000 ---" out/round27_name.log

name_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round27_name.log)
if [ -z "$name_insns" ] || [ "$name_insns" -lt 128600 ]; then
    echo "FAIL: name cluster only reached ${name_insns:-0} instructions" >&2
    tail -40 out/round27_name.log >&2
    exit 1
fi

echo "ok: 232 kernel EUser imports follow ROM export K-3 + 1 local exception"
echo "    DProcess name: TUidType()/operator[], [uid] suffix, Append/NumWidth"
echo "    full (linked): $full_insns instructions; USER-EXEC 3; HAL timer = 0"
echo "    control (infer): $infer_insns instructions; MATHX call-snap artifact"
echo "    HAL timer probe: $hal_insns instructions; +0x5c constant -> new KERN"
echo "    name path: $name_insns instructions; UIDs 1000007a/8b/b9, no stand-in"
echo "PASS: the kernel/EUser import order differs by a constant 3; the linked"
echo "      path's next gap is the HAL timer frequency (vtable+0x5c)"
