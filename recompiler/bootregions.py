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
    +0x08  attr        low 5 bits = bank type; 0x4000 = super-page bank;
                       0x04000000 = linear translation (0x1a1c first pass);
                       0x08000000 = physical fallback (0x1a1c second pass)
    +0x0c  linbase     linear base address (also a page mask for expansion)

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
  only looks at banks whose type is **5..8** *and* whose attr byte at ``+0xb``
  has bit 2 set (attr bit ``0x04000000``).  A bank without that flag is
  invisible to the linear lookup even if its ``linbase``/``size`` cover the
  address.  The fallback pass walks banks with attr bit ``0x08000000`` and
  maps back through the key.
* ``0x1958`` compacts the table into the list at the super page; type 2/4
  entries are expanded through a page mask in ``linbase``.
* ``0x1b34`` maps a byte offset to an address, but only through type 2 banks.
* ``0x21d0`` sets bit ``0x08000000`` on type 1 and 4 banks.

So the table is a ROM-bank map, not a list of ROMFS files.  ``build`` derives
the *legacy* three-bank table from the EKA1 ``TRomHeader`` (ROM base/size and
kernel data base/limit) and adds the 64 KiB boot bank at physical 0.  That
table is enough for the super-page/list consumers (``0x2a34``/``0x2a7c``), but
it cannot satisfy ``0x1a1c`` or ``0x1b34``: their type/flag checks need the
``linear`` profile.  The two profiles are kept explicit because the legacy
table is what the earlier bring-up used.

The ``linear`` profile is the mask-ROM stand-in that moved the KaeP frontier:

* a type-2 RAM bank (offset mapping, super page, 6 MiB by default),
* a type-5 ROM bank with the linear flag (address translation),
* a type-5 boot bank with the linear flag (identity for 0..0x10000).

Its RAM bank is first so ``0x1b34(table, 0)`` maps offset 0 to RAM, not to the
boot bank; that is what the loader expects when it builds its heap/page tables.

Commands::

    py recompiler/bootregions.py build   6600_mcu.bin out/6600_bootregions.bin
    py recompiler/bootregions.py build   6600_mcu.bin \
        out/6600_bootregions_linear.bin --profile linear
    py recompiler/bootregions.py explain out/6600_bootregions_linear.bin
    py recompiler/bootregions.py verify  6600_mcu.bin
    py recompiler/bootregions.py verify  6600_mcu.bin --profile linear
"""
from __future__ import annotations

import argparse
import struct
import sys

BANK = 0x10000              # the mask-ROM secondary bank
ATTR_TYPE = 0x1F
ATTR_SUPERPAGE = 0x4000
ATTR_LINEAR = 0x04000000    # 0x1a1c first pass: [entry+0xb] bit 2
ATTR_PHYS = 0x08000000      # 0x1a1c second pass: [entry+0xb] bit 3
# Types 2 and 4 are expanded through the page mask in `linbase` by 0x1958.
TYPE_EXPAND = (2, 4)
TYPE_OFFSET = 2             # 0x1b34 offset -> address
TYPE_LINEAR = 5             # 0x1a1c first pass accepts types 5..8
DEFAULT_RAM_SIZE = 0x00600000   # physical RAM for the linear bring-up profile


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
    """The legacy three banks the stand-in mask ROM installs.

    These satisfy the super-page/list consumers but are invisible to the
    ``0x1a1c`` linear lookup, which additionally requires type 5..8 and
    ``ATTR_LINEAR``.
    """
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


def linear_regions(rom: bytes,
                   ram_size: int = DEFAULT_RAM_SIZE) -> list[dict]:
    """The linear-translation boot-region table used for KaeP bring-up.

    Order matters: ``0x1b34(table, 0)`` maps offset 0 through the first type-2
    bank, so RAM must come first.  ``0x1a1c`` ignores type 2 and uses the type-5
    ROM/boot entries, which is why one bank cannot serve both consumers.
    """
    h = rom_header(rom)
    return [
        {"name": "ram", "base": h["kern_data"], "size": ram_size,
         "attr": TYPE_OFFSET | ATTR_SUPERPAGE | ATTR_LINEAR,
         "linbase": h["kern_data"]},
        {"name": "rom", "base": h["rom_base"], "size": h["rom_size"],
         "attr": TYPE_LINEAR | ATTR_LINEAR, "linbase": h["rom_base"]},
        {"name": "boot", "base": 0, "size": BANK,
         "attr": TYPE_LINEAR | ATTR_LINEAR, "linbase": 0},
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
    """Simplified first-pass translation (legacy model, ignores flags)."""
    for r in rows:
        if r["linbase"] <= addr < (r["linbase"] + r["size"]) & 0xFFFFFFFF:
            return (r["base"] + (addr - r["linbase"])) & 0xFFFFFFFF
    return None


def linear_lookup(rows: list[dict], addr: int) -> int | None:
    """Model 0x1a1c's first pass exactly: type 5..8 + ATTR_LINEAR."""
    for r in rows:
        if (r["attr"] & ATTR_TYPE) not in range(TYPE_LINEAR, 9):
            continue
        if not (r["attr"] & ATTR_LINEAR):
            continue
        if r["linbase"] <= addr < (r["linbase"] + r["size"]) & 0xFFFFFFFF:
            return (r["base"] + (addr - r["linbase"])) & 0xFFFFFFFF
    return None


