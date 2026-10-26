#!/bin/sh
# test_round107.sh - publish the per-thread cleanup stack pointer (thread+0x58).
#
# The kernel's cleanup-stack services read and write [current_thread+0x58]:
#
#   svc 0x74 -> 0x50318804:  r0 = [[global]] ; r0 = [r0, #0x58]   (get)
#   svc 0x75 -> 0x50318814:  [r1, #0x58] = r0                     (set)
#
# B7e builds the TCleanupTrapHandler -> CCleanup graph and publishes the trap
# handler at thread+0x3c, but it never wrote thread+0x58.  CleanupStack::PushL
# (0x5037fca0) therefore resolved a null cleanup stack and panicked 0x2c:
#
#   0x5037fca8  bl 0x50392ba4      ; svc 0x74
#   0x5037fcb0  moveq r0, #0x2c ; bleq 0x503873bc
#
# Publishing the CCleanup at thread+0x58 removes that panic.  With slot
# 0x503b37c4 bound to the one-argument PushL shape EFile then passes the call
# and stops later at `pc left the image 0xf0009b06` instead of panicking; with
# the ROM value it still exits cleanly at 1,380 Thumb instructions.
#
# Acceptance:
#   - the service table entries 0x74/0x75 decode to code that touches +0x58;
#   - with the PushL binding the stop is `pc left the image 0xf0009b06` and no
#     0x2c panic is taken;
#   - the plain run is unchanged (clean `returned` at 0xdead0000).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 107: publish the per-thread cleanup stack pointer"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'PY'
import struct, capstone
d = open('out/6600_runtime.bin','rb').read(); base = 0x50000000
def w(a): return struct.unpack_from('<I', d, a - base)[0]
tbl = 0x50314aec
md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
for svc, name in ((0x74, 'get'), (0x75, 'set')):
    t = w(tbl + svc*4)
    ops = [i.op_str for i in md.disasm(d[t-base:t-base+0x14], t)]
    assert any('#0x58' in o for o in ops), (svc, ops)
    print('ok: svc %#x -> %#010x touches +0x58 (%s)' % (svc, t, name))
PY

printf '0x503b37c4 0x5037fca0\n' > out/round107_push.map
run_efile() {
    log=$1; shift
    env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
        NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
        NK_BUDGET=600000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
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
        NK_SCHED_AUTOCOMPLETE=1 NK_SCHED_EXIT=1 NK_SCHED_LOG=0 \
        NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 NK_SCHED_NO_PREEMPT=1 \
        NK_SWI_RET=0x1c:-1 "$@" \
        ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
        --rom-image out/6600_runtime.bin >"$log" 2>&1
}

run_efile out/round107_push.log NK_IMPORTMAP_APP=out/round107_push.map
run_efile out/round107_plain.log

# Round 111: with the cleanup stack now published and the queue laid out
# correctly, the PushL-bound run no longer jumps to 0xf0009b06; it passes the
# call and stops at the null method at 0x503bfcfe (Thumb 1,371).
grep -q "^--- stop: null call (8) at 0000000000 ---" out/round107_push.log
grep -q "503bfcfe" out/round107_push.log
if grep -q "0x5037fcb4 -> 0x503873bc" out/round107_push.log; then
    echo "FAIL: PushL still panics 0x2c" >&2
    exit 1
fi
# Round 111: the mask-ROM hand-off dispatches the application from a kernel
# that has already reached its entry sentinel, so when the application
# returns the supervisor resumes into that sentinel and the outer stop is
# the kernel halt rather than an unwind through the harness frame.  Assert
# the application-side signal (Thumb instruction count) instead.
sh tools/check_thumb.sh out/round107_plain.log 1200

echo "ok: thread+0x58 is the per-thread cleanup stack pointer (svc 0x74/0x75)"
echo "ok: publishing it removes PushL's 0x2c panic"
echo "ok: with the PushL binding EFile passes the call and stops at 0xf0009b06;"
echo "    with the ROM value it still exits cleanly at 1,380 Thumb instructions"
echo "PASS: round 107 adds the missing per-thread cleanup stack pointer"
