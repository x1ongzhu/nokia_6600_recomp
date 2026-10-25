#!/bin/sh
# test_kaep.sh — acceptance test for the KaeP/page-tag round.
#
#   1. the KaeP block and the 0x20ec page-tag grid are structural invariants;
#   2. the legacy attr=1 boot-region table cannot satisfy 0x1a1c/0x1b34;
#   3. the linear profile (RAM type 2, ROM/boot type 5 + 0x04000000) lets the
#      *original* linked boot bank pass the old 0xc58 frontier and reach the
#      page-table builder at 0x2fe4;
#   4. `kaep.py unpack` extracts the 0x20-byte KaeP/PeaK record and the
#      0x1423dc-byte embedded image byte-for-byte;
#   5. `kaep.py install` places an executable ARM `ldr pc` handoff at linked
#      0x80; with the staging regions and no stop PC it enters the real kernel
#      instead of executing the opaque record bytes as an SWI.
#
# The exact 0x2fe4 stop is a page-table fill, not a finished boot: it is
# pinned here so a regression cannot silently move the frontier back.  The
# 0x20-byte record codec is still opaque; unpack/install preserve the
# container boundary rather than pretending to decrypt it.
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

echo "== KaeP container unpack"
"$PY" recompiler/kaep.py unpack "$ROM" \
    out/6600_kaep_record.bin out/6600_kaep_image.bin \
    --json out/kaep_container.json >/dev/null
record_size=$(wc -c <out/6600_kaep_record.bin | tr -d ' ')
image_size=$(wc -c <out/6600_kaep_image.bin | tr -d ' ')
[ "$record_size" = "32" ] || {
    echo "FAIL: KaeP record is $record_size bytes, want 32" >&2
    exit 1
}
[ "$image_size" = "1319900" ] || {
    echo "FAIL: KaeP image is $image_size bytes, want 1319900" >&2
    exit 1
}
"$PY" - <<'PY'
import json
c = json.load(open("out/kaep_container.json"))
assert c["magic"] == "KaeP", c
assert c["record_offset"] == 0x12e, c
assert c["record_size"] == 0x20, c
assert c["image_offset"] == 0x14e, c
assert c["image_size"] == 0x1423dc, c
assert c["record_sha256"] == (
    "ff0334e2aeaa9aa7f2a78f04f9e7518a"
    "2c37d51fc615cfcea9017247c0eccb81"), c
assert c["image_sha256"] == (
    "f8d1db85fdb64ba987637f7b03256a2a"
    "b4af6bf2d939860dd6fcfdaa40c4c106"), c
print("ok: KaeP record 0x20 @ 0x12e, image 0x1423dc @ 0x14e")
PY

echo "== boot-region profiles"
"$PY" recompiler/bootregions.py verify "$ROM" >/dev/null
"$PY" recompiler/bootregions.py build "$ROM" \
    out/6600_bootregions.bin >/dev/null
"$PY" recompiler/bootregions.py verify "$ROM" --profile linear >/dev/null
"$PY" recompiler/bootregions.py build "$ROM" \
    out/6600_bootregions_linear.bin --profile linear >/dev/null
"$PY" recompiler/bootregions.py verify "$ROM" --profile staging >/dev/null
"$PY" recompiler/bootregions.py build "$ROM" \
    out/6600_bootregions_staging.bin --profile staging >/dev/null

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
if ! grep -q -E -- "stop: budget \(0\) at 0x00002fe[48]" out/kaep_linear.log; then
    echo "FAIL: linear table did not reach the 0x2fe4 page-table fill" >&2
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

echo "== installed KaeP handoff enters the kernel"
"$PY" recompiler/kaep.py install out/6600_bootbank_linked.bin "$ROM" \
    out/6600_bootbank_kaep_install.bin >/dev/null
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_kaep_install.bin \
  NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=1500000 NK_MMIO_N=0 \
  ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/kaep_install.log 2>&1

if grep -q -- "SWI 0xf9ea00 at 0x00000080" out/kaep_install.log; then
    echo "FAIL: 0x80 still executes the KaeP record as an SWI" >&2
    exit 1
fi
if ! grep -q "undefined=0" out/kaep_install.log; then
    echo "FAIL: installed handoff hit an undefined instruction" >&2
    tail -20 out/kaep_install.log >&2
    exit 1
fi
if ! grep -q "^last pcs:.* 5039" out/kaep_install.log; then
    echo "FAIL: installed handoff did not enter the kernel" >&2
    tail -20 out/kaep_install.log >&2
    exit 1
fi
kinsns=$(sed -n 's/^insns=\([0-9]*\).*/\1/p' out/kaep_install.log)
if [ -z "$kinsns" ] || [ "$kinsns" -lt 1000000 ]; then
    echo "FAIL: kernel ran only ${kinsns:-0} instructions after handoff" >&2
    exit 1
fi

echo "PASS: KaeP container unpack, page grid, linear regions, and kernel handoff"
