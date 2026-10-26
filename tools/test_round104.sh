#!/bin/sh
# test_round104.sh - the ROM's EUser export table is shifted for applications.
#
# Round 103 showed EFile calling slot 0x503b37c4 with one pointer argument
# while the ROM's entry 12 there (0x503988a8) is a three-argument heap grow.
# This round confirms the mismatch is not EFile's fault:
#
#   - slot 0x503b37c4 is imported by ~150 ROM images;
#   - SplashScreen (0x509ef15c: `mov r0,r4; bl`) and Starter
#     (0x509ececc: `ldr r0,[sp]; bl`) also call it with a single argument;
#   - three entries lower, ROM export 9 = 0x5037fca0 starts with
#     `push {r4,r5,lr}; mov r4,r0` and panics 0x2c/0x30 on a null cleanup
#     stack - i.e. a one-argument CleanupStack::PushL.  So for this ordinal the
#     application's .def is three lower than the ROM table (the same K-3 rule
#     the kernel map encodes).
#
# Binding 0x503b37c4 to 0x5037fca0 makes EFile *return* from the call and
# continue at 0x503bfcf8/0x503bfcfe (before, it left with KErrNoMemory), so the
# hypothesis is right.  A global rotation of the whole table (NK_EUSER_ROTATE)
# is not: shifting every entry from 6/12/14 by 3 all break at
# `pc left the image 0xe92d4070`, because the shift is not uniform.
#
# The new frontier is `[obj+0x10] == 0` at 0x503bfcfa: EFile loads a method
# pointer out of an object and branches to it (`bl 0x503c5980` = `bx r1`).
#
# Acceptance:
#   - the offline scan finds >100 importers and the PushL-shaped export 9;
#   - with the binding: "applied 1 application rebinds", Thumb 1,383, last PCs
#     contain 0x503bfcf8, stop is a null call;
#   - global rotation by 3 lands on 0xe92d4070.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 104: the ROM EUser export table is shifted for applications"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'PY'
import struct, json
d = open('out/6600_runtime.bin','rb').read(); base = 0x50000000
def w(a): return struct.unpack_from('<I', d, a - base)[0]
def h(a): return struct.unpack_from('<H', d, a - base)[0]
TARGET = 0x503b37c4
j = json.load(open('out/6600_runtime_layout.json'))
n = 0
for im in j['images']:
    lo, hi = im['code'], im['code'] + im['text_size']
    if not (0x50000000 <= lo < 0x52000000) or im['text_size'] < 0x400:
        continue
    for a in range(lo, hi - 8, 2):
        if h(a) == 0x4b01 and h(a + 2) == 0x681b and h(a + 4) == 0x4718:
            if w(((a + 4) & ~3) + 4) == TARGET:
                n += 1
                break
assert n > 100, n
print('ok: %d ROM images import slot 0x503b37c4' % n)
ed = 0x503b3794
assert w(ed + 4 * 12) == 0x503988a8      # three-argument heap grow
assert w(ed + 4 * 9)  == 0x5037fca0      # one-argument PushL shape
print('ok: export 12 = 0x503988a8 (3-arg grow), export 9 = 0x5037fca0 (1-arg PushL)')
PY

run_efile() {
    log=$1; shift
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
        NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 \
        NK_THREAD_HEAP=0x80905ec4 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
        NK_ALLOC_LOG=0 NK_ALLOC_HLE_KERNEL_ONLY=1 NK_ALLOC_BASE=0x80600000 \
        NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
        NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
        NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
        NK_TIMER=1 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
        NK_IMPORTMAP_REVERT=1 NK_IMPORTMAP_NO_REVERT=0x503b3948 \
        NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 \
        NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 NK_SCHED_FAKE=1 \
        NK_SCHED_ENTRY=0x503b7105 NK_SCHED_STACK=0x80560000 \
        NK_SCHED_STACK_EXTRA=0x600 NK_SCHED_STACK_FILL=0xdead0000 \
        NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=6 \
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 \
        NK_SWI_RET=0x1c:-1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

printf '0x503b37c4 0x5037fca0\n' > out/round104_push.map
run_efile out/round104_push.log NK_IMPORTMAP_APP=out/round104_push.map
run_efile out/round104_rot.log NK_EUSER_ROTATE=3

grep -q "importmap: applied 1 application rebinds" out/round104_push.log
grep -q "Thumb 1383)" out/round104_push.log
grep -q "503bfcf8" out/round104_push.log
grep -q "^--- stop: null call (8)" out/round104_push.log
grep -q "euser: rotated export entries 6..1787 by 3" out/round104_rot.log
grep -q "^--- stop: pc left the image (5) at 0xe92d4070 ---" out/round104_rot.log

echo "ok: every ROM image calls slot 0x503b37c4 with one pointer argument"
echo "ok: ROM export 9 (0x5037fca0) is that one-argument PushL, three below 12"
echo "ok: binding it makes EFile return from the call and continue at 0x503bfcf8"
echo "ok: a global table rotation is wrong - the shift is not uniform"
echo "ok: new frontier is [obj+0x10] == 0 at 0x503bfcfa"
echo "PASS: round 104 identifies the EUser table shift and its first mapping"
