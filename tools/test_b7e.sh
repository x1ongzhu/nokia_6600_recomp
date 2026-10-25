#!/bin/sh
# test_b7e.sh — initial thread/process/object-index boot state.
#
# Round 20 reclassifies the round-19 frontier.  The accessor at 0x50380270 is
# not RHeap::Alloc: it indexes an object array ([this+0x18] is the array,
# [this+0x14] the element size, [this] the base), and the caller 0x50318410 is
# the handle-to-object path from [thread+0x18] to [process+0x38].  That is
# CObjectIx::At (the SDK EUser ordinal 109), so the missing boot state is the
# initial process and its object index, not a heap.
#
# Acceptance:
#   - NK_B7E installs thread -> process -> CObjectIx -> array;
#   - the kernel publishes its first thread 0x802ffd00 and later creates a
#     second thread 0x80001860, both with the object index installed;
#   - the run leaves the round-19 8.5k null-heap stop far behind: it executes
#     >5,000,000 instructions with 0 undefined instructions, 0 call fixups and
#     0 crash recoveries;
#   - the next frontier is the second thread's stack underflow (pc=0), not an
#     import, layout or null-object-index stop.
#
# The graph is an explicit bring-up stand-in, not a scheduler model.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi
mkdir -p out

echo "== ARM MUL/MLA regression"
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/interp_selftest.c runtime/src/nokia_rt.c \
    runtime/src/nokia_interp.c -o out/interp_selftest
./out/interp_selftest >out/test_b7e.interp.log 2>&1
grep -q "ARM MUL/MLA write bits 19-16 and leave r0 alone" \
    out/test_b7e.interp.log
echo "ok: ARM MUL/MLA writes bits 19-16 (r0 is no longer clobbered)"

echo "== flat image"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

echo "== B7e thread/process/object-index graph"
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-6600.txt \
NK_IAT_FAKE=0 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=6000000 \
NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/b7e_boot.log 2>&1

grep -q "B7e boot state: thread 0x80003000, process 0x80003200, objidx 0x80003300" \
    out/b7e_boot.log
grep -q "B7e: current thread 0x802ffd00 -> process 0x80003200" \
    out/b7e_boot.log
grep -q "B7e: current thread 0x80001860 -> process 0x80003200" \
    out/b7e_boot.log
grep -q "undefined=0" out/b7e_boot.log
grep -q "call fixups=0" out/b7e_boot.log
grep -q "recoveries=0" out/b7e_boot.log
grep -q "^--- stop: pc left the image (5) at 0000000000 ---" out/b7e_boot.log
grep -q "pc=0000000000" out/b7e_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/b7e_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 5000000 ]; then
    echo "FAIL: B7e run only reached ${insns:-0} instructions" >&2
    tail -25 out/b7e_boot.log >&2
    exit 1
fi
echo "ok: B7e installed the object index and ran $insns instructions"
echo "    (0 undefined, 0 call fixups, 0 recoveries)"
echo "ok: next frontier is the second thread's stack underflow at pc=0"
echo "PASS: initial process/object index; round-19 null-heap diagnosis corrected"
