#!/bin/sh
# build_kernel_smoke.sh — reproduce the native 6600 kernel-function smoke test.
#
#   tools/build_kernel_smoke.sh [NHL105530.C1]
#
# With no argument it uses the already-extracted 6600_mcu.bin.  Generated
# files go to out/ (gitignored) so no firmware or generated C is committed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi

if [ "$#" -ge 1 ]; then
    "$PY" recompiler/wd2.py extract "$1" 6600_mcu.bin
fi
if [ ! -f 6600_mcu.bin ]; then
    echo "6600_mcu.bin missing; pass the NHL105530.C1 container" >&2
    exit 1
fi

mkdir -p out
"$PY" recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin
# The kernel entry is ARM in the page-header-free text.  Seed it plus the
# real MMIO write helper at 0x50312eb4 and a few neighbours; the lifter only
# needs a handful of functions for this smoke test.
"$PY" recompiler/recursive.py fw/6600_kernel.bin out/kernel_mixed.json \
    --base 0x50310000 --entry 0x50310054 --max-bytes 2048 \
    --extra-entry 0x50312eb4 --extra-entry 0x5031308c \
    --extra-entry 0x503133d0 --extra-entry 0x50313518
"$PY" recompiler/lift.py out/kernel_mixed.json --all --out out/kernel_mixed.c
"$PY" recompiler/gen_register.py out/kernel_mixed.json out/kernel_register.c

clang -std=c11 -Iruntime/include \
    runtime/test/smoke_kernel.c out/kernel_mixed.c out/kernel_register.c \
    runtime/src/nokia_rt.c runtime/src/nokia_interp.c -o out/smoke_kernel
./out/smoke_kernel
