#!/bin/sh
# test_boot_recover.sh — boot the flat image with call recovery enabled.
#
# Current bring-up acceptance test (round 5, after the Thumb format-2 fix):
#   - assemble the bring-up image (patched missing tail),
#   - run the kernel entry with the known call-site map,
#   - require the entry to complete and return to the mask-ROM stand-in,
#   - require no fatal stop / undefined instruction and <= 20 skipped calls.
#
# The exact frontier is deliberately not asserted: it moves as more stale call
# targets are resolved.  The log records the last PCs and every skipped call.
# A 1M-instruction budget is still accepted, but it is no longer the goal: the
# previous "2M instructions" result was produced by a Thumb decoder bug that
# turned `adds rd,rs,#imm` into a register add.
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
NK_CALLMAP=config/callmap-6600.txt NK_MMIO_N=${NK_MMIO_N:-24} \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/boot_recover.log 2>&1 || true

if ! grep -q "runtime image uid3 0x100058e8" out/boot_recover.log; then
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
echo "boot recovery test OK"
