#!/bin/sh
# build_rom_image.sh — assemble the flat 6600 runtime ROM.
#
#   tools/build_rom_image.sh                     # 6600_mcu.bin -> out/6600_runtime.bin
#   tools/build_rom_image.sh ROM OUT.bin
#   tools/build_rom_image.sh ROM OUT.bin --no-snap
#
# `recompiler/romimage.py build` places the kernel and every DLL reachable
# from its TDllRefTable at their runtime addresses, the ROMFS directory block
# at 0x50300000 and the ROMFS files at their (linear) runtime addresses.
# The result is a 22 MiB image that the boot harness can map directly:
#
#   ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --rom-image out/6600_runtime.bin
#
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi

ROM=${1:-6600_mcu.bin}
OUT=${2:-out/6600_runtime.bin}
if [ $# -ge 2 ]; then shift 2; elif [ $# -eq 1 ]; then shift 1; fi

if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: $PY recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
"$PY" recompiler/romimage.py build "$ROM" "$OUT" \
    --json "${OUT%.bin}_layout.json" --place-rodata "$@"

echo
echo "hint: map the image at 0x50000000 and start at the kernel entry:"
echo "      ./out/boot_kernel $ROM fw/6600_kernel.bin --rom-image $OUT"
