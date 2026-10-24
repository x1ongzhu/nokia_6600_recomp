#!/usr/bin/env python3
"""layout.py — audit the packed image layout against the export tables.

The 6600 flash image stores each executable as a packed record
`[TRomImageHeader][.text][.rdata][.data][.edata][TDllRefTable]` whose *file*
offset has no fixed relation to its runtime address.  The export directory
(`TRomImageHeader.iExportDir`, a plain array of fixed-up function addresses,
indexed by ordinal) is the strongest available ground truth about the layout:
every entry must be the runtime address of an exported function.

This tool measures that agreement instead of assuming it.  It answers:

* how many entries are inside the image, 4-byte aligned, and carry the Thumb
  interworking bit (odd address);
* how many land on a function start in the *stored* text (ARM `push`/`stmdb`
  prologue, Thumb `push {lr}`, or directly after an ARM/Thumb terminator);
* the best single constant shift, if any.  A well-packed small image scores
  ~100% at shift 0; the kernel and the big DLLs do not, which is the B1g
  layout question, not a CPU/runtime bug.

The `pools` command audits literal-pool alignment: the ROM linker aligns a
pool to 4 bytes, so a packed pool at 2 mod 4 is direct evidence that the
stored text is not the linked text.

    py recompiler/layout.py census 6600_mcu.bin
    py recompiler/layout.py census 6600_mcu.bin --json out/layout_census.json
    py recompiler/layout.py drift  6600_mcu.bin --json out/layout_drift.json
    py recompiler/layout.py gaps   6600_mcu.bin --code-only
    py recompiler/layout.py pools  6600_mcu.bin
    py recompiler/layout.py verify 6600_mcu.bin

`drift` tests the strongest possible "the packed text is the linked text with
some 2-byte padding removed" model: an export may match any stored start at or
below it, with a non-decreasing cumulative drift.  Even that freedom only
matches the kernel exports at the same rate as random addresses (a null test),
so padding/relayout cannot recover the linked layout.

`gaps` classifies the header-less block between `.text` and `.data`.  It is
usually strings/pointer tables (the kernel and the big boot DLL), but a small
group of records stores a second Thumb/ARM code fragment there.

`verify` exits non-zero if the invariants used by the loader stop holding
(export tables inside the text, the small reference DLL fully aligned, the
kernel export count and alignment stable, pools mostly 4-aligned, and the drift
model still indistinguishable from the null).
"""
from __future__ import annotations

import argparse
import bisect
import json
import random
from array import array

import romimage
import relayout

EXPORT_MIN = 16          # images smaller than this only need the basic checks
SHIFT_LIMIT = 0x200      # constant-shift search range
SMALL_REF_UID3 = 0x101F6E00   # 5 Thumb exports, every one a function start
KERNEL_UID3 = 0x100058E8
DRIFT_LIMITS = (0x60, 0xC0, 0x200)   # cumulative-padding budgets to test
DRIFT_NULL_SAMPLES = 20


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _is_arm_prologue(w: int) -> bool:
    return ((w & 0xFFFF0000) == 0xE92D0000 or       # push {.., lr}
            (w & 0xFFFFF000) == 0xE24DD000 or       # sub sp, sp, #imm
            w == 0xE1A0C00D)                        # mov ip, sp


def _is_arm_terminator(w: int) -> bool:
    return ((w & 0xFFFF8000) == 0xE8BD8000 or       # ldm/pop {.., pc}
            w == 0xE12FFF1E or                      # bx lr
            w == 0xE1A0F00E or                      # mov pc, lr
            (w & 0x0F000000) == 0x0A000000)         # b


def _is_thumb_prologue(hw: int) -> bool:
    return (hw & 0xFF00) == 0xB500                  # push {r0-r7, lr}


def _is_thumb_terminator(hw: int) -> bool:
    return ((hw & 0xFF00) == 0xBD00 or              # pop {.., pc}
            hw == 0x4770)                           # bx lr


