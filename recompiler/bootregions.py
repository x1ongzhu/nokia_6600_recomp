#!/usr/bin/env python3
"""bootregions.py — model the mask-ROM boot-region (bank) table.

The UPP mask ROM hands the secondary boot loader a table in RAM (``r0``/``fp``
on entry to linked ``0x30c``).  The loader copies it to the super page and uses
it to translate between the **physical** and **linear** views of the boot
image.  Round 12 found the empty table at ``0xfffff400``; this module makes the
table an explicit, generated input instead of an unexplained hole.

Entry format, recovered from the consumers in the linked boot bank::

    +0x00  base        physical base address
    +0x04  size        size in bytes
    +0x08  attr        low 5 bits = bank type; 0x4000 = super-page bank
    +0x0c  linbase     linear base address

The table itself is ``u32 count`` followed (after a 4-byte pad) by ``count``
0x10-byte entries::

    +0x00  count
    +0x04  reserved (0)
    +0x08  entry[0]
    ...

Consumers in the linked bank:

* ``0x2a34(table, addr)`` — first bank whose ``[base, base+size)`` contains
  ``addr`` (used with address 0 for the boot bank).
* ``0x2a7c(table, mask)`` — first bank whose ``attr & mask`` is non-zero;
  mask ``0x4000`` selects the RAM bank, and the super page lives at
  ``base + size - 0x1000``.
* ``0x1a1c(table, key, addr, phys)`` — two-way translation.  The first pass
  maps a **linear** address through ``linbase`` (``base + addr - linbase``);
  the fallback pass walks physical banks (attr bit ``0x8``) and maps back.
* ``0x1958`` compacts the table into the list at the super page; type 2/4
  entries are expanded through a page mask in ``linbase``.
* ``0x1b34`` maps a byte offset to an address, but only through type 2 banks.
* ``0x21d0`` sets bit ``0x08000000`` on type 1 and 4 banks.

So the table is a ROM-bank map, not a list of ROMFS files.  ``build`` derives
it from the EKA1 ``TRomHeader`` (ROM base/size and kernel data base/limit) and
adds the 64 KiB boot bank at physical 0.  The RAM bank carries the ``0x4000``
flag, which places the copied table at ``kern_limit - 0x1000 + 0x400``.

Commands::

    py recompiler/bootregions.py build   6600_mcu.bin out/6600_bootregions.bin
    py recompiler/bootregions.py explain out/6600_bootregions.bin
    py recompiler/bootregions.py verify  6600_mcu.bin
"""
from __future__ import annotations

import argparse
import struct
import sys

BANK = 0x10000              # the mask-ROM secondary bank
ATTR_TYPE = 0x1F
ATTR_SUPERPAGE = 0x4000
# Types 2 and 4 are expanded through the page mask in `linbase` by 0x1958.
TYPE_EXPAND = (2, 4)


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def rom_header(rom: bytes) -> dict:
    """Decode the EKA1 TRomHeader fields the boot bank cares about."""
    return {
        "rom_base": u32(rom, 0x88),
        "rom_size": u32(rom, 0x8C),
        "root": u32(rom, 0x90),
        "kern_data": u32(rom, 0x94),
        "kern_limit": u32(rom, 0x98),
    }


def regions(rom: bytes) -> list[dict]:
    """The three banks the stand-in mask ROM installs."""
    h = rom_header(rom)
    return [
        {"name": "boot", "base": 0, "size": BANK,
         "attr": 0x1, "linbase": 0},
        {"name": "rom", "base": h["rom_base"], "size": h["rom_size"],
         "attr": 0x1, "linbase": h["rom_base"]},
        {"name": "ram", "base": h["kern_data"],
         "size": h["kern_limit"] - h["kern_data"],
         "attr": 0x1 | ATTR_SUPERPAGE, "linbase": h["kern_data"]},
    ]


def encode(rows: list[dict]) -> bytes:
    out = bytearray(struct.pack("<II", len(rows), 0))
    for r in rows:
        out += struct.pack("<4I", r["base"], r["size"], r["attr"], r["linbase"])
    return bytes(out)


def decode(buf: bytes) -> dict:
    n = u32(buf, 0)
    rows = []
    for i in range(n):
        o = 8 + 0x10 * i
        if o + 0x10 > len(buf):
            break
        base, size, attr, linbase = struct.unpack_from("<4I", buf, o)
        rows.append({"base": base, "size": size, "attr": attr,
                     "linbase": linbase})
    return {"count": n, "rows": rows}


