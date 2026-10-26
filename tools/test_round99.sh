#!/bin/sh
# test_round99.sh - the handle lookup slot must keep the kernel-time variant.
#
# Round 98's frontier was "pc left the image at 0x3a".  The last PCs show
# CObjectIx::At (0x50380270) doing `ldr ip,[ip,#0x14]; bx ip` with ip=0x3a.
# The object index at 0x80600e98 is built by the kernel: constructor
# 0x50384d44 installs vtable 0x503b36f8, iCount=1 at +0x10, and leaves the
# entry array at +0x14 null until something is registered.
#
#   - the ROM's At (0x50380270, what slot 0x503b3948 holds in the image)
#     dereferences that null array and jumps to 0x3a;
#   - the kernel build's variant (0x5038e4b4, what config/imports-r29-6600.txt
#     installs) reads a count that is zero and returns 0 safely.
#
# So NK_IMPORTMAP_REVERT must not revert this one slot.
# NK_IMPORTMAP_NO_REVERT=<hex,...> lists slots that keep the kernel-time value.
#
# With 0x503b3948 excluded, 235 rebinds are reverted (not 236), the 0x3a crash
# is gone, and the app thread unwinds cleanly through its trap frame.  The
# remaining blocker is one bogus ReAlloc size: EUser's descriptor-grow path
# (0x5039c37c, called from 0x5039c400) asks for 0xb63a74 bytes while EFile
# builds its server name, which the round-94 cap rejects, so EFile leaves with
# KErrNoMemory.
#
# Acceptance:
#   - "importmap: reverted 235 kernel-time rebinds";
#   - no "pc left the image" at 0x3a;
#   - stop is "returned" at 0xdead0000;
#   - exactly one rejection, for 0xb63a78 bytes;
#   - Thumb instructions > 1200.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 99: keep the kernel handle-lookup variant for app threads"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 \
    NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=900000 NK_MMIO_N=8 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_TRAP_FRAME=1 NK_THREAD_HEAP=0x80700000 \
    NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
    NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
    NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
    NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
    NK_TIMER=1 NK_TIMER_LOG=0 NK_IMPORTMAP=config/imports-r29-6600.txt \
    NK_IMPORTMAP_REVERT=1 NK_IMPORTMAP_NO_REVERT=0x503b3948 \
    NK_CPSR=0x40000053 NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_SCHED=1 NK_SCHED_FAKE=1 NK_SCHED_ENTRY=0x503b7105 \
    NK_SCHED_STACK=0x80560000 NK_SCHED_STACK_EXTRA=0x600 \
    NK_SCHED_STACK_FILL=0xdead0000 NK_SCHED_AUTOCOMPLETE=1 \
    NK_SCHED_EXIT=1 NK_SCHED_LOG=8 NK_HANDOFF_ARM=1 NK_MEMCOPY_CLAMP=1 \
    NK_SCHED_NO_PREEMPT=1 NK_SWI_RET=0x1c:-1 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round99_keep.log 2>&1

grep -q "importmap: reverted 235 kernel-time rebinds for the app thread" out/round99_keep.log
if grep -q "pc left the image (5) at 0x0000003a ---" out/round99_keep.log; then
    echo "FAIL: the null object-index array is back" >&2
    exit 1
fi
grep -q "^--- stop: returned (2) at 0xdead0000 ---" out/round99_keep.log
test "$(grep -c 'HLE alloc rejected: 0xb63a78 bytes' out/round99_keep.log)" -eq 1
grep -q "r0=0x80700000 r1=0x80601b68 r2=0xb63a74" out/round99_keep.log
.venv/bin/python - <<'PY'
import re
line = [l for l in open('out/round99_keep.log') if l.startswith('insns=')][-1]
m = re.search(r'Thumb (\d+)\)', line)
assert m and int(m.group(1)) > 1200, line
print('ok: the app thread ran %s Thumb instructions' % m.group(1))
PY

echo "ok: the handle-lookup slot keeps the kernel-time variant (235 reverts,"
echo "    not 236), so CObjectIx::At no longer dereferences the null array"
echo "ok: the 0x3a crash is gone and the thread unwinds through its trap frame"
echo "ok: the remaining blocker is a bogus 0xb63a74-byte ReAlloc from EUser's"
echo "    descriptor-grow path while EFile builds its server name"
echo "PASS: round 99 keeps one kernel-time rebind for the object index"
