#!/bin/sh
# test_pagestream.sh — acceptance test for the 0x20ec page-header removal.
#
# The 6600 flash stores the packed records as
#
#     0xec-byte page header + 0x2000-byte payload   (stride 0x20ec)
#
# Rounds 7-15 kept the page header inline (treating its first six bytes as a
# tag), which inserted 0xec bytes every 0x2000 bytes of every record.  This
# test pins the corrected view:
#
#   - the page-header-free stream is 0x1605ed8 bytes;
#   - the kernel header is at stream 0x31004c and its text at +0x64 (0x3100b0),
#     with the ARM entry word 0xe92d4070 at 0x50310054;
#   - the kernel exports land on function starts 469/478 (98.1%) and the big
#     DLL 0x100039e5 1757/1788 (98.3%) at shift 0;
#   - the linked boot bank is the stream slice [0xb0, 0x100b0), all switch
#     tables bias 0;
#   - the assembled flat image boots the real kernel entry (ARM) for >=900k
#     instructions with no undefined instruction and no call recovery.
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
IMG=out/6600_runtime_paged.bin
LOG=out/pagestream_test.log

echo "== page grid and packed-record stream"
"$PY" recompiler/pagestream.py verify "$ROM" | tee "$LOG"
"$PY" recompiler/pagestream.py analyze "$ROM" >out/pagestream_analyze.log
grep -q "kernel header 0x31004c  text 0x3100b0" out/pagestream_analyze.log
grep -q "entry word 0xe92d4070" out/pagestream_analyze.log

echo "== linked boot bank (page-header-free)"
"$PY" recompiler/bootbank.py verify "$ROM" --stream | tee -a "$LOG"
"$PY" recompiler/bootbank.py build "$ROM" out/6600_bootbank_stream.bin \
    --stream >out/pagestream_bank.log

echo "== export-table census"
"$PY" recompiler/layout.py verify "$ROM" | tee -a "$LOG"
"$PY" recompiler/layout.py census "$ROM" --json out/layout_census_paged.json \
    >out/layout_census_paged.log
"$PY" - <<'PY'
import json
rows = {r["uid3"]: r for r in json.load(open("out/layout_census_paged.json"))["images"]}
k = rows["0x100058e8"]
d2 = rows["0x100039e5"]
assert k["start"] >= 450, k
assert d2["start"] >= 1700, d2
assert k["best"]["shift"] == 0, k["best"]
assert d2["best"]["shift"] == 0, d2["best"]
print(f"ok: kernel {k['start']}/{k['exports']} starts "
      f"({100*k['start_rate']:.1f}%), DLL2 {d2['start']}/{d2['exports']} "
      f"({100*d2['start_rate']:.1f}%) at shift 0")
PY

echo "== flat runtime image"
"$PY" recompiler/romimage.py build "$ROM" "$IMG" \
    --json out/6600_runtime_paged_layout.json >out/pagestream_build.log
grep -q "sections from 725 images" out/pagestream_build.log
grep -q "kernel entry 0x50310054" out/pagestream_build.log
size=$(wc -c <"$IMG" | tr -d ' ')
[ "$size" = "23068672" ]

echo "== real kernel entry"
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel
NK_KERNEL_VECTORS=1 NK_BUDGET=1000000 NK_RECOVER=0 NK_CALL_INFER=0 \
NK_MMIO_N=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin --rom-image "$IMG" \
    >out/pagestream_boot.log 2>&1 || true

grep -q "entry 0x50310054 (ARM)" out/pagestream_boot.log
grep -q "kernel vectors: 0x64 bytes" out/pagestream_boot.log
grep -q "undefined=0" out/pagestream_boot.log
grep -q "recoveries=0" out/pagestream_boot.log
insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/pagestream_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 900000 ]; then
    echo "FAIL: only ${insns:-0} instructions (want >= 900000)" >&2
    tail -25 out/pagestream_boot.log >&2
    exit 1
fi
echo "ok: real kernel entry executed $insns instructions (0 undefined, 0 recoveries)"
grep -E "^(insns=|mmio:|last pcs)" out/pagestream_boot.log | tail -3

echo "PASS: page-header-free packed stream, 98% exports, real kernel boot"
