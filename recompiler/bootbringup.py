#!/usr/bin/env python3
"""bootbringup.py — explicit bring-up inputs for the secondary boot loader.

The real UPP mask ROM does three things this project cannot fully reconstruct:

1. it decodes the ``KaeP``/PeaK record and installs a boot descriptor at linked
   ``0x80``;
2. it builds the boot-image node list the loader searches at ``0xc58``;
3. it gives the loader the RAM/ROM section banks.

The loader itself is real: after the round-15 fixes it passes the CPU/board
lookup, programs UPP registers and builds page tables.  The container boundary
is now explicit (``kaep.unpack``), but the mask ROM's codec for the 0x20-byte
PeaK record is still opaque, so this module supplies the descriptor and an
executable handoff rather than pretending the record is plaintext.

This module makes the missing inputs **explicit** instead of pretending the
packed payload is a descriptor:

* a boot descriptor at linked ``0x80`` (key, kernel entry/code/data, section
  sizes, list head),
* an executable ARM handoff at the start of the descriptor
  (``ldr pc,[pc,#-4]; .word 0x50310054``), so the loader enters the real
  kernel instead of executing the opaque KaeP record bytes,
* a two-level boot-image list at ``0xfd00``/``0xfd10`` whose node has
  ``next = 0`` and the type word ``0x05040000`` the ``0xc58`` search expects,
* the ``staging`` boot-region table from :mod:`bootregions`.

This is a container-level stand-in: :func:`kaep.unpack` preserves the KaeP
record and image, while :func:`kaep.install` supplies the descriptor and the
executable handoff.  The mask ROM's transform of the 0x20-byte record is still
undocumented and is not claimed here.

The acceptance frontier is deterministic: with ``NK_STOP_PC=0x80`` the loader
stops at the handoff with ``recoveries=1`` and no undefined instruction.  With
the stop removed, the trampoline enters the kernel at ``0x50310054`` and runs
to the kernel stack/exception frontier instead of taking an SWI on the KaeP
record bytes.

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
import kaep

BANK = 0x10000
DESCRIPTOR = 0x80
LIST_HEAD = kaep.LIST_HEAD
NODE = kaep.NODE
NODE_TYPE = kaep.NODE_TYPE

# Kept as a compatibility alias for callers that imported the old tables.
DESCRIPTOR_FIELDS = kaep.descriptor_fields()
NODE_FIELDS = kaep.node_fields()


def build(rom: bytes, ram_size: int = bootregions.DEFAULT_RAM_SIZE):
    """Return (linked boot bank, staging region table bytes)."""
    bank = bootbank.build(rom)
    if len(bank) != BANK:
        raise SystemExit(f"bootbank.build returned {len(bank)} bytes")

    # The first two descriptor words are an ARM `ldr pc` trampoline to the
    # kernel entry.  The loader only checks +0/+4/+8 when its 0x40000000 flag
    # is set, so the handoff target is executable instead of a descriptor blob.
    bank = kaep.install(bank, rom)

    table = bootregions.encode(bootregions.staging_regions(rom, ram_size))
    return bank, table


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
    print("  remove NK_STOP_PC to execute the handoff and enter the kernel at "
          f"{bootregions.KERNEL_ENTRY:#x}")
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
    check(struct.unpack_from("<II", bank, DESCRIPTOR) ==
          (kaep.TRAMPOLINE_WORD, bootregions.KERNEL_ENTRY),
          "handoff at 0x80 is `ldr pc,[pc,#-4]; .word kernel entry`")
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
