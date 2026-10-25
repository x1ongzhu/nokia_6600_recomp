#!/bin/sh
# test_bootbringup.sh — acceptance test for the round-15 boot-image handoff.
#
#  1. fragment C is relocated, so the CPU/board table at linked 0x74b8
#     contains the value 0x3b and the loader no longer halts in 0x3d44;
#  2. the staging boot-region table resolves the kernel code section to
#     0x50310000 and the .data section to 0x80000000;
#  3. the KaeP container descriptor/list and its executable `ldr pc` handoff
#     let the real loader program UPP, build page tables and reach linked 0x80
#     with no undefined instruction;
#  4. removing NK_STOP_PC executes the handoff and enters the real kernel at
#     0x50310054 (it runs on into the kernel's own stack/exception path),
#     rather than taking an SWI on the opaque KaeP record bytes.
#
# The 0x20-byte KaeP record itself is preserved, not decoded; the trampoline is
# the explicit mask-ROM stand-in for the still-undocumented record codec.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: $PY recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== fragment C and the CPU/board table"
"$PY" recompiler/bootbank.py verify "$ROM" >/dev/null
"$PY" recompiler/bootbank.py build "$ROM" out/6600_bootbank_linked.bin >/dev/null
"$PY" recompiler/bootbank.py analyze "$ROM" | grep -q "C bias: 0x374"

echo "== staging boot-region table"
"$PY" recompiler/bootregions.py verify "$ROM" --profile staging >/dev/null
"$PY" recompiler/bootregions.py build "$ROM" \
    out/6600_bootregions_staging.bin --profile staging >/dev/null

echo "== KaeP container descriptor / node and executable handoff"
"$PY" recompiler/kaep.py verify "$ROM" >/dev/null
"$PY" recompiler/bootbringup.py verify "$ROM" >/dev/null
"$PY" recompiler/bootbringup.py build "$ROM" \
    out/6600_bootbank_bringup.bin \
    --regions out/6600_bootregions_staging.bin >/dev/null

if [ ! -x out/boot_kernel ]; then
    clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
        runtime/test/boot_kernel.c runtime/src/nokia_rt.c \
        runtime/src/nokia_interp.c -o out/boot_kernel
fi
if [ ! -f out/6600_runtime.bin ]; then
    tools/build_rom_image.sh >/dev/null
fi

echo "== run to the boot-image handoff"
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_bringup.bin \
  NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=1500000 NK_MMIO_N=0 \
  NK_STOP_PC=0x80 NK_WATCH=0x80 NK_WATCH_HITS=1 NK_WATCH_LOG=32 \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin > out/bootbringup.log 2>&1

if ! grep -q -- "stop: returned (2) at 0x00000080" out/bootbringup.log; then
    echo "FAIL: loader did not reach the boot-image handoff at 0x80" >&2
    tail -30 out/bootbringup.log >&2
    exit 1
fi
if ! grep -q "recoveries=1" out/bootbringup.log; then
    echo "FAIL: expected exactly one recovered stale call" >&2
    tail -30 out/bootbringup.log >&2
    exit 1
fi
if ! grep -q "undefined=0" out/bootbringup.log; then
    echo "FAIL: handoff path hit an undefined instruction" >&2
    exit 1
fi
if grep -q "self-branch (panic halt)" out/bootbringup.log; then
    echo "FAIL: firmware panic halt before the handoff" >&2
    tail -20 out/bootbringup.log >&2
    exit 1
fi
if ! grep -q "0x00003ae8 -> 0x00005bb4" out/bootbringup.log; then
    echo "FAIL: the stale 0x3ae8 call did not reach the handoff path" >&2
    exit 1
fi
if ! grep -q "mmio: 12 reads, 46 writes" out/bootbringup.log; then
    echo "FAIL: UPP programming counts changed (expected 12 reads / 46 writes)" >&2
    grep "^mmio:" out/bootbringup.log >&2
    exit 1
fi
insns=$(sed -n 's/^insns=\([0-9]*\).*/\1/p' out/bootbringup.log)
if [ -z "$insns" ] || [ "$insns" -lt 30000 ]; then
    echo "FAIL: handoff reached after only ${insns:-0} instructions" >&2
    exit 1
fi

echo "== handoff executes the installed trampoline and enters the kernel"
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_bringup.bin \
  NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=1500000 NK_MMIO_N=0 \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin > out/bootbringup_kernel.log 2>&1

if grep -q -- "SWI 0xf9ea00 at 0x00000080" out/bootbringup_kernel.log; then
    echo "FAIL: 0x80 still executes the opaque KaeP record as an SWI" >&2
    tail -20 out/bootbringup_kernel.log >&2
    exit 1
fi
if ! grep -q "undefined=0" out/bootbringup_kernel.log; then
    echo "FAIL: kernel handoff hit an undefined instruction" >&2
    tail -20 out/bootbringup_kernel.log >&2
    exit 1
fi
if ! grep -q "^last pcs:.* 5039" out/bootbringup_kernel.log; then
    echo "FAIL: handoff did not reach the kernel code range" >&2
    tail -20 out/bootbringup_kernel.log >&2
    exit 1
fi
kinsns=$(sed -n 's/^insns=\([0-9]*\).*/\1/p' out/bootbringup_kernel.log)
if [ -z "$kinsns" ] || [ "$kinsns" -lt 1000000 ]; then
    echo "FAIL: kernel did not run after the handoff (${kinsns:-0})" >&2
    exit 1
fi

echo "PASS: KaeP container, executable handoff and real kernel entry"