class TextView:
    """Bounds-checked word/halfword access to one image's stored text."""

    def __init__(self, rom: bytes, img: romimage.Image):
        self.img = img
        self.text = rom[img.text.file_off:img.text.file_end]
        self.code = img.code
        self.limit = img.code + len(self.text)

    def u32(self, va: int) -> int | None:
        o = va - self.code
        if 0 <= o <= len(self.text) - 4:
            return int.from_bytes(self.text[o:o + 4], "little")
        return None

    def u16(self, va: int) -> int | None:
        o = va - self.code
        if 0 <= o <= len(self.text) - 2:
            return int.from_bytes(self.text[o:o + 2], "little")
        return None

    def contains(self, va: int) -> bool:
        return self.code <= va < self.limit


def _literalish(v: int | None) -> bool:
    """True for words that can sit between a function and the next entry."""
    if v is None:
        return False
    return (v in (0, 0xFFFFFFFF) or v < 0x100000 or
            0x80000000 <= v < 0x80400000 or
            0x50000000 <= v < 0x51700000 or
            0x00040000 <= v < 0x00400000)


def start_kind(tv: TextView, v: int, pool_aware: bool = False) -> str | None:
    """Classify `v` as a function start in the stored text.

    The parity selects the ISA the way the ROM exports it: odd and 2-mod-4
    addresses can only be Thumb function starts; 4-aligned exports are ARM.

    `pool_aware` walks back through the literal pool that follows a function's
    terminator.  Leaf functions after a pool are real starts, but their
    immediately-preceding word is a literal, not a terminator; without this
    path the census silently undercounts them (the kernel export rate rises
    from 17.2% to 21.8%).
    """
    if not tv.contains(v & ~1):
        return None
    if v & 3:                                      # odd or 2 mod 4: Thumb
        base = v & ~1
        if _is_thumb_prologue(tv.u16(base) or 0):
            return "prologue"
        if _is_thumb_terminator(tv.u16(base - 2) or 0):
            return "after-term"
        return None
    w = tv.u32(v)
    if w is None:
        return None
    if _is_arm_prologue(w):
        return "prologue"
    if _is_arm_terminator(tv.u32(v - 4) or 0):
        return "after-term"
    if pool_aware:
        q = v - 4
        n = 0
        while q >= tv.code and n <= 0x60:
            w = tv.u32(q)
            if w is None:
                return None
            if _is_arm_terminator(w):
                return "after-pool" if n else "after-term"
            if not _literalish(w):
                return None
            q -= 4
            n += 4
    return None


def export_entries(rom: bytes, img: romimage.Image) -> list[int]:
    sec = img.section("edata")
    if sec is None or not img.export_count:
        return []
    return [int.from_bytes(rom[sec.file_off + i * 4:sec.file_off + i * 4 + 4],
                           "little")
            for i in range(img.export_count)]


