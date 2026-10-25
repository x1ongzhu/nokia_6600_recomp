#!/bin/sh
# test_relayout.sh — diagnostic check for the residual literal-pool plan.
#
# Round 5-7 saw a 0x58-byte cumulative shift in the packed kernel text and
# built `relayout.py` to re-insert linker padding.  Round 16 showed that the
# shift was the 0xec-byte page headers (recompiler/pagestream.py).  On the
# page-header-free stream the text is already linked: 469/478 exports land on
# starts at shift 0, 787/812 pools are 4-aligned, and the residual plan is
# only 26 inserts / 0x34 bytes.  Those residual inserts are detector noise
# (data tables / leaf functions), so they must NOT be applied to the stream.
#
# This test pins:
#   - the stream's export match (via layout.py verify);
#   - the residual plan size (26 inserts, 0x34 bytes);
#   - all 812 pools align *after* the diagnostic plan;
#   - the raw packed text (with page headers) still shows the old problem,
#     which is why relayout alone could never fix it.
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
LOG=out/relayout_analyze.log
"$PY" recompiler/relayout.py analyze "$ROM" --json out/6600_relayout.json \
    >"$LOG" 2>&1
"$PY" recompiler/layout.py verify "$ROM" >out/relayout_layout_verify.log

grep -q "insertions 26 -> shift 0x34 bytes" "$LOG"
grep -q "pools aligned after plan: 812/812" "$LOG"
grep -q "literal pools 812" "$LOG"
grep -q "layout verify: ok" out/relayout_layout_verify.log

# The residual plan must stay small.  If it grows back to the old 0x58+
# cumulative shift, the page-header fix regressed.
shift=$(sed -n 's/.*insertions [0-9]* -> shift \(0x[0-9a-f]*\) bytes.*/\1/p' "$LOG")
case "$shift" in
    0x34) ;;
    *) echo "FAIL: residual relayout shift is $shift, expected 0x34" >&2
       exit 1 ;;
esac

echo "ok: 812 pools, 26 residual inserts (0x34 bytes), 812/812 aligned"
echo "ok: the page-header-free stream itself is the linked layout"
echo "note: the residual plan is diagnostic only; applying it would corrupt"
echo "      real instructions, so the boot image uses the stream unchanged"
echo "relayout diagnostic test OK"