def super_page(rows: list[dict]) -> int | None:
    for r in rows:
        if r["attr"] & ATTR_SUPERPAGE:
            return (r["base"] + r["size"] - 0x1000) & 0xFFFFFFFF
    return None


def lookup_linear(rows: list[dict], addr: int) -> int | None:
    """First-pass translation used by 0x1a1c."""
    for r in rows:
        if r["linbase"] <= addr < (r["linbase"] + r["size"]) & 0xFFFFFFFF:
            return (r["base"] + (addr - r["linbase"])) & 0xFFFFFFFF
    return None


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    rows = regions(rom)
    buf = encode(rows)
    with open(a.out, "wb") as f:
        f.write(buf)
    h = rom_header(rom)
    print(f"rom header: base {h['rom_base']:#x} size {h['rom_size']:#x} "
          f"kern {h['kern_data']:#x}..{h['kern_limit']:#x}")
    for r in rows:
        print(f"  {r['name']:>4}: phys {r['base']:#010x}+{r['size']:#09x} "
              f"lin {r['linbase']:#010x} attr {r['attr']:#06x}")
    sp = super_page(rows)
    print(f"wrote {a.out}: {len(buf)} bytes; super page {sp:#x}, "
          f"table copy at {sp + 0x400:#x}")
    print("install it with:")
    print(f"  NK_REGIONS={a.out}@0x80000000 NK_R11=0x80000000 ...")
    return 0


def cmd_explain(a):
    buf = open(a.path, "rb").read()
    t = decode(buf)
    print(f"count {t['count']}")
    for i, r in enumerate(t["rows"]):
        print(f"  [{i}] phys {r['base']:#010x}+{r['size']:#09x} "
              f"lin {r['linbase']:#010x} attr {r['attr']:#010x} "
              f"type {r['attr'] & ATTR_TYPE} "
              f"{'(super page)' if r['attr'] & ATTR_SUPERPAGE else ''}")
    return 0


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    h = rom_header(rom)
    rows = regions(rom)
    t = decode(encode(rows))
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("ok: " if cond else "FAIL: ") + msg)
        ok = ok and cond

    check(h["rom_base"] == 0x50000000, "ROM linear base is 0x50000000")
    check(h["rom_size"] == 0x1600000, "ROM size is 0x1600000")
    check(h["kern_data"] == 0x80000000, "kernel data starts at 0x80000000")
    check(h["kern_limit"] == 0x80300000, "kernel data ends at 0x80300000")
    check(t["count"] == 3, "three banks: boot, ROM, RAM")
    check(rows[0]["base"] == 0 and rows[0]["size"] == BANK,
          "boot bank is physical 0..0x10000")
    check(rows[1]["base"] == h["rom_base"] and rows[1]["size"] == h["rom_size"],
          "ROM bank mirrors TRomHeader")
    check(rows[2]["attr"] & ATTR_SUPERPAGE,
          "RAM bank carries the 0x4000 super-page flag")
    sp = super_page(rows)
    check(sp == 0x802FF000, f"super page is 0x802ff000 (got {sp:#x})")
    check(sp is not None and sp + 0x400 == 0x802FF400,
          "the copied table lands at 0x802ff400")
    check(lookup_linear(rows, 0x50001234) == 0x50001234,
          "the flash bank is identity-mapped at 0x50000000")
    check(lookup_linear(rows, 0x00001234) == 0x00001234,
          "the boot copy is mapped at physical 0")
    check(lookup_linear(rows, 0x80000100) == 0x80000100,
          "RAM is identity-mapped")
    # The KaeP vector address the loader asks for is *not* a linear ROM
    # address; it must be resolved through the payload after unpacking.
    check(lookup_linear(rows, 0xF018E59F) is None,
          "0xf018e59f is outside every bank (the KaeP payload frontier)")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    bd = sub.add_parser("build", help="write the boot-region table")
    bd.add_argument("rom", nargs="?", default="6600_mcu.bin")
    bd.add_argument("out", nargs="?", default="out/6600_bootregions.bin")
    bd.set_defaults(func=cmd_build)
    ex = sub.add_parser("explain", help="decode a table file")
    ex.add_argument("path", nargs="?", default="out/6600_bootregions.bin")
    ex.set_defaults(func=cmd_explain)
    vf = sub.add_parser("verify", help="assert the derived table invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
