#!/bin/sh
# test_layout.sh — regression check for the packed-vs-linked layout audit.
#
# The export directory of every ROM image is a list of fixed-up function
# addresses.  It is therefore the best available oracle for the layout
# question: after a correct "unpack", every entry must land on a function
# start in the text.
#
# This test pins the facts the current boot work relies on:
#   - export entries are addresses (small reference DLL: all 5, Thumb bit set,
#     every one on a push prologue)
#   - the kernel has 478 in-text, 4-aligned entries
#   - the stored kernel text keeps 1420/1430 ARM prologues and 759/787 literal
#     pools 4-aligned, i.e. alignment padding can only explain ~0x58 of drift
#   - the kernel/DLL export tables nevertheless sit close to the base rate of
#     "random address looks like a function start", which is the B1g evidence
#     that the stored text is not the linked text
#   - the pool-aware detector (round 10) finds more leaf starts (104/478) and
#     raises the baseline in step (17.2%), so the ratio stays near 1.3x
#   - the strongest padding-only model (round 11: any stored start below the
#     export, non-decreasing drift) only matches the random-address null
#     (1.03-1.08x), so monotone drift/relayout is not the answer
#
# Run tools/test_romimage.sh as well: that one checks the assembled flat image.
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
check "4-aligned 759/787" "$POOLS_LOG" "kernel pools are mostly 4-aligned"
check "alignment plan      : 44 inserts, 0x58 bytes" "$POOLS_LOG" \
    "alignment-only drift is bounded"
check "0x100058e8" "$CENSUS_LOG" "kernel export census present"
check "0x101f6e00" "$CENSUS_LOG" "reference DLL export census present"
check "kernel scores at the null level" "$DRIFT_LOG" \
    "padding-only drift model is rejected"
check "code-like gaps:" "$GAPS_LOG" "header-less blocks include code fragments"

# The census must keep reporting a real split: the kernel export table does
# not describe the stored text, while the small Thumb DLL does.
"$PY" - "$CENSUS" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["uid3"]: r for r in d["images"]}
k = rows.get("0x100058e8")
small = rows.get("0x101f6e00")
if not k or not small:
    print("FAIL: census is missing the kernel or the reference DLL")
    raise SystemExit(1)
if k["exports"] != 478 or k["in_text"] != 478 or k.get("in_code") != 478:
    print(f"FAIL: kernel census {k['exports']} exports / {k['in_text']} in text / "
          f"{k.get('in_code')} in code")
    raise SystemExit(1)
if k["start_rate"] is None or k["base_rate"] is None:
    print("FAIL: kernel census has no start/base rate (text too small?)")
    raise SystemExit(1)
if k["start"] < 100 or k.get("after_pool", 0) < 10:
    print(f"FAIL: pool-aware detector regressed: start={k['start']} "
          f"after_pool={k.get('after_pool')}")
    raise SystemExit(1)
ratio = k["start_rate"] / k["base_rate"] if k["base_rate"] else 0
print(f"ok: kernel exports on stored starts {k['start']}/478 "
      f"({100*k['start_rate']:.1f}%, pool {k.get('after_pool', 0)}), "
      f"base {100*k['base_rate']:.1f}% ({ratio:.2f}x)")
if ratio > 2.0:
    print("FAIL: kernel export table unexpectedly matches the stored text; "
          "update B1g and this test")
    raise SystemExit(1)
if small["start"] != small["exports"]:
    print(f"FAIL: reference DLL {small['start']}/{small['exports']} starts")
    raise SystemExit(1)
print(f"ok: reference DLL {small['start']}/{small['exports']} starts")
EOF

# B1g2: even the strongest padding-only relayout (any stored start below an
# export, any non-decreasing drift up to the budget) must not beat the random
# null.  If it does, the "stored function order is not the linked order"
# conclusion is stale and this test should fail loudly.
"$PY" - "$DRIFT" <<'EOF' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["max_drift"]: r for r in d["results"]}
r = rows.get(0x200)
if r is None:
    print("FAIL: drift JSON has no 0x200 budget row")
    raise SystemExit(1)
if r["chain"] < 100:
    print(f"FAIL: drift matcher regressed (chain={r['chain']})")
    raise SystemExit(1)
if r["ratio"] is None or r["ratio"] >= 1.2:
    print(f"FAIL: padding-only drift now fits the kernel "
          f"(chain={r['chain']}, null={r['null_avg']:.1f}, "
          f"ratio={r['ratio']:.2f}); revisit B1g2")
    raise SystemExit(1)
print(f"ok: drift chain {r['chain']}/{r['exports']} vs null "
      f"{r['null_avg']:.1f} ({r['ratio']:.2f}x); padding cannot explain it")
EOF

# The header-less block is not always debug/rodata: some records carry a
# second Thumb/ARM fragment.  The kernel and the big boot DLL must stay
# rodata; if they flip to "code", the classifier or the record layout changed.
"$PY" - "$GAPS" <<'EOF' || fail=1
import json, sys
rows = json.load(open(sys.argv[1]))["gaps"]
code = [r for r in rows if r["kind"].startswith("code:")]
if len(code) < 10:
    print(f"FAIL: only {len(code)} code-like gaps classified (expected >=10)")
    raise SystemExit(1)
by_uid = {r["uid3"]: r for r in rows}
for uid in ("0x100058e8", "0x100039e5"):
    r = by_uid.get(uid)
    if r is None or r["kind"] != "rodata":
        print(f"FAIL: {uid} gap classified as {None if r is None else r['kind']}, "
              "expected rodata")
        raise SystemExit(1)
print(f"ok: {len(code)} code-like header-less blocks; kernel/DLL2 are rodata")
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
