#!/bin/sh
# test_kaep.sh — acceptance test for the KaeP/page-tag round.
#
#   1. the KaeP block and the 0x20ec page-tag grid are structural invariants;
#   2. the legacy attr=1 boot-region table cannot satisfy 0x1a1c/0x1b34;
#   3. the linear profile (RAM type 2, ROM/boot type 5 + 0x04000000) lets the
#      *original* linked boot bank pass the old 0xc58 frontier and reach the
#      page-table builder at 0x2fe4;
#   4. the synthetic KaeP descriptor/node in `kaep.py synth` is an explicit
#      bring-up stand-in and also passes 0xc58.
#
# The exact 0x2fe4 stop is a page-table fill, not a finished boot: it is
# pinned here so a regression cannot silently move the frontier back.
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

echo "== KaeP/page-tag invariants"
"$PY" recompiler/kaep.py verify "$ROM"
"$PY" recompiler/kaep.py analyze "$ROM" --json out/kaep_analysis.json >/dev/null

echo "== boot-region profiles"
"$PY" recompiler/bootregions.py verify "$ROM" >/dev/null
"$PY" recompiler/bootregions.py build "$ROM" \
    out/6600_bootregions.bin >/dev/null
"$PY" recompiler/bootregions.py verify "$ROM" --profile linear >/dev/null
"$PY" recompiler/bootregions.py build "$ROM" \
    out/6600_bootregions_linear.bin --profile linear >/dev/null

if [ ! -x out/boot_kernel ]; then
    clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
        runtime/test/boot_kernel.c runtime/src/nokia_rt.c \
        runtime/src/nokia_interp.c -o out/boot_kernel
fi
if [ ! -f out/6600_bootbank_linked.bin ]; then
    "$PY" recompiler/bootbank.py build "$ROM" out/6600_bootbank_linked.bin \
        >/dev/null
fi
if [ ! -f out/6600_runtime.bin ]; then
    tools/build_rom_image.sh >/dev/null
fi

run_loader() {
    log=$1
    budget=$2
    image=$3
    NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 NK_LOW_ROM_IMAGE="$image" \
      NK_REGIONS=out/6600_bootregions_linear.bin@0x80000000 \
      NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
      NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET="$budget" NK_MMIO_N=0 \
      ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

echo "== original linked bank + linear table (old 0xc58 frontier)"
run_loader out/kaep_linear.log 600000 out/6600_bootbank_linked.bin
if ! grep -q -- "stop: budget (0) at 0x00002fe4" out/kaep_linear.log; then
    echo "FAIL: linear table did not reach 0x2fe4" >&2
    tail -20 out/kaep_linear.log >&2
    exit 1
fi
if ! grep -q "recoveries=0" out/kaep_linear.log; then
    echo "FAIL: linear run used crash recovery" >&2
    exit 1
fi
if grep -q -- "stop: budget (0) at 0x00000c58" out/kaep_linear.log; then
    echo "FAIL: still stuck at the KaeP lookup" >&2
    exit 1
fi

echo "== synthetic KaeP descriptor/node (bring-up stand-in)"
"$PY" recompiler/kaep.py synth out/6600_bootbank_linked.bin \
    out/6600_bootbank_kaep.bin >/dev/null
run_loader out/kaep_synth.log 150000 out/6600_bootbank_kaep.bin
if grep -q "stop: budget (0) at 0x00000c58" out/kaep_synth.log; then
    echo "FAIL: synthetic descriptor still stuck at 0xc58" >&2
    exit 1
fi
if ! grep -q "recoveries=0" out/kaep_synth.log; then
    echo "FAIL: synthetic run used crash recovery" >&2
    exit 1
fi

echo "PASS: KaeP page grid, linear regions, and the post-0xc58 frontier"
