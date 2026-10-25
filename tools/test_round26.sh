#!/bin/sh
# test_round26.sh — recover the EUser CObject/DProcess base-class ABI.
#
# Round 25 stopped when the freshly created DProcess was closed through
# DProcess vtable +0xc.  That call was assumed to be Close; the real EUser
# CObject vtable at 0x503b362c shows the order is
#
#   +0x08 ~CObject   0x50384ac8
#   +0x0c Open()     0x50384b28
#   +0x10 Close()    0x50384b3c
#   +0x14 Name()     0x50384bf8  (hidden return pointer: r0=TName*, r1=this)
#   +0x18 FullName() 0x50384c34
#
# so vtable +0xc is Open.  The kernel's DProcess vtable at 0x50338690 inherits
# that layout.  The old bindings left the CObject constructor at ordinal 1396
# (a list constructor that wrote [this+0xc]/[this+0x10]) and iAccessCount at
# 0, so Open hit an object-close panic helper.  Round 26 binds the real
# CObject constructor/destructor/Open/Close/FullName, the real
# CObjectCon::AddL (K::Containers[EProcess] insertion), CObject::Name and
# memcpy.
#
# With those eight ABI repairs the process is constructed, opened and linked
# into the process container.  The next stop is inside the kernel's own
# DProcess::Name override: its descriptor slots still use stale ordinals, so
# the temporary TName is overwritten before CheckUniqueFullName (USER 7).
# A documented stand-in patches the DProcess vtable +0x14 to EUser's real
# CObject::Name; that reaches DProcess::Loaded and a new zero-return
# frontier at 126,778 instructions.
#
# Acceptance:
#   - 38 import-map overrides;
#   - the CObject ctor/dtor/Open/Close/FullName and AddL/Name/memcpy binds
#     appear in the boot log;
#   - real path: >= 126,800 insns, 0 undefined/unbound/recoveries, then the
#     DProcess::Name descriptor panic (USER 7);
#   - name stand-in: >= 126,700 insns, 0 undefined/unbound/recoveries, stop
#     "pc left the image" at 0 from DProcess::Loaded;
#   - the LDMDB/STMDB memmove regression passes.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== interpreter selftest (LDMDB/STMDB memmove tail)"
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/interp_selftest.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/interp_selftest
./out/interp_selftest >out/interp_selftest.log 2>&1
grep -q "ok: ARM LDMDB/STMDB writeback copies the source range" \
    out/interp_selftest.log

echo "== flat image + boot harness"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

run_boot() {
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
        NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r26-6600.txt \
        NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 \
        NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 NK_TRAPCLEAN=1 \
        NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
        NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
        NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
        "$@"
}

echo "== round 26: CObject/DProcess base ABI (38 overrides)"
run_boot ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round26_boot.log 2>&1

grep -q "import map config/imports-r26-6600.txt: 38 slot overrides" out/round26_boot.log
grep -q "0x503b4d64 (uid 0x100039e5 ord 1396).*-> 0x50384a98" out/round26_boot.log
grep -q "0x503b4b5c (uid 0x100039e5 ord 1266).*-> 0x50384ac8" out/round26_boot.log
grep -q "0x503b4410 (uid 0x100039e5 ord 799).*-> 0x50384b28" out/round26_boot.log
grep -q "0x503b3a58 (uid 0x100039e5 ord 177).*-> 0x50384b3c" out/round26_boot.log
grep -q "0x503b3f14 (uid 0x100039e5 ord 480).*-> 0x50384c34" out/round26_boot.log
grep -q "0x503b42cc (uid 0x100039e5 ord 718).*-> 0x50384bf8" out/round26_boot.log
grep -q "0x503b37b8 (uid 0x100039e5 ord 9).*-> 0x503851e0" out/round26_boot.log
grep -q "0x503b3798 (uid 0x100039e5 ord 1).*-> 0x5038cfe0" out/round26_boot.log
grep -q "undefined=0" out/round26_boot.log
grep -q "unbound IAT=0" out/round26_boot.log
grep -q "recoveries=0" out/round26_boot.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round26_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round26_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 126800 ]; then
    echo "FAIL: round-26 real path only reached ${insns:-0} instructions" >&2
    tail -40 out/round26_boot.log >&2
    exit 1
fi

echo "== round 26: DProcess::Name descriptor frontier (USER 7)"
run_boot NK_WATCH=0x5039a9fc NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round26_name.log 2>&1
grep -q "pc=0x5039a9fc .*r1=0x7" out/round26_name.log
grep -q "0x50385358 -> 0x503884ac" out/round26_name.log

echo "== round 26: EUser CObject::Name stand-in -> DProcess::Loaded"
run_boot NK_PATCH=0x503386a4:0x50384bf8,0x503384bc:0x50384bf8 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round26_namehle.log 2>&1
grep -q "patch 0x503386a4 = 0x50384bf8" out/round26_namehle.log
grep -q "undefined=0" out/round26_namehle.log
grep -q "recoveries=0" out/round26_namehle.log
grep -q "^--- stop: pc left the image (5) at 0000000000 ---" out/round26_namehle.log

hle_insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/round26_namehle.log)
if [ -z "$hle_insns" ] || [ "$hle_insns" -lt 126700 ]; then
    echo "FAIL: name stand-in only reached ${hle_insns:-0} instructions" >&2
    tail -40 out/round26_namehle.log >&2
    exit 1
fi

echo "ok: CObject ctor/dtor/Open/Close/FullName + CObjectCon::AddL"
echo "    + CObject::Name + memcpy are bound from the real EUser class"
echo "    real path: $insns instructions, USER 7 in DProcess::Name"
echo "    name stand-in: $hle_insns instructions, DProcess::Loaded zero return"
echo "PASS: vtable +0xc is CObject::Open; process registration reaches"
echo "      CheckUniqueFullName and the next frontier is descriptor ABI"
