#!/usr/bin/env python3
"""bootbank.py — reconstruct the linked view of the 6600 UPP boot bank.

The first 64 KiB of the flash image is the secondary boot bank the UPP mask
ROM runs.  It is **not** stored at its linked addresses: the bank is a
concatenation of code fragments that were linked for different bases, and the
absolute addresses inside it (jump tables, the loader's hand-off address) still
hold the *linked* values.  The packed bytes are contiguous but the pointers are
not, so executing the flash copy directly makes every absolute branch land in
the wrong fragment.

Round 11 hit this as "the loader snaps a stale call at ``0x50001664`` and then
loops at ``0x1248``".  The mapping is actually deterministic:

* ``0x3b0`` is ``sub r1, pc, #0x308; add r0, r0, r1; mov pc, lr``: it adds
  the **relocation addend 0xb0** to ``r0`` (``physical = linked + 0xb0``).
  The linked image therefore starts at stored offset ``0xb0``.  The same rule
  turns the loader's hard-coded hand-off ``0x1244`` into the real function at
  ``0x12f4`` and the first jump table's ``0x11a8`` into its case body at
  ``0x1258``.
* Later fragments were packed after other fragments, so their bias is larger.
  The compiler-generated ``ldrls pc, [pc, rN, lsl #2]`` tables measure it: a
  table's closest case body (just after the table) gives a lower bound on the
  bias, and all tables inside one fragment agree to within ``0x20``.  The bank
  has three such fragments:

  =========  ===================  ===================  =======
  fragment   linked range         stored range         bias
  =========  ===================  ===================  =======
  A          ``0x0000-0x2000``    ``0x00b0-0x20b0``   ``0xb0``
  B          ``0x2000-0x6000``    ``0x219c-0x619c``   ``0x19c``
  C          ``0x6000-0x8000``    ``0x6374-0x8374``   ``0x374``
  =========  ===================  ===================  =======

  ``C`` is pinned by the 16-bit CPU/board table at linked ``0x74b8``: the
  correct halfwords (including the CPU value ``0x3b``) are stored at file
  ``0x782c``, exactly ``linked + 0x374``.  ``build`` now relocates A, B and C;
  before that the CPU lookup compared ``0x3b`` with instruction bytes and
  halted in the ``b .`` panic at linked ``0x3d44``.

The reconstruction is the biggest single-step boot advance since the Thumb
decoder fix: the loader now runs 600,000 instructions on the real path with
**zero** stale calls (round 11 needed 9 recoveries and then looped at
``0x1248``), and reaches the image-loader thread at linked ``0x1244``.

Commands::

    py recompiler/bootbank.py analyze 6600_mcu.bin
    py recompiler/bootbank.py build   6600_mcu.bin out/6600_bootbank_linked.bin
    py recompiler/bootbank.py verify  6600_mcu.bin
"""
from __future__ import annotations

import argparse
import sys

import pagestream

BANK = 0x10000                  # mask-ROM boot bank view
BASE_PROBE = 0x3B0              # `sub r1, pc, #imm; add r0, r0, r1; mov pc, lr`
LOADER_ENTRY = 0x3BC            # `mov r0, fp; sub r1, pc, #imm; ...; b loader`
LINKED_ENTRY = 0x30C            # LOADER_ENTRY - 0xB0

# Fragments whose stored->linked mapping is verified.  Each tuple is
# (linked_start, linked_end, stored_start, name).
#
# Fragment C is pinned by the 16-bit CPU/board table consumed at linked
# 0x3d10: the table lives at linked 0x74b8, and the correct halfwords
# (0x0000, 0x002a, 0x0029, ..., 0x003b) are stored at file 0x782c.  That is
# exactly linked + 0x374, the bias measured from C's switch tables.  Before
# this relocation the loader compared the CPU value 0x3b against instruction
# bytes and halted in the `b .` panic at linked 0x3d44.
MODULES = (
    (0x0000, 0x2000, 0x00B0, "A"),
    (0x2000, 0x6000, 0x219C, "B"),
    (0x6000, 0x8000, 0x6374, "C"),
)
# The two inter-fragment gaps (0x20b0..0x219c and 0x619c..0x6374) still hold
# code linked for another base; they are not relocated yet.
GAPS = ((0x20B0, 0x219C), (0x619C, 0x6374))


def u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "little")


