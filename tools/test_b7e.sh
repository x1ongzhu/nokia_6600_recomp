#!/bin/sh
# test_b7e.sh — initial thread/process, RTC driver data and the next frontier.
#
# Round 20 installed a thread -> process -> CObjectIx graph and reached the
# second thread's stack underflow.  Round 21 keeps that graph but fixes the
# paths it exposed:
#
#   - the kernel's EUser imports were linked against a different EUser .def
#     revision; four slots resolve to a function with the wrong ABI and panic
#     during kernel init.  config/imports-b7e-6600.txt rebinds them explicitly
#     (AtC16, the 2-arg TPtr16 ctor, TBuf16(int), TDes16::Copy(buf,len));
#   - the CObjectIx element fetch must fill a real TDesC8 descriptor, not a
#     bare pointer, because At() then calls TDesC8::Ptr() on it;
#   - the RTC physical device driver (uid3 0x100000d8) carries its vtable and
#     strings in the header-less block after .text.  `romimage.py
#     --place-rodata` now places that block at code+text_size when it fits
#     before the next packed header, so the RTC vtable at 0x503413e8 is live;
#   - the RTC constructor allocates with User::AllocZ -> RHeap::Alloc
#     (0x5038e2ec), which needs a heap.  NK_ALLOC_HLE serves it from the
#     harness bump heap; the HAL map/channel call is a minimal stand-in.
#
# Result: the RTC driver constructor completes.  The next frontier is a real
# boot-services dependency: the kernel asks for a session/file server while
# loading Econs.dll (uid3 0x100039e7) and halts in the panic printer with
# KERN-NO-SESSION 22.  That is the ROMFS/file-server task (PN-3), not an
# import or layout problem.
#
# Round 22 update: this file is kept as the round-21 baseline.  The ECons
# request turned out to be the RTC driver's misbound operator new entering
# EUser's RTest console path; tools/test_rtc.sh pins the round-22 run
# (27,470 instructions, post-extension timer/DFC frontier).
#
# Acceptance:
#   - the flat image contains the RTC driver vtable at 0x503413e8;
#   - the kernel rebinds the four EUser slots and runs the whole init table;
#   - >8,000 instructions with 0 undefined, 0 call fixups, 0 recoveries and
#     0 unbound imports;
#   - the run stops in the panic printer (0x50312b88) with panic code 22
#     ("KERN-NO-SESSION") while loading Econs.dll.
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

echo "== ARM MUL/MLA regression"
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/interp_selftest.c runtime/src/nokia_rt.c \
    runtime/src/nokia_interp.c -o out/interp_selftest
./out/interp_selftest >out/test_b7e.interp.log 2>&1
grep -q "ARM MUL/MLA write bits 19-16 and leave r0 alone" \
    out/test_b7e.interp.log
echo "ok: ARM MUL/MLA writes bits 19-16 (r0 is no longer clobbered)"

echo "== flat image with the header-less driver rodata"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

"$PY" - <<'PY'
import struct
d = open("out/6600_runtime.bin", "rb").read()
def r32(a):
    return struct.unpack_from("<I", d, a - 0x50000000)[0]
assert r32(0x503413e8 + 0x18) == 0x5033ef98, hex(r32(0x503413e8 + 0x18))
assert 0x50000000 <= r32(0x503413e8 + 0x18) < 0x51600000
assert r32(0x5079d244) != 0   # Econs.dll text is placed
print("ok: RTC driver vtable 0x503413e8 is live; Econs.dll text is placed")
PY

echo "== B7e run: RTC driver -> Econs.dll session frontier"
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=8000000 \
NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 \
NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/b7e_boot.log 2>&1

grep -q "import map config/imports-b7e-6600.txt: 5 slot overrides" out/b7e_boot.log
grep -q "import rebind: 0x503b391c (uid 0x100039e5 ord 98)" out/b7e_boot.log
grep -q "import rebind: 0x503b4d1c (uid 0x100039e5 ord 1378)" out/b7e_boot.log
grep -q "import rebind: 0x503b4b9c (uid 0x100039e5 ord 1282)" out/b7e_boot.log
grep -q "import rebind: 0x503b3b70 (uid 0x100039e5 ord 247)" out/b7e_boot.log
grep -q "B7e: current thread 0x802ffd00 -> process 0x80003200" out/b7e_boot.log
grep -q "undefined=0" out/b7e_boot.log
grep -q "call fixups=0" out/b7e_boot.log
grep -q "unbound IAT=0" out/b7e_boot.log
grep -q "recoveries=0" out/b7e_boot.log
grep -q "^--- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/b7e_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/b7e_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 8000 ]; then
    echo "FAIL: B7e run only reached ${insns:-0} instructions" >&2
    tail -25 out/b7e_boot.log >&2
    exit 1
fi
echo "ok: rebinds + driver rodata + heap; $insns instructions"
echo "    (0 undefined, 0 call fixups, 0 unbound imports, 0 recoveries)"

echo "== panic identity: KERN-NO-SESSION 22"
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=8000000 \
NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 \
NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
NK_WATCH=0x50321c40 NK_WATCH_HITS=1 NK_WATCH_LOG=0 NK_WATCH_MEM=r0:0x10 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/b7e_panic.log 2>&1

grep -q "\[watch\] pc=0x50321c40 .*r1=0x16" out/b7e_panic.log
grep -q "\[watch\] mem r0 @0x50338230: 0000000f 0045004b 004e0052 004e002d" \
    out/b7e_panic.log
echo "ok: panic is category KERN-NO-SESSION, code 22 (Econs.dll load)"
echo "    round-21 baseline: the RTest/ECons request is a misbound RTC allocator"
echo "PASS: driver rodata + imports + heap; round-21 frontier preserved"
echo "      (round 22 advances to 27,470 instructions; see tools/test_rtc.sh)"
