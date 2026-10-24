#!/usr/bin/env python3
"""bootbringup.py — explicit bring-up inputs for the secondary boot loader.

The real UPP mask ROM does three things this project cannot reconstruct yet:

1. it unpacks the ``KaeP`` boot image and installs a descriptor at linked
   ``0x80``;
2. it builds the boot-image node list the loader searches at ``0xc58``;
3. it gives the loader the RAM/ROM section banks.

The loader itself is real: after the round-15 fixes it passes the CPU/board
lookup, programs UPP registers and builds page tables.  What it does not have
is real KaeP data, so it eventually maps a 2 GiB section and burns the budget.

This module makes the missing inputs **explicit** instead of pretending the
packed payload is a descriptor:

* a synthetic KaeP descriptor at linked ``0x80`` (key, kernel entry/code/data,
  section sizes, list head),
* a two-level boot-image list at ``0xfd00``/``0xfd10`` whose node has
  ``next = 0`` and the type word ``0x05040000`` the ``0xc58`` search expects,
* the ``staging`` boot-region table from :mod:`bootregions`,
* a one-instruction skip of the KaeP compressed-image parser at ``0xfb8``
  (``mov pc, lr``).  The parser is real code; it cannot run because the packed
  stream is not a descriptor.  Skipping it lets the loader continue to its
  own section mapping and handoff.

None of these values are a reconstruction of the KaeP transform.  They are a
reproducible stand-in, exactly like ``kaep.py synth``, but now sufficient to
reach the **boot-image handoff at linked 0x80** with the kernel code/data
banks mapped.

The acceptance frontier is deterministic: the run stops at linked ``0x00000080``
(when ``NK_STOP_PC=0x80`` is used) with ``recoveries=1`` and no undefined
instruction.  The handoff target is the boot image the mask ROM would have
decompressed; the synthetic descriptor is not executable code, so the next
step is the real KaeP unpack, not a larger budget.

Commands::

    py recompiler/bootbringup.py build 6600_mcu.bin \
        out/6600_bootbank_bringup.bin --regions out/6600_bootregions_staging.bin
    py recompiler/bootbringup.py verify 6600_mcu.bin
"""
from __future__ import annotations

import argparse
import struct
import sys

import bootbank
import bootregions

BANK = 0x10000
DESCRIPTOR = 0x80
LIST_HEAD = 0xFD00
NODE = 0xFD10
PARSER = 0xFB8
PARSER_SKIP = 0xE1A0F00E       # mov pc, lr
NODE_TYPE = 0x05040000

# Descriptor fields consumed by the loader.  The offsets are relative to
# linked 0x80; the values come from the kernel TRomImageHeader and the flat
# runtime image.
DESCRIPTOR_FIELDS = {
    0x0C: 0x80000000,          # key / linear RAM base used by 0x1a1c
    0x14: bootregions.KERNEL_ENTRY,
    0x18: 0x80000000,          # data linear address
    0x1C: bootregions.KERNEL_CODE,
    0x20: LIST_HEAD,           # boot-image list head translated by 0xc58
    0x24: bootregions.KERNEL_DATA_SIZE,
    0x28: bootregions.KERNEL_BSS_SIZE,
    0x2C: 0,
    0x34: bootregions.KERNEL_CODE_SIZE,
    0x48: bootregions.KERNEL_DATA_SIZE + bootregions.KERNEL_BSS_SIZE,
    0x58: 0x80000000,
    0x64: bootregions.KERNEL_ENTRY,
}

# The node is what `0xc58` returns and `0xe6c` treats as a section
# descriptor: +0x2c/+0x34 are the code size, +0x5c is the list terminator,
# +0x60 is the type/version word.
NODE_FIELDS = {
    0x04: bootregions.KERNEL_HEADER,
    0x10: bootregions.KERNEL_ENTRY,
    0x14: bootregions.KERNEL_CODE,
    0x1C: bootregions.KERNEL_CODE,
    0x2C: 0,
    0x34: bootregions.KERNEL_CODE_SIZE,
    0x48: bootregions.KERNEL_DATA_SIZE + bootregions.KERNEL_BSS_SIZE,
    0x5C: 0,
    0x60: NODE_TYPE,
}