def _rot_imm(imm12: int) -> int:
    """Decode an ARM data-processing rotated immediate."""
    imm8 = imm12 & 0xFF
    rot = (imm12 >> 8) * 2
    return ((imm8 >> rot) | (imm8 << (32 - rot))) & 0xFFFFFFFF if rot else imm8


def image_base(bank: bytes) -> int | None:
    """`sub r1, pc, #imm` at 0x3b0 computes the linked->physical addend."""
    w = u32(bank, BASE_PROBE)
    if (w & 0x0FFF0000) != 0x024F0000:      # sub r1, pc, #imm
        return None
    if (w & 0xF000) != 0x1000:              # Rd must be r1
        return None
    return (BASE_PROBE + 8 - _rot_imm(w & 0xFFF)) & 0xFFFFFFFF


def loader_entry(bank: bytes, entry: int = LOADER_ENTRY) -> dict:
    """Decode the hand-off: `sub r1, pc, #imm` -> descriptor.

    In the raw pack the entry is stored at 0x3bc and the descriptor at 0x130;
    in the page-header-free linked view the entry is 0x30c and the descriptor
    is linked 0x80.
    """
    w = u32(bank, entry + 4)
    target = None
    if (w & 0x0FFF0000) == 0x024F0000 and (w & 0xF000) == 0x1000:
        target = (entry + 8 + 4 - _rot_imm(w & 0xFFF)) & 0xFFFFFFFF
    return {"entry": entry, "sub": w, "descriptor": target}


def switch_tables(bank: bytes) -> list[dict]:
    """Find `ldrls pc, [pc, rN, lsl #2]` tables and measure their bias.

    The instruction is followed by `b default` and then the table.  In these
    compiler-generated switches the closest case body starts immediately after
    the table, so `table_end - entry` is a lower bound on the fragment bias;
    tail-merged cases give smaller values.
    """
    rows: list[dict] = []
    for a in range(0, BANK - 4, 4):
        w = u32(bank, a)
        if (w & 0x0FFFF000) != 0x079FF000:   # ldr{cond} pc,[pc,rN,lsl#2]
            continue
        # The preceding `cmp rN, #n` (if any) gives the entry count.
        n = 9
        prev = u32(bank, a - 4)
        if (prev & 0x0FF0F000) == 0x03500000:
            n = _rot_imm(prev & 0xFFF) + 1
            if not 1 <= n <= 16:
                n = 9
        table = a + 8
        entries = []
        for i in range(n):
            v = u32(bank, table + 4 * i)
            if v >= BANK:
                break
            entries.append(v)
        if not entries:
            continue
        end = table + 4 * len(entries)
        biases = [end - v for v in entries if v <= end]
        if not biases:
            continue
        rows.append({
            "address": a, "table": table, "entries": len(entries),
            "end": end, "bias_max": max(biases), "bias_list": biases,
        })
    return rows


def module_for_stored(off: int) -> tuple[int, int, str] | None:
    """Return (drift, linked_base, name) for a stored offset, if mapped."""
    for ls, le, ss, name in MODULES:
        if ss <= off < ss + (le - ls):
            return ss - ls, ls, name
    return None


def analyze(rom: bytes, stream: bool = False) -> dict:
    if stream:
        bank = build_stream(rom)
        base = None
        entry = loader_entry(bank, LINKED_ENTRY)
    else:
        bank = rom[:BANK]
        base = image_base(bank)
        entry = loader_entry(bank)
    tables = switch_tables(bank)
    if stream:
        for row in tables:
            row["module"] = "-"
            row["expect"] = 0
    else:
        # Assign each table to the fragment whose stored range contains it.
        for row in tables:
            m = module_for_stored(row["address"])
            row["module"] = m[2] if m else None
            row["expect"] = m[0] if m else None
    by_module: dict[str, list[dict]] = {}
    for row in tables:
        by_module.setdefault(row["module"] or "-", []).append(row)
    summary = {}
    for name, rows in by_module.items():
        summary[name] = max(r["bias_max"] for r in rows)
    return {
        "stream": stream,
        "reloc_addend": base,
        "loader": entry,
        "tables": tables,
        "modules": ([] if stream else
                    [(ls, le, ss, nm) for ls, le, ss, nm in MODULES]),
        "measured": summary,
    }


