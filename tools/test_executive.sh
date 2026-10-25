#!/bin/sh
# test_executive.sh — acceptance test for the EKA1 executive (SWI) call gate.
#
# Round 18 found that the kernel's long 924k-instruction run was not a boot:
# EUser.dll's API stubs are single `svc #N` instructions, and the interpreter
# treated them as no-ops.  Execution therefore fell through the entire stub
# table, entered the real function after it, and looped with a 0x4b0 stack
# leak per iteration until it underran the mapped stack.
#
# This test pins the corrected model:
#
#   1. the kernel SVC handler bounds the service table to 0x444 bytes
#      (0x111 entries) and every non-zero target is inside the kernel text;
#   2. the four unimplemented service slots are explicit (0x8a, 0x94, 0x95,
#      0x96), not silently guessed;
#   3. EUser's SVC stubs map to real service addresses (for example
#      index 0x68 -> 0x5032541c, index 0x4d -> 0x503244e4);
#   4. with NK_SWI_DIRECT=1 the runtime calls those services with the caller's
#      LR still live, and the kernel reaches the next frontier: the missing
#      scheduler/current-thread object and an unbound IAT slot, not a
#      fall-through loop.
#
# The current-thread object and the "request complete" HLE are explicit
# bring-up stand-ins (NK_FAKE_THREAD, NK_SWI_COMPLETE).  The test asserts that
# the run stops at the new, narrower frontier instead of claiming a finished
# boot.
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

echo "== executive table invariants"
"$PY" recompiler/executive.py verify "$ROM" | tee out/executive_verify.log
grep -q "handler limit \[0x50314f7c\] = 0x444" out/executive_verify.log
grep -q "zero/unimplemented: 4 (0x8a, 0x94, 0x95, 0x96)" out/executive_verify.log

echo "== SVC stub map"
"$PY" recompiler/executive.py list "$ROM" --used \
    --json out/executive_used.json >out/executive_used.log
"$PY" - <<'PY'
import json
j = json.load(open("out/executive_used.json"))
rows = {r["index"]: r for r in j["entries"]}
assert rows[0x68]["target"] == 0x5032541c, rows[0x68]
assert rows[0x4d]["target"] == 0x503244e4, rows[0x4d]
assert rows[0x68]["uses"] > 0
assert rows[0x4d]["uses"] > 0
print("ok: SVC 0x68 -> 0x5032541c, 0x4d -> 0x503244e4, both referenced")
PY

"$PY" recompiler/executive.py stubs "$ROM" --image 0x100039e5 \
    --json out/executive_euser.json >out/executive_euser.log
"$PY" - <<'PY'
import json
j = json.load(open("out/executive_euser.json"))
assert len(j["stubs"]) >= 100, len(j["stubs"])
assert all(s["index"] < 0x111 for s in j["stubs"])
print(f"ok: EUser has {len(j['stubs'])} mapped SVC stubs")
PY

echo "== flat runtime image"
if [ ! -f out/6600_runtime.bin ]; then
    tools/build_rom_image.sh >/dev/null
fi

echo "== direct executive dispatch stops at the unbound IAT"
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
NK_IAT_FAKE=0 NK_IAT_LOG=8 NK_RECOVER=0 NK_CALL_INFER=0 \
NK_BUDGET=20000 NK_MMIO_N=0 NK_SWI_LOG=8 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/executive_boot.log 2>&1

grep -q "SWI 0x800068 at 0x50392b78 -> service 0x5032541c" out/executive_boot.log
grep -q "SWI 0x4d at 0x50392b08 -> complete request" out/executive_boot.log
grep -q "unbound IAT slot 0x5037d0e8 at 0x50336fe8" out/executive_boot.log
grep -q "undefined=0" out/executive_boot.log
insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/executive_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 7000 ]; then
    echo "FAIL: direct SWI run only reached ${insns:-0} instructions" >&2
    tail -25 out/executive_boot.log >&2
    exit 1
fi
if ! grep -q "^--- stop: unbound import (IAT) (4) at 0x50336fe8 ---" out/executive_boot.log; then
    echo "FAIL: expected the unbound-IAT frontier" >&2
    tail -25 out/executive_boot.log >&2
    exit 1
fi
if ! grep -q "sp=0x802fff08" out/executive_boot.log; then
    echo "FAIL: SP is not the valid post-MUL-fix value (0x802fff08)" >&2
    grep "^regs: r0=" out/executive_boot.log >&2
    exit 1
fi
if ! grep -q "cpsr=0x800000d3" out/executive_boot.log; then
    echo "FAIL: expected the SVC-mode frontier (cpsr=0x800000d3)" >&2
    grep "^cpsr=" out/executive_boot.log >&2
    exit 1
fi
echo "ok: direct SWI path executed $insns instructions, 0 undefined,"
echo "    stop at the unbound IAT (slot 0x5037d0e8)"

echo "== control: faking the IAT return exposes the next corruption"
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
NK_IAT_FAKE=1 NK_IAT_LOG=8 NK_RECOVER=0 NK_CALL_INFER=0 \
NK_BUDGET=20000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/executive_iat_fake.log 2>&1
grep -q "^--- stop: pc left the image (5) at 0000000000 ---" out/executive_iat_fake.log
grep -q "cpsr=0x600000db" out/executive_iat_fake.log
grep -q "sp=0x802ffc7c" out/executive_iat_fake.log
finsns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/executive_iat_fake.log)
if [ -z "$finsns" ] || [ "$finsns" -lt 8000 ]; then
    echo "FAIL: fake-IAT run only reached ${finsns:-0} instructions" >&2
    tail -20 out/executive_iat_fake.log >&2
    exit 1
fi
echo "ok: fake IAT return runs $finsns instructions, then r4=0x00730072 -> PC 0"

echo "== banked-register model reaches the same unbound-IAT frontier"
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
NK_IAT_FAKE=0 NK_BANKED=1 NK_RECOVER=0 NK_CALL_INFER=0 \
NK_BUDGET=20000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/executive_banked.log 2>&1
grep -q "banked mode stacks:" out/executive_banked.log
grep -q "undefined=0" out/executive_banked.log
grep -q "sp=0x802fff08" out/executive_banked.log
grep -q "^--- stop: unbound import (IAT) (4) at 0x50336fe8 ---" out/executive_banked.log
binsns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/executive_banked.log)
if [ -z "$binsns" ] || [ "$binsns" -lt 7000 ]; then
    echo "FAIL: banked run only reached ${binsns:-0} instructions" >&2
    tail -20 out/executive_banked.log >&2
    exit 1
fi
echo "ok: banked model executed $binsns instructions with valid mode banks"

echo "PASS: EKA1 executive table, SVC stubs, and the direct call gate"