def build(rom: bytes, ram_size: int = bootregions.DEFAULT_RAM_SIZE):
    """Return (linked boot bank, staging region table bytes)."""
    bank = bytearray(bootbank.build(rom))
    if len(bank) != BANK:
        raise SystemExit(f"bootbank.build returned {len(bank)} bytes")

    for off, value in DESCRIPTOR_FIELDS.items():
        struct.pack_into("<I", bank, DESCRIPTOR + off, value)

    # Zero the list area first: an unset `next` pointer would send the 0xc58
    # search into executable code (the earlier synthetic node did exactly
    # that and returned 0).
    for off in range(0, 0x80, 4):
        struct.pack_into("<I", bank, LIST_HEAD + off, 0)
    struct.pack_into("<I", bank, LIST_HEAD + 4, NODE)
    for off, value in NODE_FIELDS.items():
        struct.pack_into("<I", bank, NODE + off, value)

    # Skip the KaeP compressed-image parser.  This is a documented bring-up
    # patch, not a claim about the real compressed stream.
    struct.pack_into("<I", bank, PARSER, PARSER_SKIP)

    table = bootregions.encode(bootregions.staging_regions(rom, ram_size))
    return bytes(bank), table


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    bank, table = build(rom, a.ram_size)
    with open(a.out, "wb") as f:
        f.write(bank)
    with open(a.regions, "wb") as f:
        f.write(table)
    print(f"wrote {a.out}: {len(bank):#x}-byte linked boot bank")
    print(f"wrote {a.regions}: {len(table)}-byte staging boot-region table")
    print("run the boot-image handoff:")
    print(f"  NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 "
          f"NK_LOW_ROM_IMAGE={a.out} \\")
    print(f"    NK_REGIONS={a.regions}@0x80000000 NK_ENTRY=0x30c \\")
    print("    NK_R11=0x80000000 NK_R10=0x80000000 NK_RECOVER=1 "
          "NK_CODE_ONLY=1 \\")
    print("    NK_BUDGET=1500000 NK_STOP_PC=0x80 "
          "./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin "
          "--rom-image out/6600_runtime.bin")
    return 0


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    bank, table = build(rom, a.ram_size)
    rows = bootregions.decode(table)
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("ok: " if cond else "FAIL: ") + msg)
        ok = ok and cond

    check(len(bank) == BANK, "linked boot bank is 64 KiB")
    check(rows["count"] == 4, "staging table has four banks")
    check(struct.unpack_from("<I", bank, PARSER)[0] == PARSER_SKIP,
          "KaeP parser at 0xfb8 is skipped by a bring-up `mov pc,lr`")
    check(struct.unpack_from("<I", bank, DESCRIPTOR + 0x20)[0] == LIST_HEAD,
          "descriptor points at the boot-image list head 0xfd00")
    check(struct.unpack_from("<I", bank, LIST_HEAD + 4)[0] == NODE,
          "list head points at node 0xfd10")
    check(struct.unpack_from("<I", bank, NODE + 0x5C)[0] == 0,
          "node next pointer is the list terminator")
    check(struct.unpack_from("<I", bank, NODE + 0x60)[0] == NODE_TYPE,
          "node type word is 0x05040000")
    check(struct.unpack_from("<I", bank, DESCRIPTOR + 0x1C)[0]
          == bootregions.KERNEL_CODE,
          "descriptor code address is 0x50310000")
    check(struct.unpack_from("<I", bank, DESCRIPTOR + 0x14)[0]
          == bootregions.KERNEL_ENTRY,
          "descriptor entry is 0x50310054")
    # The C fragment must be relocated or the CPU lookup at linked 0x3d10
    # compares 0x3b against instruction bytes and halts at 0x3d44.
    check(bank[0x74D8:0x74DA] == b"\x3b\x00",
          "fragment C installs the CPU table value 0x3b at linked 0x74d8")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    bd = sub.add_parser("build", help="write the bring-up bank and region table")
    bd.add_argument("rom", nargs="?", default="6600_mcu.bin")
    bd.add_argument("out", nargs="?", default="out/6600_bootbank_bringup.bin")
    bd.add_argument("--regions", default="out/6600_bootregions_staging.bin")
    bd.add_argument("--ram-size", type=lambda s: int(s, 0),
                    default=bootregions.DEFAULT_RAM_SIZE)
    bd.set_defaults(func=cmd_build)
    vf = sub.add_parser("verify", help="assert the bring-up stand-in invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.add_argument("--ram-size", type=lambda s: int(s, 0),
                    default=bootregions.DEFAULT_RAM_SIZE)
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