def build(rom: bytes) -> bytes:
    """Return the 64 KiB linked view of the boot bank.

    Fragments with a verified mapping are moved to their linked addresses; the
    rest of the page keeps the stored bytes so that data (ROMFS/header blocks)
    is still present.  The caller maps the result at address 0.
    """
    bank = bytearray(rom[:BANK])
    out = bytearray(bank)
    for ls, le, ss, name in MODULES:
        n = le - ls
        out[ls:le] = bank[ss:ss + n]
    return bytes(out)


LINKED_ENTRY = 0x30C
STREAM_BASE = 0xB0              # linked 0 is at stream offset 0xb0


def build_stream(rom: bytes) -> bytes:
    """Return the linked boot bank from the page-header-free stream.

    The 0x20ec page headers are exactly what made the raw bank look
    fragmented.  After removing them the boot bank is the contiguous stream
    slice ``[0xb0, 0x100b0)``: linked 0 is stream 0xb0 and every switch table
    measures bias 0.  This supersedes the A/B/C relocation heuristics.
    """
    stream = pagestream.build(rom)
    if len(stream) < STREAM_BASE + BANK:
        raise SystemExit("packed stream is too short for a 64 KiB boot bank")
    return stream[STREAM_BASE:STREAM_BASE + BANK]


def cmd_analyze(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom, a.stream)
    if a.stream:
        print(f"# boot bank: linked stream view of {a.rom}")
    else:
        print(f"# boot bank: first {BANK:#x} bytes of {a.rom}")
    addend = info["reloc_addend"]
    print(f"reloc addend (0x3b0): "
          f"{('0x%x' % addend) if addend is not None else 'n/a (linked)'}")
    le = info["loader"]
    desc = le["descriptor"]
    print(f"loader entry      : {le['entry']:#x} (linked {LINKED_ENTRY:#x}), "
          f"descriptor {('0x%x' % desc) if desc is not None else '?'} (stored)")
    print()
    print(f"{'switch':>8} {'table':>8} {'n':>2} {'end':>8} "
          f"{'bias<=':>7} {'frag':>4} {'expect':>7}")
    for r in info["tables"]:
        exp = f"{r['expect']:#x}" if r["expect"] is not None else "-"
        print(f"{r['address']:#8x} {r['table']:#8x} {r['entries']:2d} "
              f"{r['end']:#8x} {r['bias_max']:#7x} {r['module'] or '-':>4} {exp:>7}")
    print()
    if a.stream:
        biases = sorted({r["bias_max"] for r in info["tables"]})
        print(f"linked stream view: {len(info['tables'])} switch tables, "
              f"bias {[hex(x) for x in biases]}")
        print("page headers removed -> linked 0 is stream 0xb0; no fragment "
              "relocation is needed")
    else:
        print("measured fragments (max table bias is a lower bound, ±0x20):")
        for ls, le, ss, name in info["modules"]:
            print(f"  {name}: linked {ls:#06x}-{le:#06x} <- stored {ss:#06x} "
                  f"(bias {ss - ls:#x})")
        m = info["measured"]
        a_bias = m.get("A")
        b_bias = m.get("B")
        print(f"  A bias: {('0x%x' % a_bias) if a_bias is not None else '?'}  "
              f"(anchor: 0x3b0 helper)")
        print(f"  B bias: {('0x%x' % b_bias) if b_bias is not None else '?'}")
        c_bias = m.get("C")
        print(f"  C bias: {('0x%x' % c_bias) if c_bias is not None else '?'}  "
              f"(anchor: CPU table 0x74b8 -> file 0x782c)")
    return 0


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    buf = build_stream(rom) if a.stream else build(rom)
    if len(buf) != BANK:
        print(f"internal error: built {len(buf)} bytes", file=sys.stderr)
        return 1
    with open(a.out, "wb") as f:
        f.write(buf)
    print(f"wrote {a.out}: {BANK:#x}-byte linked boot bank"
          f"{' (page-header-free stream)' if a.stream else ''}")
    if a.stream:
        print(f"  linked 0 is packed-stream 0x{STREAM_BASE:x}; switch table "
              f"bias is 0")
    else:
        for ls, le, ss, name in MODULES:
            print(f"  {name}: linked {ls:#06x}-{le:#06x} <- stored {ss:#06x}")
    entry = LINKED_ENTRY
    print(f"map it at address 0 and start at linked {entry:#x}:")
    print(f"  NK_LOW_ROM=1 NK_LOW_ROM_IMAGE={a.out} NK_ENTRY={entry:#x} \\")
    print("    NK_R11=0x80000000 NK_R10=0x80000000 NK_RECOVER=1 NK_CODE_ONLY=1 \\")
    print("    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --rom-image out/6600_runtime.bin")
    return 0


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom, a.stream)
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("ok: " if cond else "FAIL: ") + msg)
        ok = ok and cond

    if a.stream:
        built = build_stream(rom)
        check(len(built) == BANK, "stream boot bank is 64 KiB")
        desc = info["loader"]["descriptor"]
        check(desc == 0x80,
              f"linked loader hands off descriptor 0x80 (got {desc:#x})")
        biases = {r["bias_max"] for r in info["tables"]}
        check(biases == {0},
              f"all linked switch tables measure bias 0 (got {sorted(biases)})")
        check(built[0x74B8:0x74BA] == b"\x00\x00" and
              built[0x74D8:0x74DA] == b"\x3b\x00",
              "linked CPU/board table at 0x74b8 has the CPU value 0x3b")
        check(built[0x80:0xA0] ==
              b"\x00\xea\xf9\xdf" * 4 +
              b"\x00\xea\x00\x00\xa0\xe1\xf9\xdf\x00\xea\xf9\xdf\x00\xea"
              b"\x18\xf0",
              "linked 0x80 still holds the packed KaeP payload")
        return 0 if ok else 1

    check(info["reloc_addend"] == 0xB0,
          f"image base is 0xb0 (got {info['reloc_addend']})")
    desc = info["loader"]["descriptor"]
    check(desc == 0x130, f"loader hands off descriptor 0x130 (got {desc:#x})")
    a = info["measured"].get("A")
    b = info["measured"].get("B")
    check(a == 0xB0, f"fragment A switch bias measures 0xb0 (got {a})")
    check(b is not None and 0x180 <= b <= 0x1C0,
          f"fragment B switch bias measures ~0x19c (got {b})")
    n_b = sum(1 for r in info["tables"] if r["module"] == "B")
    check(n_b >= 8, f"fragment B has {n_b} measured switch tables")
    # Fragment C: the CPU/board table at linked 0x74b8.  The value 0x3b is
    # what 0x37a0 asks 0x3d10 for; a mis-relocated C makes the scan compare it
    # against ARM instruction bytes and halt in the 0x3d44 `b .`.
    stored_table = 0x782C
    linked_table = stored_table - 0x374
    check(linked_table == 0x74B8,
          f"C relocation maps stored 0x782c to linked 0x74b8 (got {linked_table:#x})")
    check(rom[stored_table:stored_table + 2] == b"\x00\x00" and
          rom[stored_table + 0x20:stored_table + 0x22] == b"\x3b\x00",
          "the C table at stored 0x782c contains the CPU value 0x3b")
    built = build(rom)
    check(built[0x74B8:0x74BA] == rom[stored_table:stored_table + 2],
          "the built linked view installs the C table at 0x74b8")
    # Every table inside A must agree with the anchor, and B within 0x20.
    for r in info["tables"]:
        if r["module"] == "A":
            check(r["bias_max"] == 0xB0, f"A table {r['address']:#x} bias {r['bias_max']:#x}")
        elif r["module"] == "B":
            check(abs(r["bias_max"] - 0x19C) <= 0x20,
                  f"B table {r['address']:#x} bias {r['bias_max']:#x}")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    an = sub.add_parser("analyze", help="measure the boot-bank fragments")
    an.add_argument("rom", nargs="?", default="6600_mcu.bin")
    an.add_argument("--stream", action="store_true",
                    help="analyze the page-header-free linked stream view")
    an.set_defaults(func=cmd_analyze)
    bd = sub.add_parser("build", help="write the linked 64 KiB boot-bank view")
    bd.add_argument("rom", nargs="?", default="6600_mcu.bin")
    bd.add_argument("out", nargs="?", default="out/6600_bootbank_linked.bin")
    bd.add_argument("--stream", action="store_true",
                    help="build from the page-header-free packed stream")
    bd.set_defaults(func=cmd_build)
    vf = sub.add_parser("verify", help="assert the measured invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.add_argument("--stream", action="store_true",
                    help="verify the page-header-free linked stream view")
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
