#!/bin/sh
# build_bringup_image.sh — build the page-header-free flat runtime ROM.
#
#   tools/build_bringup_image.sh                    # -> out/6600_runtime_bringup.bin
#   tools/build_bringup_image.sh ROM OUT.bin
#
# Round 16 correction: the old round-5..15 bring-up patch
# (config/patches-6600.txt) restored a Thumb `pop` in bytes that were actually
# a 0xec-byte page header, not kernel/euser code.  The page-header-free stream
# (recompiler/pagestream.py) makes the text contiguous and the patch is
# obsolete, so this variant is now just an alias for the faithful build.  The
# patch file and callmap are kept for history; neither is applied here.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
OUT=${2:-out/6600_runtime_bringup.bin}

exec "$root/tools/build_rom_image.sh" "$ROM" "$OUT"
