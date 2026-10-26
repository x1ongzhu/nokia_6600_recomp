#!/bin/sh
# test_round106.sh - static proof that the disputed call takes one argument.
#
# An intermediate version of this round claimed the opposite; it is withdrawn.
# Decoding the window with register-write information settles it:
#
#   503bfcd8  ldr r1, [pc, #0x114]   writes r1 (=0x80100c0c)  <- only for str
#   503bfcda  str r0, [r1]
#   503bfcdc  cmp r0, #0
#   503bfcde  bne 0x503bfce6
#   503bfce0  movs r0, #0x38
#   503bfce2  bl 0x503c3970          (leave 0x38)
#   503bfce6  ldr r0, [pc, #0x108]   writes r0
#   503bfce8  ldr r0, [r0]           writes r0
#   503bfcea  bl 0x503c5dcc          <- call 1
#   503bfcee  bl 0x503bdc5c
#   503bfcf2  adds r4, r0, #0
#   503bfcf4  bl 0x503c5dcc          <- call 2
#
# Nothing between 0x503bfce6 and 0x503bfcf4 writes r1 or r2, so the values seen
# at the call (r1=0x80100c0c, r2=9) are leftovers from the str sequence and from
# even earlier code.  Both call sites pass a single argument, which is what
# rounds 103/104 concluded: the ROM's entry 12 (0x503988a8, a three-argument
# heap grow) is not what this call site expects.
#
# Acceptance:
#   - the decoder shows r1 written only at 0x503bfcd8 and no r1/r2 write
#     between 0x503bfce6 and 0x503bfcf4;
#   - the search tool still reports the ROM values as the cleanest candidate.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out
echo "== round 106: static proof that the disputed call takes one argument"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'PY'
import capstone
d = open('out/6600_runtime.bin','rb').read(); base = 0x50000000
md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB); md.detail = True
writes = []
for i in md.disasm(d[0x503bfcd0-base:0x503bfcf8-base], 0x503bfcd0):
    wr = [i.reg_name(r) for r in i.regs_access()[1]]
    writes.append((i.address, wr))
r1_sites = [a for a, wr in writes if 'r1' in wr]
assert r1_sites == [0x503bfcd8], [hex(a) for a in r1_sites]
tail = [wr for a, wr in writes if 0x503bfce6 <= a <= 0x503bfcf4]
assert all('r1' not in wr and 'r2' not in wr for wr in tail), tail
print('ok: r1 is written only at 0x503bfcd8 (for the str) and never again')
print('ok: neither r1 nor r2 is written between 0x503bfce6 and 0x503bfcf4')
PY

sh tools/app_import_search.sh 12:3 12:4 > out/round106_search.log 2>&1
# Round 111: the baseline now leaves the application and resumes the
# supervisor into the kernel's entry sentinel (Thumb 1,267); both shifted
# candidates still end in a null call, so no shift improves on the ROM values.
grep -q "baseline          Thumb=1267  --- stop: self-branch (panic halt) (7) at 0x50312b88 ---" out/round106_search.log
grep -q "longer but crashes" out/round106_search.log

echo "ok: both slot-12 call sites pass one argument; the intermediate"
echo "    'three arguments' reading is withdrawn (r1/r2 are leftovers)"
echo "ok: per-slot shifting only turns the clean run into a crash"
echo "PASS: round 106 restores the one-argument finding with a static proof"
