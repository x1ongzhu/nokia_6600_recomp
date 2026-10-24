#!/bin/sh
# test_bootregions.sh — pin the mask-ROM boot-region table model.
#
# Round 12 reached the image-loader thread with an EMPTY table at the
# high-vector fallback 0xfffff400.  The loader copies its input bank table to
# super_page+0x400, so an empty input makes it build the list at
# 0xfffff000+0x400.  recompiler/bootregions.py derives the three banks the
# mask ROM must install from TRomHeader and the boot harness installs them with
# NK_REGIONS.  Acceptance:
#   - the derived table is boot/ROM/RAM with the RAM bank carrying 0x4000
#   - with the table the super page is 0x802ff000, not the 0xfffff000 fallback
#   - the copied list at 0x802ff400 has 3 compacted entries
#   - still zero stale-call recoveries / undefined instructions, and the first
#     UPP write is unchanged
#   - without the table the list is still empty at 0xfffff400 (control)
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

IMG=out/6600_runtime.bin
if [ ! -f "$IMG" ] || [ "$ROM" -nt "$IMG" ]; then
    tools/build_rom_image.sh "$ROM" "$IMG" >out/bootregions_romimage.log 2>&1
fi

"$PY" recompiler/bootregions.py verify "$ROM" >out/bootregions_verify.log
"$PY" recompiler/bootregions.py build "$ROM" out/6600_bootregions.bin \
    >out/bootregions_build.log
"$PY" recompiler/bootbank.py build "$ROM" out/6600_bootbank_linked.bin \
    >out/bootregions_bank.log

clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

fail=0
check() {
    if grep -q "$1" "$2"; then echo "ok: $3"; else echo "FAIL: $3"; fail=1; fi
}

# --- with the derived bank table -------------------------------------------
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_REGIONS=out/6600_bootregions.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  NK_WATCH=0x1244 NK_WATCH_HITS=1 NK_WATCH_LOG=1 \
  NK_DUMP=0x802ff400:0x40 NK_DUMP_FILE=out/bootregions_list.bin \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
  >out/bootregions_run.log 2>&1 || true

check "boot-region table out/6600_bootregions.bin: 56 bytes at 0x80000000" \
    out/bootregions_run.log "the harness installs the derived table"
check "watch] pc=0x00001244" out/bootregions_run.log \
    "the image-loader thread still runs"
check "sp=0x802ff3fc" out/bootregions_run.log \
    "the super page is the RAM bank top (0x802ff000), not 0xfffff000"
check "recoveries=0" out/bootregions_run.log "no stale-call recovery"
check "undefined=0" out/bootregions_run.log "no undefined instruction"
check "write 0x08000008 = 0x37" out/bootregions_run.log \
    "the first UPP register write is unchanged"

if "$PY" - <<'EOF'
import struct, sys
b = open('out/bootregions_list.bin', 'rb').read()
assert struct.unpack_from('<I', b, 0)[0] == 3, b[:4]
lins = [struct.unpack_from('<4I', b, 8 + 16 * i)[3] for i in range(3)]
assert lins == [0, 0x50000000, 0x80000000], lins
EOF
then echo "ok: the copied list has boot/ROM/RAM entries"
else echo "FAIL: the copied list has boot/ROM/RAM entries"; fail=1
fi

# --- control: no table, the round-12 fallback ------------------------------
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  NK_WATCH=0x1244 NK_WATCH_HITS=1 NK_WATCH_LOG=1 \
  NK_DUMP=0xfffff400:0x10 NK_DUMP_FILE=out/bootregions_empty.bin \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
  >out/bootregions_empty.log 2>&1 || true

check "pc=0x00001244" out/bootregions_empty.log \
    "the empty-table run also reaches 0x1244"
check "sp=0xfffff3fc" out/bootregions_empty.log \
    "without a table the super page is the 0xfffff000 fallback"
check "recoveries=0" out/bootregions_empty.log \
    "the fallback run is also clean"

if "$PY" - <<'EOF'
import struct
b = open('out/bootregions_empty.bin', 'rb').read()
assert struct.unpack_from('<I', b, 0)[0] == 0, b[:4]
EOF
then echo "ok: the fallback list is empty (round-12 control)"
else echo "FAIL: the fallback list is empty (round-12 control)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "boot-region table test FAILED"
    exit 1
fi
echo "boot-region table test OK"
