#!/bin/sh
# test_boot_recover.sh — boot the page-header-free flat image with recovery on.
#
# Round 16 correction: the "missing Thumb pop" / callmap / bring-up patches
# were artifacts of the 0xec-byte page headers.  On the corrected packed
# stream the kernel entry is ARM, its exports match the text at 98.1%, and the
# clean run needs no call recovery at all.  This test keeps the recover/spin/
# watch observability exercised while asserting the new baseline:
#
#   - the real kernel entry runs >=900k instructions;
#   - no undefined instruction and no unbound import;
#   - recovery, when enabled, stays bounded (<= 2 events);
#   - NK_WATCH still dumps a call ring at a real kernel PC.
#
# The old 197-instruction / 4-skip result is kept in docs/PROGRESS.md as
# history; it executed the page header, not the kernel.
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
IMG=out/6600_runtime_bringup.bin
tools/build_rom_image.sh "$ROM" "$IMG" >out/bringup_build.log 2>&1

clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_KERNEL_VECTORS=1 \
NK_BUDGET=${NK_BUDGET:-1000000} \
NK_RECOVER=1 NK_RECOVER_LOG=2 NK_RECOVER_MAX=20 \
NK_CALL_INFER=0 NK_SPIN=1 NK_SPIN_MAX=${NK_SPIN_MAX:-20000} \
NK_CODE_ONLY=1 NK_MMIO_N=${NK_MMIO_N:-0} \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/boot_recover.log 2>&1 || true

if ! grep -q "uid3 0x100058e8" out/boot_recover.log; then
    echo "FAIL: kernel not located in $IMG"
    tail -20 out/boot_recover.log
    exit 1
fi
if grep -q "undefined instruction" out/boot_recover.log; then
    echo "FAIL: undefined instruction reached"
    grep -n "undefined" out/boot_recover.log | head -5
    exit 1
fi
insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/boot_recover.log)
rec=$(sed -n 's/.*recoveries=\([0-9][0-9]*\).*/\1/p' out/boot_recover.log)
if [ -z "$insns" ] || [ "$insns" -lt 900000 ]; then
    echo "FAIL: only ${insns:-0} instructions (want >= 900000)"
    tail -20 out/boot_recover.log
    exit 1
fi
if [ -z "$rec" ] || [ "$rec" -gt 2 ]; then
    echo "FAIL: $rec recoveries on the corrected image (want <= 2)"
    tail -20 out/boot_recover.log
    exit 1
fi
if ! grep -q "unbound IAT=0" out/boot_recover.log; then
    echo "FAIL: imports did not all bind"
    tail -20 out/boot_recover.log
    exit 1
fi
echo "ok: $insns instructions, $rec recoveries, imports bound"

# NK_WATCH must still dump the call ring on the real path.
NK_KERNEL_VECTORS=1 NK_BUDGET=1000000 NK_RECOVER=0 NK_CALL_INFER=0 \
NK_WATCH=0x5039b2a0 NK_WATCH_HITS=1 NK_WATCH_LOG=8 NK_MMIO_N=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/watch.log 2>&1 || true
if ! grep -q "\[watch\] pc=0x5039b2a0" out/watch.log; then
    echo "FAIL: NK_WATCH did not fire at 0x5039b2a0"
    tail -10 out/watch.log
    exit 1
fi
if ! grep -q "\[watch\] last " out/watch.log; then
    echo "FAIL: NK_WATCH did not dump the call ring"
    tail -10 out/watch.log
    exit 1
fi
echo "ok: NK_WATCH fired at 0x5039b2a0 and dumped the call ring"
grep -E "^(insns=|mmio:|last pcs)" out/boot_recover.log | tail -3
echo "boot/recovery test OK"
