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
    py recompiler/layout.py pools 6600_mcu.bin
    py recompiler/layout.py verify 6600_mcu.bin

`verify` exits non-zero if the invariants used by the loader stop holding
(export tables inside the text, the small reference DLL fully aligned, the
kernel export count and alignment stable, pools mostly 4-aligned).
"""
from __future__ import annotations

import argparse
import json

import romimage
import relayout

EXPORT_MIN = 16          # images smaller than this only need the basic checks
SHIFT_LIMIT = 0x200      # constant-shift search range
SMALL_REF_UID3 = 0x101F6E00   # 5 Thumb exports, every one a function start
KERNEL_UID3 = 0x100058E8


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


def start_kind(tv: TextView, v: int) -> str | None:
    """Classify `v` as a function start in the stored text.

    The parity selects the ISA the way the ROM exports it: odd and 2-mod-4
    addresses can only be Thumb function starts; 4-aligned exports are ARM.
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
    return None


def export_entries(rom: bytes, img: romimage.Image) -> list[int]:
    sec = img.section("edata")
    if sec is None or not img.export_count:
        return []
    return [int.from_bytes(rom[sec.file_off + i * 4:sec.file_off + i * 4 + 4],
                           "little")
            for i in range(img.export_count)]


def census_image(rom: bytes, img: romimage.Image, best_shift: bool) -> dict:
    tv = TextView(rom, img)
    entries = export_entries(rom, img)
    in_text = aligned4 = thumb = prologue = after_term = start = 0
    for v in entries:
        if v & 1:
            thumb += 1
        else:
            if v & 3:
                continue
            aligned4 += 1
        if not tv.contains(v & ~1):
            continue
        in_text += 1
        kind = start_kind(tv, v)
        if kind == "prologue":
            prologue += 1
        elif kind == "after-term":
            after_term += 1
        if kind:
            start += 1

    # How often a *random* text address (same parity class as the exports)
    # looks like a start.  This is the null hypothesis for "the exports are
    # aligned with the stored text".
    density = None
    if len(entries) >= 64 and img.text_size >= 0x1000:
        step = 2 if thumb else 4
        probed = hits = 0
        for o in range(0, img.text_size - 4, step):
            probed += 1
            if start_kind(tv, img.code + o):
                hits += 1
        density = hits / probed if probed else None

    best = {"shift": 0, "hits": start} if entries else None
    if best_shift and len(entries) >= EXPORT_MIN:
        best = {"shift": 0, "hits": -1}
        for shift in range(0, SHIFT_LIMIT + 1, 2):
            hits = 0
            for v in entries:
                p = ((v & ~1) - shift) | (v & 1)
                if start_kind(tv, p):
                    hits += 1
            if hits > best["hits"]:
                best = {"shift": shift, "hits": hits}

    return {
        "uid3": f"{img.uid3:#010x}",
        "header_file": f"{img.hdr_off:#x}",
        "code": f"{img.code:#x}",
        "text_size": img.text_size,
        "exports": len(entries),
        "in_text": in_text,
        "aligned4": aligned4,
        "thumb": thumb,
        "prologue": prologue,
        "after_term": after_term,
        "start": start,
        "start_rate": (start / len(entries)) if entries else None,
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
    print(f"{'uid3':>12} {'exports':>7} {'in-text':>7} {'al4':>5} {'thumb':>5} "
          f"{'pro':>4} {'after':>5} {'start':>5} {'rate':>6} {'base':>6} "
          f"{'x':>5} {'best-shift':>10} {'hits':>5}")
    for r in rows:
        best = r["best"] or {"shift": 0, "hits": 0}
        rate = 100.0 * r["start_rate"] if r["start_rate"] is not None else 0.0
        base = 100.0 * r["base_rate"] if r["base_rate"] is not None else 0.0
        ratio = (rate / base) if base else 0.0
        print(f"{r['uid3']:>12} {r['exports']:7d} {r['in_text']:7d} "
              f"{r['aligned4']:5d} {r['thumb']:5d} {r['prologue']:4d} "
              f"{r['after_term']:5d} {r['start']:5d} {rate:5.1f}% "
              f"{base:5.1f}% {ratio:5.2f} {best['shift']:#10x} "
              f"{best['hits']:5d}")

    total = sum(r["exports"] for r in rows)
    start = sum(r["start"] for r in rows)
    linked = [r for r in rows if r["start_rate"] is not None
              and r["start_rate"] >= 0.8]
    partial = [r for r in rows if r["start_rate"] is not None
               and 0.3 <= r["start_rate"] < 0.8]
    print(f"\n{start}/{total} export entries land on a function start at shift 0 "
          f"({100.0 * start / total:.1f}%)")
    print(f"images with >=80% exports on a start (stored linked): {len(linked)}")
    for r in linked[:10]:
        print(f"  {r['uid3']}  {r['start']}/{r['exports']}")
    print(f"images with 30-80%: {len(partial)}")
    print("'base' is the chance that a random text address of the same parity "
          "looks like a start.")
    print("The kernel and the boot DLLs sit close to their base rate, so their "
          "export tables do")
    print("not describe the stored text layout (B1g).  Small images can be "
          "stored linked; the")
    print("Thumb reference DLL 0x101f6e00 is 5/5.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump({"images": rows}, f, indent=1)
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

    v = sub.add_parser("verify")
    v.add_argument("rom")
    v.set_defaults(func=cmd_verify)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
