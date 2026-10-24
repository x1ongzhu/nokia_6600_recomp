#!/bin/sh
# test_loader.sh — regression check for the EKA1 record loader / import binder.
#
# Builds boot_kernel and runs the assisted path:
#   packed record -> text/data/edata/dllref
#   kernel TDllRefTable -> referenced DLLs -> export directory
#   first import stub -> .edata ordinal
#
# It deliberately does not assert how far execution gets: that frontier changes
# as the ROM linker work progresses.  It asserts that the loader still finds the
# sections, the two DLLs, and resolves the first import without an unbound IAT.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi

mkdir -p out
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

log=out/loader_test.log
NK_E32_SECTIONS=1 NK_CALL_INFER=1 NK_BUDGET=1000 NK_MMIO_N=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --e32 0x3268c0 \
    >"$log" 2>&1 || true

fail=0
check() {
    if grep -q "$1" "$log"; then
        echo "ok: $2"
    else
        echo "FAIL: $2"
        fail=1
    fi
}

check "image uid3 0x100058e8" "kernel record located"
check "image uid3 0x100065a5" "first referenced DLL located"
check "image uid3 0x100039e5" "second referenced DLL located"
check "call: import stub" "import stub recognised"
check "unbound IAT=0" "import resolved through .edata"
check "call fixups=[1-9]" "interworking call repair ran"

if [ "$fail" -ne 0 ]; then
    echo "--- $log ---"
    sed -n '1,25p' "$log"
    exit 1
fi
echo "EKA1 loader test OK"
