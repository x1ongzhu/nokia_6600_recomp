#!/bin/sh
# test_round108.sh - EFile dereferences a stale pointer to freed heap memory.
#
# With slot 0x503b37c4 bound to the one-argument PushL shape and thread+0x58
# published, EFile reaches its descriptor-grow dispatch:
#
#   503bfcf2  adds r4, r0, #0      ; r4 = 0x510355e0, from 0x503bdc5c
#   503bfcf8  ldr r0, [r4]
#   503bfcfa  ldr r1, [r0, #0x10]
#   503bfcfe  bl 0x503c5980        ; bx r1 -> 0xf0009b06
#
# At 0x503bfcfa r0 = 0x5103559c, i.e. the object's first word is a pointer to
# another heap object - not a vtable.  But the constructor that built it
# (0x503bdca4, reached from 0x503bdc5c) definitely installs one:
#
#   503bdca4  push {r4,lr} ; r4 = r0
#   503bdcac  bl 0x503c5ce0            ; base ctor
#   503bdcb0  ldr r0, [pc, #0x10]      ; 0x503c80c4  (vtable in EFile .rdata)
#   503bdcb2  str r0, [r4]
#   503bdcb4  ldr r0, [pc, #0x10]      ; 0xffff8001  (kernel handle constant)
#   503bdcb6  str r0, [r4, #0x18]
#   503bdcb8  movs r0, #0
#   503bdcba  str r0, [r4, #0x1c]
#
# so the memory at 0x510355e0 was freed and reused between construction and use.
# The tail of the object is still intact ([+0x18]=0xffff8001, [+0x1c]=0 just as
# the ctor wrote them) while the first 0x18 bytes were overwritten with what
# looks like a queue node ([0]=0x5103559c, [0x10]=0x510355dc), i.e. something
# destroyed a live object and the block was handed out again.  The prime suspect is the invented CCleanup
# graph we publish at thread+0x58: PushL now works, but our iBase/iTop/iNext
# layout may make the corresponding Pop/PopAndDestroy destroy the wrong thing.
#
# Acceptance:
#   - the ctor literal is 0x503c80c4 and the +0x18 field is 0xffff8001;
#   - at 0x503bfcfa r0 = 0x5103559c, i.e. not that vtable;
#   - the stop is `pc left the image 0xf0009b06`.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 108: EFile dereferences a stale pointer"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel 2>/dev/null || \
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'PY'
import struct
d = open('out/6600_runtime.bin','rb').read(); base = 0x50000000
def w(a): return struct.unpack_from('<I', d, a - base)[0]
def lit(addr, imm):
    return w(((addr + 4) & ~3) + imm)
assert lit(0x503bdcb0, 0x10) == 0x503c80c4, hex(lit(0x503bdcb0, 0x10))
assert lit(0x503bdcb4, 0x10) == 0xffff8001, hex(lit(0x503bdcb4, 0x10))
print('ok: ctor 0x503bdca4 installs vtable 0x503c80c4 and 0xffff8001 at +0x18')
PY

printf '0x503b37c4 0x5037fca0\n' > out/round108_push.map
env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=600000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 NK_THREAD_HEAP=0x80905ec4 \
    NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_HLE_KERNEL_ONLY=1 NK_ALLOC_BASE=0x80600000 \
    NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=1 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_IMPORTMAP_REVERT=1 NK_IMPORTMAP_NO_REVERT=0x503b3948 \
    NK_IMPORTMAP_APP=out/round108_push.map NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_SCHED=1 \
    NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 NK_SCHED_STACK=0x80560000 \
    NK_SCHED_STACK_EXTRA=0x600 NK_SCHED_STACK_FILL=0xdead0000 \
    NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=0 \
    NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 \
    NK_SWI_RET=0x1c:-1 NK_WATCH=0x503bfcfa NK_WATCH_HITS=1 NK_WATCH_LOG=3 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round108_vt.log 2>&1

grep -q "pc=0x503bfcfa thumb=1" out/round108_vt.log
grep -q "r0=0x5103559c" out/round108_vt.log
grep -q "r4=0x510355e0" out/round108_vt.log
grep -q "^--- stop: pc left the image (5) at 0xf0009b06 ---" out/round108_vt.log

echo "ok: the ctor installs vtable 0x503c80c4, but the object now holds"
echo "    0x5103559c, so the memory was freed and reused"
echo "ok: prime suspect is the invented CCleanup graph published at thread+0x58"
echo "    (PushL works, but the matching Pop may destroy the wrong object)"
echo "PASS: round 108 shows EFile using a stale pointer to freed heap memory"