def monotone_chain(entries: list[int], starts: list[int],
                   max_drift: int) -> tuple[int, int]:
    """Longest order-preserving matching of exports to stored starts.

    A pure cumulative-padding (or "drift") model of the packed text says the
    linked layout is the stored layout plus a non-decreasing number of inserted
    bytes: export `V` matches a stored start `c` with `V - c == P(c)`, the
    mapping is monotone in address order, and P never exceeds the total padding.

    This is the strongest possible version of that model: it does not require
    every export to match and it allows a different drift for every export.
    The returned length is therefore an *upper bound* on how many exports any
    padding-only relayout could explain.  The caller compares it with the same
    statistic on random addresses (the null hypothesis).
    """
    if not entries or not starts or max_drift <= 0:
        return 0, 0
    # 2-D prefix maximum over (drift, stored start).  Both axes are monotone:
    # a state can extend a later export only if the stored start and the drift
    # are both non-decreasing.  The Fenwick tree is over drift; each node is a
    # Fenwick tree over the start index.  Chain lengths fit in 16 bits.
    index = {c: i + 1 for i, c in enumerate(starts)}
    n_drift = max_drift // 2 + 2
    n_start = len(starts) + 1
    tree = [array("H", [0]) * (n_start + 1) for _ in range(n_drift + 1)]
    best = 0
    for v in entries:
        lo = bisect.bisect_left(starts, v - max_drift)
        hi = bisect.bisect_right(starts, v)
        updates: list[tuple[int, int, int]] = []
        for c in starts[lo:hi]:
            d = (v - c) // 2 + 1
            ci = index[c]
            # query prefix (drift <= d, stored start < c)
            q = 0
            i = d
            while i > 0:
                row = tree[i]
                j = ci - 1
                while j > 0:
                    if row[j] > q:
                        q = row[j]
                    j -= j & -j
                i -= i & -i
            ln = q + 1
            updates.append((d, ci, ln))
            if ln > best:
                best = ln
        # Insert only after the whole export is processed, so one export can
        # contribute at most one match to a chain.
        for d, ci, ln in updates:
            i = d
            while i <= n_drift:
                row = tree[i]
                j = ci
                while j <= n_start:
                    if ln > row[j]:
                        row[j] = ln
                    j += j & -j
                i += i & -i
    return best, max_drift


def drift_image(rom: bytes, img: romimage.Image, max_drift: int,
                null_samples: int, seed: int = 0x6600) -> dict:
    """Compare the best padding-only export matching against a random null."""
    tv = TextView(rom, img)
    entries = sorted(export_entries(rom, img))
    starts = [img.code + o for o in range(0, img.text_size - 4, 4)
              if start_kind(tv, img.code + o, pool_aware=True)]
    real, real_drift = monotone_chain(entries, starts, max_drift)

    rng = random.Random(seed)
    null: list[int] = []
    for _ in range(null_samples):
        fake = sorted(rng.randrange(img.code, img.code + img.text_size, 4)
                      for _ in entries)
        null.append(monotone_chain(fake, starts, max_drift)[0])
    null_avg = sum(null) / len(null) if null else 0.0
    return {
        "uid3": f"{img.uid3:#010x}",
        "exports": len(entries),
        "text_size": img.text_size,
        "max_drift": max_drift,
        "starts": len(starts),
        "chain": real,
        "chain_rate": (real / len(entries)) if entries else None,
        "budget": real_drift,
        "null_samples": null_samples,
        "null_avg": null_avg,
        "null_max": max(null, default=0),
        "ratio": (real / null_avg) if null_avg else None,
    }


def classify_gap(data: bytes) -> str:
    """Classify the header-less block between .text and .data.

    The packing note used to call this block "debug/rodata".  Some records
    actually carry a second *code* fragment there (Thumb or ARM).  Printable
    strings, a pointer table or a high ratio of plausible instructions are
    different signals; require a clean decode before calling it code.
    """
    if len(data) < 16:
        return "small"
    printable = sum(1 for b in data if 0x20 <= b < 0x7F or b == 0) / len(data)
    if printable > 0.70:
        return "rodata"
    words = [int.from_bytes(data[i:i + 4], "little")
             for i in range(0, len(data) - 3, 4)]
    ptr = sum(1 for w in words if 0x50000000 <= w < 0x51700000)
    if words and ptr > len(words) * 0.25:
        return "rodata"
    # Decode a short prefix in both instruction sets at both alignments.
    best = None
    try:
        from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB
    except ImportError:                      # tools remain usable without it
        return "data"
    for mode, name in ((CS_MODE_THUMB, "thumb"), (CS_MODE_ARM, "arm")):
        md = Cs(CS_ARCH_ARM, mode)
        for off in (0, 2):
            ins = list(md.disasm(data[off:off + 0x60], 0x1000 + off))
            if len(ins) < 10:
                continue
            bad = sum(1 for i in ins if "undefined" in i.mnemonic or
                      i.mnemonic == "udf")
            cf = sum(1 for i in ins if i.mnemonic in
                     ("bl", "blx", "bx", "b", "pop", "ldm", "mov") and
                     ("pc" in i.op_str or i.mnemonic in
                      ("bl", "blx", "bx", "b")))
            pro = sum(1 for i in ins if i.mnemonic in ("push", "stmdb", "sub")
                      or (i.mnemonic == "mov" and "ip" in i.op_str))
            score = len(ins) - 4 * bad + cf + 2 * pro
            if best is None or score > best[0]:
                best = (score, f"{name}{off}", bad, cf, len(ins))
    if best and best[2] == 0 and best[4] >= 10 and best[3] >= 2:
        return "code:" + best[1]
    return "data"


