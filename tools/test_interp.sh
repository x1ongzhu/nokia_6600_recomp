#!/bin/sh
# test_interp.sh — build and run the ARMv4T interpreter self-test.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mkdir -p out
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/interp_selftest.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/interp_selftest
./out/interp_selftest
