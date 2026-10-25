#!/bin/sh
# test_layout.sh — regression check for the packed-vs-linked layout audit.
#
# The export directory of every ROM image is a list of fixed-up function
# addresses.  It is the best available oracle for the layout question: after
# a correct unpack, every entry must land on a function start in the text.
#
# Round 16 correction: removing the 0xec-byte page headers (see
# recompiler/pagestream.py) makes the packed text *the* linked text.  The old
# round-9..15 "different function order" result was the page headers.
#
# This test pins the new facts:
#   - the kernel has 478 in-text, 4-aligned exports and 469 (98.1%) land on a
#     detected function start at shift 0;
#   - the big DLL 0x100039e5 scores 1757/1788 (98.3%);
#   - the small Thumb reference DLL is 5/5;
#   - 787/812 kernel literal pools are already 4-aligned; the residual plan is
#     only 26 inserts / 0x34 bytes (detector noise, not the old 0x58 drift);
#   - the drift control now reports the same near-complete chain at every
#     budget, because drift 0 is the linked layout;
#   - header-less blocks still include a dozen code fragments.
#
# Run tools/test_pagestream.sh and tools/test_romimage.sh as well.
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
CENSUS=out/layout_census.json
CENSUS_LOG=out/layout_census.log
POOLS_LOG=out/layout_pools.log
DRIFT=out/layout_drift.json
DRIFT_LOG=out/layout_drift.log
GAPS=out/layout_gaps.json
GAPS_LOG=out/layout_gaps.log
VERIFY_LOG=out/layout_verify.log

"$PY" recompiler/layout.py census "$ROM" --json "$CENSUS" >"$CENSUS_LOG"
"$PY" recompiler/layout.py pools "$ROM" >"$POOLS_LOG"
"$PY" recompiler/layout.py drift "$ROM" --null 12 --json "$DRIFT" >"$DRIFT_LOG"
"$PY" recompiler/layout.py gaps "$ROM" --json "$GAPS" >"$GAPS_LOG"
"$PY" recompiler/layout.py verify "$ROM" >"$VERIFY_LOG"

fail=0
check() {
    if grep -q "$1" "$2"; then
        echo "ok: $3"
    else
        echo "FAIL: $3"
        fail=1
    fi
}

check "layout verify: ok" "$VERIFY_LOG" "layout invariants hold"
check "kernel exports      : 478, all in text, all 4-aligned" "$VERIFY_LOG" \
    "kernel export table is a real in-text address list"
check "5/5 starts" "$VERIFY_LOG" "reference Thumb DLL export entries are starts"
check "4-aligned 787/812" "$POOLS_LOG" \
    "packed-stream kernel pools are mostly 4-aligned"
check "alignment plan      : 26 inserts, 0x34 bytes" "$POOLS_LOG" \
    "residual relayout is bounded (no 0x58-byte page drift)"
check "0x100058e8" "$CENSUS_LOG" "kernel export census present"
check "0x101f6e00" "$CENSUS_LOG" "reference DLL export census present"
check "code-like gaps:" "$GAPS_LOG" "header-less blocks include code fragments"

"$PY" - "$CENSUS" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["uid3"]: r for r in d["images"]}
k = rows.get("0x100058e8")
d2 = rows.get("0x100039e5")
small = rows.get("0x101f6e00")
if not k or not d2 or not small:
    print("FAIL: census is missing the kernel, DLL2 or the reference DLL")
    raise SystemExit(1)
for r, name, want in ((k, "kernel", 450), (d2, "DLL2", 1700)):
    if r["exports"] < 400 or r["start"] < want:
        print(f"FAIL: {name} exports on starts {r['start']}/{r['exports']}")
        raise SystemExit(1)
    if r["best"]["shift"] != 0:
        print(f"FAIL: {name} best shift is {r['best']['shift']:#x}, not 0")
        raise SystemExit(1)
    if not r["in_code_rate"] or r["in_code_rate"] < 0.99:
        print(f"FAIL: {name} in-code rate {r['in_code_rate']}")
        raise SystemExit(1)
if small["start"] != small["exports"]:
    print(f"FAIL: reference DLL {small['start']}/{small['exports']} starts")
    raise SystemExit(1)
print(f"ok: kernel {k['start']}/{k['exports']} starts, "
      f"DLL2 {d2['start']}/{d2['exports']}, reference DLL 5/5")
EOF

# The drift control is now a positive check: the page-header-free stream
# matches the export table at drift 0, so every budget reports ~the same chain
# and the chain is far above the random-address null.
"$PY" - "$DRIFT" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["max_drift"]: r for r in d["results"]}
r = rows.get(0x200)
if r is None:
    print("FAIL: drift JSON has no 0x200 budget row")
    raise SystemExit(1)
if r["chain"] < 450:
    print(f"FAIL: linked stream drift chain regressed (chain={r['chain']})")
    raise SystemExit(1)
if r["ratio"] is None or r["ratio"] <= 2.0:
    print(f"FAIL: drift chain is not above the null "
          f"(chain={r['chain']}, null={r['null_avg']:.1f}, ratio={r['ratio']:.2f})")
    raise SystemExit(1)
print(f"ok: drift chain {r['chain']}/{r['exports']} vs null "
      f"{r['null_avg']:.1f} ({r['ratio']:.2f}x); the stream is the linked text")
EOF

"$PY" - "$GAPS" <<'EOF' || fail=1
import json, sys
rows = json.load(open(sys.argv[1]))["gaps"]
code = [r for r in rows if r["kind"].startswith("code:")]
if len(code) < 10:
    print(f"FAIL: only {len(code)} code-like gaps classified (expected >=10)")
    raise SystemExit(1)
print(f"ok: {len(code)} code-like header-less blocks")
EOF

if [ "$fail" -ne 0 ]; then
    echo "--- $VERIFY_LOG ---"
    cat "$VERIFY_LOG"
    echo "--- $POOLS_LOG ---"
    cat "$POOLS_LOG"
    echo "--- $DRIFT_LOG ---"
    cat "$DRIFT_LOG"
    echo "--- $GAPS_LOG (head) ---"
    sed -n '1,20p' "$GAPS_LOG"
    echo "--- $CENSUS_LOG (head) ---"
    sed -n '1,16p' "$CENSUS_LOG"
    exit 1
fi
echo "layout audit test OK"