def gap_rows(rom: bytes, images: list[romimage.Image]) -> list[dict]:
    rows = []
    for im in images:
        if im.rodata is None or im.rodata.size < 16:
            continue
        data = rom[im.rodata.file_off:im.rodata.file_end]
        rows.append({
            "uid3": f"{im.uid3:#010x}",
            "code": f"{im.code:#x}",
            "text_size": im.text_size,
            "code_size": im.code_size,
            "gap_size": im.rodata.size,
            "gap_file": f"{im.rodata.file_off:#x}",
            "exports": im.export_count,
            "kind": classify_gap(data),
        })
    rows.sort(key=lambda r: -r["gap_size"])
    return rows


def cmd_gaps(a):
    rom, images = load_images(a.rom)
    rows = gap_rows(rom, images)
    code = [r for r in rows if r["kind"].startswith("code:")]
    print(f"# header-less blocks: {len(rows)} images with a gap >= 16 bytes")
    print(f"code-like gaps: {len(code)}  "
          f"(thumb {sum(1 for r in code if r['kind'].startswith('code:thumb'))}, "
          f"arm {sum(1 for r in code if r['kind'].startswith('code:arm'))})")
    print(f"{'size':>8} {'uid3':>12} {'kind':>12} {'exports':>7}  code")
    show = code if a.code_only else rows
    for r in show[:a.limit]:
        print(f"{r['gap_size']:8x} {r['uid3']:>12} {r['kind']:>12} "
              f"{r['exports']:7d}  {r['code']}")
    print("The kernel and the big boot DLL gaps are rodata (strings/pointer "
          "tables), but a small group of records really stores a second code "
          "fragment in this header-less block.  It is another way the packed "
          "record is not the linked image.")
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"gaps": rows}, f, indent=1)
        print(f"wrote {a.json}")


def census_image(rom: bytes, img: romimage.Image, best_shift: bool) -> dict:
    tv = TextView(rom, img)
    entries = export_entries(rom, img)
    in_text = aligned4 = thumb = prologue = after_term = after_pool = 0
    start = start_legacy = 0
    in_code = 0
    for v in entries:
        if img.code <= v < img.code + img.code_size:
            in_code += 1
        if v & 1:
            thumb += 1
        else:
            if v & 3:
                continue
            aligned4 += 1
        if not tv.contains(v & ~1):
            continue
        in_text += 1
        kind = start_kind(tv, v, pool_aware=True)
        if kind == "prologue":
            prologue += 1
        elif kind == "after-term":
            after_term += 1
        elif kind == "after-pool":
            after_pool += 1
        if kind:
            start += 1
        if start_kind(tv, v):
            start_legacy += 1

    # How often a *random* text address (same parity class as the exports)
    # looks like a start.  This is the null hypothesis for "the exports are
    # aligned with the stored text".  Use the same detector as `start`, or
    # the comparison would be biased in favour of the packed text.
    density = None
    if len(entries) >= 64 and img.text_size >= 0x1000:
        step = 2 if thumb else 4
        probed = hits = 0
        for o in range(0, img.text_size - 4, step):
            probed += 1
            if start_kind(tv, img.code + o, pool_aware=True):
                hits += 1
        density = hits / probed if probed else None

    best = {"shift": 0, "hits": start} if entries else None
    if best_shift and len(entries) >= EXPORT_MIN:
        best = {"shift": 0, "hits": -1}
        for shift in range(0, SHIFT_LIMIT + 1, 2):
            hits = 0
            for v in entries:
                p = ((v & ~1) - shift) | (v & 1)
                if start_kind(tv, p, pool_aware=True):
                    hits += 1
            if hits > best["hits"]:
                best = {"shift": shift, "hits": hits}

    return {
        "uid3": f"{img.uid3:#010x}",
        "header_file": f"{img.hdr_off:#x}",
        "code": f"{img.code:#x}",
        "text_size": img.text_size,
        "code_size": img.code_size,
        "exports": len(entries),
        "in_text": in_text,
        "in_code": in_code,
        "in_code_rate": (in_code / len(entries)) if entries else None,
        "aligned4": aligned4,
        "thumb": thumb,
        "prologue": prologue,
        "after_term": after_term,
        "after_pool": after_pool,
        "start": start,
        "start_legacy": start_legacy,
        "start_rate": (start / len(entries)) if entries else None,
        "start_rate_legacy": (start_legacy / len(entries)) if entries else None,
        "base_rate": density,
        "best": best,
    }


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def load_images(rom_path: str):
    rom = open(rom_path, "rb").read()
    return rom, romimage.plausible_images(romimage.scan_images(rom))


