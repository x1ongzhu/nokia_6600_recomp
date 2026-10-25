#!/usr/bin/env python3
"""imports.py — the EKA1 ROM import/IAT map.

EKA1 ROM images do not carry an import directory.  Every import is a two
instruction stub in the *importing* image::

    ldr ip, [pc]        e59fc000
    ldr pc, [ip]        e59cf000
    .word <slot>        ; address of the exporting image's export slot

The ROM linker resolves an import by making the slot point at the exporting
image's ``.edata`` entry for the requested ordinal.  Because the packed stream
is the linked image, a slot that holds a code address is already bound in the
flat runtime image: nothing has to be copied at load time.  The only slots
that need loader work are the ones the exporting image does not implement
(``0xffffffff`` holes) or that are still zero.

This tool makes that contract visible and testable:

* enumerate every stub in every image;
* resolve its slot to ``(owner uid3, ordinal, current value)``;
* classify it as bound / missing export / null / outside the code map;
* report the exact remaining holes instead of stopping on a bare address.

Commands::

    py recompiler/imports.py scan   6600_mcu.bin
    py recompiler/imports.py scan   6600_mcu.bin --image 0x100058e8
    py recompiler/imports.py verify 6600_mcu.bin
    py recompiler/imports.py map    6600_mcu.bin --json
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import Counter

import pagestream
import romimage

ROM_BASE = romimage.ROM_BASE
UID_KERNEL = 0x100058E8


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def load_stream(path: str) -> bytes:
    with open(path, "rb") as f:
        return pagestream.build(f.read())


def real_images(stream: bytes) -> list[romimage.Image]:
    return [im for im in romimage.scan_images(stream)
            if 0x10000000 <= im.uid3 < 0x10200000]


def text_bytes(stream: bytes, im: romimage.Image) -> tuple[int, bytes]:
    sec = im.text
    return sec.va, stream[sec.file_off:sec.file_off + sec.size]


def find_stubs(stream: bytes, im: romimage.Image) -> list[dict]:
    """All `ldr ip,[pc]; ldr pc,[ip]` stubs in one image.

    The literal directly follows the second instruction for the compact form;
    `ldr ip,[pc,#imm]` with a positive immediate is accepted as well.  A
    candidate is kept only when its slot lands in the ROM image area, which
    rejects instruction pairs that merely look like stubs.
    """
    va, code = text_bytes(stream, im)
    out: list[dict] = []
    n = len(code) // 4
    for i in range(n - 2):
        w0 = u32(code, i * 4)
        w1 = u32(code, i * 4 + 4)
        if w1 != 0xE59CF000:                 # ldr pc, [ip]
            continue
        if (w0 & 0xFFFFF000) != 0xE59FC000:  # ldr ip, [pc, #imm]
            continue
        imm = w0 & 0xFFF
        lit_va = va + i * 4 + 8 + imm
        if lit_va + 4 > va + len(code):
            continue
        slot = u32(code, i * 4 + 8 + imm)
        if not (ROM_BASE <= slot < ROM_BASE + romimage.ROM_SIZE):
            continue
        out.append({"stub": va + i * 4, "slot": slot, "code_va": va})
    return out


def export_ref(images: list[romimage.Image], slot: int):
    """Map a slot address to (owner image, ordinal, stored export value)."""
    for im in images:
        ed = im.section("edata")
        if ed and ed.va <= slot < ed.va + ed.size:
            return im, (slot - ed.va) // 4
    return None, None


def code_ranges(images: list[romimage.Image]) -> list[tuple[int, int]]:
    return [(im.code, im.code + im.text_size) for im in images]


def in_code(ranges: list[tuple[int, int]], a: int) -> bool:
    a &= ~1
    return any(lo <= a < hi for lo, hi in ranges)


def classify(value, ranges: list[tuple[int, int]]) -> str:
    if value is None:
        return "unreadable"
    if value == 0:
        return "null"
    if value == 0xFFFFFFFF:
        return "missing"
    if in_code(ranges, value):
        return "bound"
    if ROM_BASE <= value < ROM_BASE + romimage.ROM_SIZE:
        return "not-code"
    return "outside"


def scan(stream: bytes, only: int | None = None) -> dict:
    images = real_images(stream)
    ranges = code_ranges(images)
    rows: list[dict] = []
    for im in images:
        if only is not None and im.uid3 != only:
            continue
        for st in find_stubs(stream, im):
            owner, ordinal = export_ref(images, st["slot"])
            # The packed stream is linked, so a VA maps through the owner's
            # sections.  Read the slot from whichever section contains it.
            value = read_va(stream, images, st["slot"])
            kind = classify(value, ranges)
            rows.append({
                "image": im.uid3,
                "code": im.code,
                "stub": st["stub"],
                "slot": st["slot"],
                "owner": owner.uid3 if owner else None,
                "ordinal": ordinal,
                "value": value,
                "kind": kind,
            })
    return {"images": images, "ranges": ranges, "rows": rows}


def read_va(stream: bytes, images: list[romimage.Image], va: int):
    for im in images:
        for s in im.sections:
            if s.va <= va < s.va + s.size:
                return u32(stream, s.file_off + (va - s.va))
    # Flat runtime addresses (0x5030xxxx) can also sit in the ROMFS block.
    # The packed stream keeps that block below the kernel; map it linearly
    # from the root list.
    hdr = romimage.find_rom_header(stream)
    root = romimage.find_romfs_root(stream, hdr["root_dir_list"])
    if root is not None and hdr["root_dir_list"] <= va < hdr["root_dir_list"] + 0x100000:
        off = root + (va - hdr["root_dir_list"])
        if 0 <= off + 4 <= len(stream):
            return u32(stream, off)
    return None


def summarize(res: dict) -> dict:
    rows = res["rows"]
    kinds = Counter(r["kind"] for r in rows)
    by_image = Counter(r["image"] for r in rows)
    owners = Counter((r["owner"], r["kind"]) for r in rows)
    return {"stubs": len(rows), "kinds": dict(kinds),
            "by_image": dict(by_image), "owners": dict(owners)}


def cmd_scan(a):
    stream = load_stream(a.rom)
    res = scan(stream, a.image)
    s = summarize(res)
    print(f"stubs: {s['stubs']}  " +
          "  ".join(f"{k}={v}" for k, v in sorted(s["kinds"].items())))
    for uid, n in sorted(s["by_image"].items()):
        print(f"  image {uid:#010x}: {n} stubs")
    print("slot owners:")
    for (owner, kind), n in sorted(s["owners"].items(),
                                   key=lambda kv: (-kv[1], str(kv[0]))):
        print(f"  {('none' if owner is None else f'{owner:#010x}'):>12} "
              f"{kind:8s} {n}")
    holes = [r for r in res["rows"] if r["kind"] != "bound"]
    if holes:
        print("unresolved slots:")
        for r in holes:
            owner = "none" if r["owner"] is None else f"{r['owner']:#010x}"
            print(f"  slot {r['slot']:#010x} (owner {owner} "
                  f"ord {r['ordinal']}) = {r['value']:#010x} [{r['kind']}] "
                  f"stub {r['stub']:#010x} in {r['image']:#010x}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump([{k: v for k, v in r.items()} for r in res["rows"]], f,
                      indent=1)


def cmd_verify(a):
    stream = load_stream(a.rom)
    res = scan(stream)
    rows = res["rows"]
    kernel = [r for r in rows if r["image"] == UID_KERNEL]
    euser = [r for r in kernel if r["owner"] == 0x100039E5]
    elocl = [r for r in kernel if r["owner"] == 0x100065A5]
    holes = [r for r in rows if r["kind"] != "bound"]
    print(f"kernel stubs: {len(kernel)} "
          f"({len(euser)} -> EUser, {len(elocl)} -> ELocl)")
    print(f"all stubs: {len(rows)}, unresolved: {len(holes)}")
    for r in holes:
        owner = "none" if r["owner"] is None else f"{r['owner']:#010x}"
        print(f"  missing: owner {owner} ordinal {r['ordinal']} "
              f"slot {r['slot']:#010x} = {r['value']} [{r['kind']}] "
              f"(stub {r['stub']:#010x})")
    ok = True
    if not kernel:
        print("FAIL: no kernel import stubs found")
        ok = False
    if not euser:
        print("FAIL: kernel has no EUser imports")
        ok = False
    # Round 19 invariant: the only unresolved kernel slot is ELocl ordinal 20,
    # which the 6600's ELocl.dll export table leaves as a 0xffffffff hole.
    k_holes = [r for r in kernel if r["kind"] != "bound"]
    if len(k_holes) != 1:
        print(f"FAIL: expected exactly 1 unresolved kernel slot, got {len(k_holes)}")
        ok = False
    else:
        h = k_holes[0]
        if not (h["owner"] == 0x100065A5 and h["ordinal"] == 20):
            print("FAIL: unresolved kernel slot is not ELocl ordinal 20")
            ok = False
        else:
            print("ok: the only unresolved kernel import is ELocl ordinal 20 "
                  "(export table hole)")
    if not ok:
        raise SystemExit(1)
    print("PASS: every other kernel import slot holds a code address")


def cmd_map(a):
    stream = load_stream(a.rom)
    res = scan(stream)
    if a.json:
        payload = [{k: v for k, v in r.items()} for r in res["rows"]]
        with open(a.json, "w") as f:
            json.dump(payload, f, indent=1)
        print(f"wrote {a.json}: {len(payload)} stubs")
    else:
        for r in res["rows"]:
            owner = "none" if r["owner"] is None else f"{r['owner']:#010x}"
            value = "unreadable" if r["value"] is None else f"{r['value']:#010x}"
            print(f"{r['image']:#010x} {r['stub']:#010x} -> "
                  f"{r['slot']:#010x} {owner}:{r['ordinal']} "
                  f"{value} {r['kind']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("scan", cmd_scan), ("verify", cmd_verify),
                     ("map", cmd_map)):
        p = sub.add_parser(name)
        p.add_argument("rom")
        p.add_argument("--image", type=lambda s: int(s, 0), default=None,
                       help="only this uid3")
        p.add_argument("--json", default=None)
        p.set_defaults(func=fn)
    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
