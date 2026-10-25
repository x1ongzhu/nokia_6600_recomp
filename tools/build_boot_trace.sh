#!/bin/sh
# build_boot_trace.sh — build and run the native ARMv4T boot trace.
#
#   tools/build_boot_trace.sh                 # 6600_mcu.bin + carved kernel
#   tools/build_boot_trace.sh ROM KERNEL
#   NK_BUDGET=20000 NK_TRACE=1 tools/build_boot_trace.sh
#
# Executes the kernel entry in the runtime's own interpreter (not Unicorn) and
# prints the frontier: the first undefined instruction, the first MMIO events,
# register state and the last PCs.  Generated binaries go to out/ (gitignored).
# Round 16: wd2.py kernel now carves the page-header-free text, and the entry
# 0x50310054 is ARM (`push {r4,r5,r6,lr}`).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi

ROM=${1:-6600_mcu.bin}
KERNEL=${2:-fw/6600_kernel.bin}

if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: $PY recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
if [ ! -f "$KERNEL" ]; then
    mkdir -p fw out
    "$PY" recompiler/wd2.py kernel "$ROM" "$KERNEL"
fi

mkdir -p out
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

# Keep the default log readable: 200 MMIO events, no per-instruction trace.
: "${NK_MMIO_N:=200}"
: "${NK_BUDGET:=200000}"
export NK_MMIO_N NK_BUDGET

echo "== boot trace: $ROM $KERNEL"
if [ -n "${NK_E32:-}" ]; then
    ./out/boot_kernel "$ROM" "$KERNEL" --e32 "$NK_E32"
else
    ./out/boot_kernel "$ROM" "$KERNEL"
fi

echo
echo "hint: the blob path above is a minimal entry trace; the real kernel run is"
echo "      tools/build_rom_image.sh +"
echo "      NK_KERNEL_VECTORS=1 ./out/boot_kernel ROM fw/6600_kernel.bin \\"
echo "        --rom-image out/6600_runtime.bin   (see tools/test_pagestream.sh)"
echo "      NK_TRACE=1 NK_TRACE_N=120 shows the instruction stream;"
echo "      NK_INFER=0 disables Thumb<->ARM inference;"
echo "      NK_CALL_INFER=1 repairs interworking call sites;"
echo "      NK_E32=0x3268c0 NK_E32_SECTIONS=1 loads the packed EKA1"
echo "        record and its referenced DLLs (import binding)."
echo "      add '--e32 <file-offset>' to run a built-in ROM image instead."