def cmd_census(a):
    rom, images = load_images(a.rom)
    rows = [census_image(rom, im, not a.no_shift) for im in images
            if im.export_count]
    rows.sort(key=lambda r: -r["exports"])

    print(f"# export-table census: {len(rows)} images with exports")
    print(f"{'uid3':>12} {'exports':>7} {'in-text':>7} {'in-code':>7} {'al4':>5} "
          f"{'thumb':>5} {'pro':>4} {'after':>5} {'pool':>5} {'start':>5} "
          f"{'rate':>6} {'legacy':>6} {'base':>6} {'x':>5} {'best-shift':>10} {'hits':>5}")
    for r in rows:
        best = r["best"] or {"shift": 0, "hits": 0}
        rate = 100.0 * r["start_rate"] if r["start_rate"] is not None else 0.0
        legacy = (100.0 * r["start_rate_legacy"]
                  if r["start_rate_legacy"] is not None else 0.0)
        base = 100.0 * r["base_rate"] if r["base_rate"] is not None else 0.0
        ratio = (rate / base) if base else 0.0
        code_rate = (100.0 * r["in_code_rate"]
                     if r["in_code_rate"] is not None else 0.0)
        print(f"{r['uid3']:>12} {r['exports']:7d} {r['in_text']:7d} "
              f"{code_rate:6.1f}% {r['aligned4']:5d} {r['thumb']:5d} "
              f"{r['prologue']:4d} {r['after_term']:5d} {r['after_pool']:5d} "
              f"{r['start']:5d} {rate:5.1f}% {legacy:5.1f}% {base:5.1f}% "
              f"{ratio:5.2f} {best['shift']:#10x} {best['hits']:5d}")

    total = sum(r["exports"] for r in rows)
    start = sum(r["start"] for r in rows)
    legacy = sum(r["start_legacy"] for r in rows)
    # Only images whose whole export array lies in their own code range can
    # say anything about the layout.  The half-in-code group is a separate
    # parser/format question (see the in-code% column) and would otherwise
    # dominate the "linked" counts with random data words.
    valid = [r for r in rows if (r["in_code_rate"] or 0.0) >= 0.99]
    linked = [r for r in valid if r["start_rate"] is not None
              and r["start_rate"] >= 0.8]
    partial = [r for r in valid if r["start_rate"] is not None
               and 0.3 <= r["start_rate"] < 0.8]
    print(f"\n{start}/{total} export entries land on a function start at shift 0 "
          f"({100.0 * start / total:.1f}%; legacy detector {legacy}/{total})")
    print(f"images with every export inside their code range: "
          f"{len(valid)}/{len(rows)}")
    print(f"images with >=80% exports on a start (stored linked): {len(linked)}")
    for r in linked[:10]:
        print(f"  {r['uid3']}  {r['start']}/{r['exports']}")
    print(f"images with 30-80%: {len(partial)}")
    print("'in-code%' is the fraction of export words inside the image's own "
          "code range; the kernel is 100%, so its low start rate is a real "
          "layout mismatch.")
    print("'start' walks back through a literal pool to the terminator, so leaf "
          "functions after a pool count.")
    print("'base' is the chance that a random text address of the same parity "
          "looks like a start (same detector).")
    print("The kernel and the boot DLLs sit close to their base rate, so their "
          "export tables do")
    print("not describe the stored text layout (B1g).  Small images can be "
          "stored linked; the")
    print("Thumb reference DLL 0x101f6e00 is 5/5.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump({"images": rows}, f, indent=1)
        print(f"wrote {a.json}")


def cmd_drift(a):
    rom, images = load_images(a.rom)
    by_uid: dict[int, romimage.Image] = {}
    for im in images:
        old = by_uid.get(im.uid3)
        if old is None or im.text_size > old.text_size:
            by_uid[im.uid3] = im
    img = by_uid.get(a.uid3)
    if img is None or not img.export_count:
        raise SystemExit(f"image {a.uid3:#x} with exports not found")

    print(f"# drift test: {img.uid3:#010x}, {img.export_count} exports, "
          f"text {img.text_size:#x} at {img.code:#x}")
    print(f"# a padding-only relayout may match an export V to any stored "
          f"start c <= V with a non-decreasing drift V-c")
    print(f"{'max-drift':>9} {'chain':>7} {'rate':>6} {'null-avg':>8} "
          f"{'null-max':>8} {'ratio':>6}")
    rows = []
    for limit in a.limits:
        row = drift_image(rom, img, limit, a.null, a.seed)
        rows.append(row)
        print(f"{limit:#9x} {row['chain']:7d} "
              f"{100.0 * (row['chain_rate'] or 0):5.1f}% "
              f"{row['null_avg']:8.1f} {row['null_max']:8d} "
              f"{row['ratio']:6.2f}")
    print("A real padding-only layout has a monotone drift and should score "
          "far above the random-address null.")
    print("The kernel scores at the null level, so the stored function order is "
          "not the linked order; padding/relayout cannot recover it.")
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"uid3": f"{img.uid3:#010x}", "results": rows}, f,
                      indent=1)
        print(f"wrote {a.json}")