def offset_lookup(rows: list[dict], off: int) -> int | None:
    """Model 0x1b34: offset -> address through the first type-2 bank."""
    for r in rows:
        if (r["attr"] & ATTR_TYPE) == TYPE_OFFSET and off < r["size"]:
            return (r["base"] + off) & 0xFFFFFFFF
    return None


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    if a.profile == "linear":
        rows = linear_regions(rom, a.ram_size)
    else:
        rows = regions(rom)
    buf = encode(rows)
    with open(a.out, "wb") as f:
        f.write(buf)
    h = rom_header(rom)
    print(f"rom header: base {h['rom_base']:#x} size {h['rom_size']:#x} "
          f"kern {h['kern_data']:#x}..{h['kern_limit']:#x}")
    print(f"profile: {a.profile}"
          + (f" (RAM {a.ram_size:#x})" if a.profile == "linear" else ""))
    for r in rows:
        flags = []
        if r["attr"] & ATTR_LINEAR:
            flags.append("linear")
        if r["attr"] & ATTR_PHYS:
            flags.append("phys")
        if r["attr"] & ATTR_SUPERPAGE:
            flags.append("super")
        print(f"  {r['name']:>4}: phys {r['base']:#010x}+{r['size']:#09x} "
              f"lin {r['linbase']:#010x} attr {r['attr']:#010x} "
              f"type {r['attr'] & ATTR_TYPE} {' '.join(flags)}")
    sp = super_page(rows)
    print(f"wrote {a.out}: {len(buf)} bytes; super page {sp:#x}, "
          f"table copy at {sp + 0x400:#x}")
    print("install it with:")
    if a.profile == "linear":
        print("  NK_RAM_EXTRA=0x300000  # for the 6 MiB RAM bank")
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
    rows = linear_regions(rom, a.ram_size) if a.profile == "linear" \
        else regions(rom)
    t = decode(encode(rows))
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("ok: " if cond else "FAIL: ") + msg)
        ok = ok and cond

    if a.profile == "linear":
        check(h["rom_base"] == 0x50000000, "ROM linear base is 0x50000000")
        check(h["rom_size"] == 0x1600000, "ROM size is 0x1600000")
        check(h["kern_data"] == 0x80000000, "RAM starts at 0x80000000")
        check(t["count"] == 3, "three banks: RAM, ROM, boot")
        check((rows[0]["attr"] & ATTR_TYPE) == TYPE_OFFSET,
              "RAM bank is type 2 (0x1b34 offset mapping)")
        check(rows[0]["attr"] & ATTR_SUPERPAGE,
              "RAM bank carries the 0x4000 super-page flag")
        check((rows[1]["attr"] & ATTR_TYPE) == TYPE_LINEAR,
              "ROM bank is type 5 (0x1a1c linear mapping)")
        check((rows[2]["attr"] & ATTR_TYPE) == TYPE_LINEAR,
              "boot bank is type 5 (0x1a1c linear mapping)")
        for r in rows:
            check(r["attr"] & ATTR_LINEAR,
                  f"{r['name']} bank carries the 0x04000000 linear flag")
        check(offset_lookup(rows, 0) == 0x80000000,
              "offset 0 maps to RAM at 0x80000000")
        check(offset_lookup(rows, 0xB8000) == 0x800B8000,
              "offset 0xb8000 maps into RAM")
        check(linear_lookup(rows, 0x0000FD00) == 0x0000FD00,
              "the boot bank identity-maps 0xfd00")
        check(linear_lookup(rows, 0x5030FF9C) == 0x5030FF9C,
              "the ROM bank identity-maps the kernel header")
        check(linear_lookup(rows, 0xF018E59F) is None,
              "0xf018e59f is still outside every linear bank")
        sp = super_page(rows)
        check(sp == 0x805FF000,
              f"super page is 0x805ff000 with 6 MiB RAM (got {sp:#x})")
        return 0 if ok else 1

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
    check(linear_lookup(rows, 0x5030FF9C) is None,
          "the legacy attr=1 table is invisible to 0x1a1c "
          "(use --profile linear for the KaeP frontier)")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    bd = sub.add_parser("build", help="write the boot-region table")
    bd.add_argument("rom", nargs="?", default="6600_mcu.bin")
    bd.add_argument("out", nargs="?", default="out/6600_bootregions.bin")
    bd.add_argument("--profile", choices=("legacy", "linear"),
                    default="legacy",
                    help="legacy attr=1 table or the linear-capable bring-up "
                         "table (default: legacy)")
    bd.add_argument("--ram-size", type=lambda s: int(s, 0),
                    default=DEFAULT_RAM_SIZE,
                    help="RAM bank size for --profile linear (default 6 MiB)")
    bd.set_defaults(func=cmd_build)
    ex = sub.add_parser("explain", help="decode a table file")
    ex.add_argument("path", nargs="?", default="out/6600_bootregions.bin")
    ex.set_defaults(func=cmd_explain)
    vf = sub.add_parser("verify", help="assert the derived table invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.add_argument("--profile", choices=("legacy", "linear"),
                    default="legacy")
    vf.add_argument("--ram-size", type=lambda s: int(s, 0),
                    default=DEFAULT_RAM_SIZE)
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
