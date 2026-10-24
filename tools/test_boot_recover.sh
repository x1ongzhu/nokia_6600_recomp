#!/bin/sh
# test_boot_recover.sh — boot the flat image with call recovery enabled.
#
# Bring-up acceptance test (round 8):
#   - assemble the bring-up image (patched missing tail),
#   - run the kernel entry with the known call-site map,
#   - require the entry to complete and return to the mask-ROM stand-in,
#   - require no fatal stop / undefined instruction and <= 20 skipped calls,
#   - exercise the round-8 observability: NK_WATCH must dump the call ring at
#     the UPP init function, and the spin watchdog / PC-space guard must fire
#     on the faithful (unpatched) image instead of burning the budget.
#
# The exact frontier is deliberately not asserted: it moves as more stale call
# targets are resolved.  The log records the last PCs and every skipped call.
# The old "2M instructions" result was an artifact of the missing Thumb `pop`
# at 0x5039adcc (see docs/PROGRESS.md §B6), not progress.
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
if [ ! -f "$IMG" ] || [ "$ROM" -nt "$IMG" ]; then
    tools/build_bringup_image.sh "$ROM" "$IMG" >out/bringup_build.log 2>&1
fi

clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_BUDGET=${NK_BUDGET:-2000000} \
NK_RECOVER=1 NK_RECOVER_LOG=${NK_RECOVER_LOG:-24} NK_RECOVER_MAX=200 \
NK_CALL_INFER=1 NK_SNAP_WINDOW_ARM=${NK_SNAP_WINDOW_ARM:-0x200} \
NK_SNAP_WINDOW_THUMB=${NK_SNAP_WINDOW_THUMB:-0x400} \
NK_SPIN=1 NK_SPIN_MAX=${NK_SPIN_MAX:-20000} NK_CODE_ONLY=1 \
NK_CALLMAP=config/callmap-6600.txt NK_MMIO_N=${NK_MMIO_N:-24} \
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
    tail -20 out/boot_recover.log
    exit 1
fi

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/boot_recover.log)
rec=$(sed -n 's/.*recoveries=\([0-9][0-9]*\).*/\1/p' out/boot_recover.log)
if [ -z "$insns" ] || [ "$insns" -lt 150 ]; then
    echo "FAIL: only $insns instructions executed (want >= 150, entry completes)"
    tail -20 out/boot_recover.log
    exit 1
fi
if [ -z "$rec" ] || [ "$rec" -gt 20 ]; then
    echo "FAIL: $rec recoveries (want <= 20)"
    tail -20 out/boot_recover.log
    exit 1
fi
if ! grep -q -- "--- stop: returned" out/boot_recover.log; then
    echo "FAIL: kernel entry did not return through the mask-ROM stand-in"
    tail -20 out/boot_recover.log
    exit 1
fi

echo "ok: $insns instructions, $rec skips, entry returned"
echo "ok: callmap loaded, no undefined instruction"
grep -E "callmap |skip:|recover #|stop:|mmio:|last pcs" out/boot_recover.log | tail -12

# --- round 8: NK_WATCH dumps the call ring at the UPP init function ---------
NK_BUDGET=2000 NK_RECOVER=1 NK_RECOVER_LOG=2 NK_RECOVER_MAX=50 \
NK_CALL_INFER=1 NK_SNAP_WINDOW_ARM=0x200 NK_SNAP_WINDOW_THUMB=0x400 \
NK_SPIN=1 NK_SPIN_MAX=20000 NK_CODE_ONLY=1 \
NK_CALLMAP=config/callmap-6600.txt NK_FIXUP_LOG=2 \
NK_WATCH=0x50313518 NK_WATCH_HITS=1 NK_WATCH_LOG=6 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/watch.log 2>&1 || true
if ! grep -q "\[watch\] pc=0x50313518" out/watch.log; then
    echo "FAIL: NK_WATCH did not fire at 0x50313518"
    tail -10 out/watch.log
    exit 1
fi
if ! grep -q "\[watch\] last 6 of" out/watch.log; then
    echo "FAIL: NK_WATCH did not dump the call ring"
    tail -10 out/watch.log
    exit 1
fi
echo "ok: NK_WATCH fired at 0x50313518 and dumped the call ring"

# --- round 8: spin watchdog / PC-space guard on the faithful image ----------
FAITHFUL=out/6600_runtime.bin
if [ ! -f "$FAITHFUL" ] || [ "$ROM" -nt "$FAITHFUL" ]; then
    tools/build_rom_image.sh "$ROM" "$FAITHFUL" >out/rom_build.log 2>&1
fi
NK_BUDGET=200000 NK_RECOVER=1 NK_RECOVER_LOG=2 NK_RECOVER_MAX=400 \
NK_CALL_INFER=1 NK_SNAP_WINDOW_ARM=0x200 NK_SNAP_WINDOW_THUMB=0x400 \
NK_SPIN=1 NK_SPIN_MAX=2000 NK_CODE_ONLY=1 \
NK_CALLMAP=config/callmap-6600.txt NK_FIXUP_LOG=2 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$FAITHFUL" \
    >out/spin.log 2>&1 || true
if ! grep -q "\[interp\] spin:" out/spin.log; then
    echo "FAIL: spin watchdog did not fire on the faithful image"
    tail -10 out/spin.log
    exit 1
fi
echo "ok: spin watchdog fired on the faithful image"

# Direct unit test for the PC-space guard: entering at a RAM address must be
# rejected before the first instruction executes.
NK_ENTRY=0x802fa000 NK_ENTRY_ARM=1 NK_CODE_ONLY=1 NK_BUDGET=10 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/ram_entry.log 2>&1 || true
if ! grep -q "pc left the image.*802fa000" out/ram_entry.log; then
    echo "FAIL: PC-space guard accepted a RAM entry point"
    tail -10 out/ram_entry.log
    exit 1
fi
echo "ok: PC-space guard rejected a RAM entry point"

echo "boot recovery test OK"