def cmd_pools(a):
    rom = open(a.rom, "rb").read()
    im, text, funcs, groups, pools, plan, _, _ = relayout.build_plan(
        rom, a.uid3)
    aligned = sum(1 for p in pools if p % 4 == 0)
    dup = [(p1, p2) for p1, p2 in zip(pools, pools[1:]) if p2 - p1 <= 4]
    print(f"kernel {im.uid3:#010x}: text {len(text):#x} at {im.code:#x}")
    print(f"functions detected : {len(funcs)}")
    print(f"literal pools       : {len(pools)}  "
          f"4-aligned {aligned}/{len(pools)}  "
          f"2-mod-4 {len(pools) - aligned}")
    print(f"adjacent pool starts (<=4 bytes apart): {len(dup)}")
    for p1, p2 in dup:
        print(f"  {p1:#x} / {p2:#x}")
    print(f"alignment plan      : {len(plan.inserts)} inserts, "
          f"{plan.shift:#x} bytes")
    print("The packed text keeps 1420/1430 ARM prologues 4-aligned, so padding "
          "alone can account for at most ~0x58 bytes of address drift.")


def cmd_verify(a):
    rom, images = load_images(a.rom)
    by_uid: dict[int, romimage.Image] = {}
    for im in images:
        old = by_uid.get(im.uid3)
        if old is None or im.text_size > old.text_size:
            by_uid[im.uid3] = im
    failures: list[str] = []

    def check(cond: bool, msg: str):
        if not cond:
            failures.append(msg)

    # 1. the kernel export table is a real, fully in-text address list
    k = by_uid.get(KERNEL_UID3)
    check(k is not None, "kernel image (uid3 0x100058e8) not found")
    if k is not None:
        tv = TextView(rom, k)
        entries = export_entries(rom, k)
        check(len(entries) == 478,
              f"kernel export count {len(entries)}, expected 478")
        check(all(tv.contains(v) for v in entries),
              "kernel exports outside the kernel text")
        check(all(v % 4 == 0 for v in entries),
              "kernel exports not all 4-byte aligned")
        # B1g2: a padding-only relayout is a non-decreasing drift.  It must not
        # beat the random-address null, otherwise the B1g conclusion is stale.
        row = drift_image(rom, k, 0x200, 8)
        check(row["ratio"] is not None and row["ratio"] < 1.2,
              f"kernel drift chain {row['chain']} vs null "
              f"{row['null_avg']:.1f} (ratio {row['ratio']:.2f}); "
              "a padding-only model is now plausible, revisit B1g")

    # 2. a small Thumb DLL is the positive control: every export is a start
    small = by_uid.get(SMALL_REF_UID3)
    check(small is not None, f"reference DLL {SMALL_REF_UID3:#x} not found")
    if small is not None:
        tv = TextView(rom, small)
        entries = export_entries(rom, small)
        kinds = [start_kind(tv, v) for v in entries]
        check(len(entries) == 5, f"reference DLL has {len(entries)} exports, "
                                 "expected 5")
        check(all(kinds), f"reference DLL exports not all starts: {kinds}")
        check(all(v & 1 for v in entries),
              "reference DLL exports should all carry the Thumb bit")

    # 3. the kernel text is almost entirely 4-byte aligned
    if k is not None:
        _, _, _, _, pools, plan, _, _ = relayout.build_plan(rom, KERNEL_UID3)
        aligned = sum(1 for p in pools if p % 4 == 0)
        check(len(pools) >= 700, f"only {len(pools)} kernel pools detected")
        check(aligned >= 0.9 * len(pools),
              f"only {aligned}/{len(pools)} pools are 4-aligned")

    if failures:
        print("layout verify: FAIL")
        for f in failures:
            print(f"  - {f}")
        raise SystemExit(1)
    print("layout verify: ok")
    print(f"  images with exports : {sum(1 for im in images if im.export_count)}")
    print("  kernel exports      : 478, all in text, all 4-aligned")
    print(f"  reference Thumb DLL : {SMALL_REF_UID3:#010x}, 5/5 starts")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("census")
    c.add_argument("rom")
    c.add_argument("--json")
    c.add_argument("--no-shift", action="store_true",
                   help="skip the constant-shift search")
    c.set_defaults(func=cmd_census)

    p = sub.add_parser("pools")
    p.add_argument("rom")
    p.add_argument("--uid3", type=lambda s: int(s, 0),
                   default=KERNEL_UID3)
    p.set_defaults(func=cmd_pools)

    g = sub.add_parser("gaps")
    g.add_argument("rom")
    g.add_argument("--json")
    g.add_argument("--code-only", action="store_true")
    g.add_argument("--limit", type=int, default=40)
    g.set_defaults(func=cmd_gaps)

    d = sub.add_parser("drift")
    d.add_argument("rom")
    d.add_argument("--uid3", type=lambda s: int(s, 0),
                   default=KERNEL_UID3)
    d.add_argument("--json")
    d.add_argument("--null", type=int, default=DRIFT_NULL_SAMPLES,
                   help="random-address samples for the null hypothesis")
    d.add_argument("--seed", type=lambda s: int(s, 0), default=0x6600)
    d.add_argument("--limits", type=lambda s: [int(x, 0) for x in s.split(",")],
                   default=list(DRIFT_LIMITS),
                   help="comma-separated cumulative-padding budgets")
    d.set_defaults(func=cmd_drift)

    v = sub.add_parser("verify")
    v.add_argument("rom")
    v.set_defaults(func=cmd_verify)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
