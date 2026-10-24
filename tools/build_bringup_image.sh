#!/bin/sh
# build_bringup_image.sh — build the flat runtime ROM with bring-up patches.
#
#   tools/build_bringup_image.sh                    # -> out/6600_runtime_bringup.bin
#   tools/build_bringup_image.sh ROM OUT.bin
#
# The raw image (tools/build_rom_image.sh) is the faithful assembly of the
# packed records.  This variant additionally applies config/patches-6600.txt:
# bytes missing from the packed text (see the file for details).  It is the
# image used by tools/test_boot_recover.sh.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
OUT=${2:-out/6600_runtime_bringup.bin}

exec "$root/tools/build_rom_image.sh" "$ROM" "$OUT" --patch config/patches-6600.txt
