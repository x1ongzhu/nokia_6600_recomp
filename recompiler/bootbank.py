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
  C*         ``0x6000-...``       ``0x6374-...``      ``0x374``
  =========  ===================  ===================  =======

  ``C`` is measured by its switch tables but its linked base is not yet pinned
  down; ``build`` only relocates A and B, the fragments the loader executes.

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

BANK = 0x10000                  # mask-ROM boot bank view
BASE_PROBE = 0x3B0              # `sub r1, pc, #imm; add r0, r0, r1; mov pc, lr`
LOADER_ENTRY = 0x3BC            # `mov r0, fp; sub r1, pc, #imm; ...; b loader`
LINKED_ENTRY = 0x30C            # LOADER_ENTRY - 0xB0

# Fragments whose stored->linked mapping is verified.  Each tuple is
# (linked_start, linked_end, stored_start, name, provisional).
MODULES = (
    (0x0000, 0x2000, 0x00B0, "A", False),
    (0x2000, 0x6000, 0x219C, "B", False),
)
# Measured but not relocated by `build`: the linked base is not pinned yet.
PROVISIONAL = (0x6000, 0x6374, "C")


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


def loader_entry(bank: bytes) -> dict:
    """Decode the hand-off at 0x3bc: `sub r1, pc, #imm` -> descriptor."""
    w = u32(bank, LOADER_ENTRY + 4)
    target = None
    if (w & 0x0FFF0000) == 0x024F0000 and (w & 0xF000) == 0x1000:
        target = (LOADER_ENTRY + 8 + 4 - _rot_imm(w & 0xFFF)) & 0xFFFFFFFF
    return {"entry": LOADER_ENTRY, "sub": w, "descriptor": target}


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
    for ls, le, ss, name, _ in MODULES:
        if ss <= off < ss + (le - ls):
            return ss - ls, ls, name
    return None


def analyze(rom: bytes) -> dict:
    bank = rom[:BANK]
    base = image_base(bank)
    entry = loader_entry(bank)
    tables = switch_tables(bank)
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
        "reloc_addend": base,
        "loader": entry,
        "tables": tables,
        "modules": [(ls, le, ss, nm, prov) for ls, le, ss, nm, prov in MODULES],
        "provisional": PROVISIONAL,
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
    for ls, le, ss, name, provisional in MODULES:
        if provisional:
            continue
        n = le - ls
        out[ls:le] = bank[ss:ss + n]
    return bytes(out)


def cmd_analyze(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom)
    print(f"# boot bank: first {BANK:#x} bytes of {a.rom}")
    print(f"reloc addend (0x3b0): {info['reloc_addend']:#x}")
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
    print("measured fragments (max table bias is a lower bound, ±0x20):")
    for ls, le, ss, name, prov in info["modules"]:
        print(f"  {name}: linked {ls:#06x}-{le:#06x} <- stored {ss:#06x} "
              f"(bias {ss - ls:#x})")
    m = info["measured"]
    a_bias = m.get("A")
    b_bias = m.get("B")
    print(f"  A bias: {('0x%x' % a_bias) if a_bias is not None else '?'}  "
          f"(anchor: 0x3b0 helper)")
    print(f"  B bias: {('0x%x' % b_bias) if b_bias is not None else '?'}")
    ls, ss, name = info["provisional"]
    print(f"  {name}: stored {ss:#06x} (provisional; linked base not pinned)")
    return 0


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    buf = build(rom)
    if len(buf) != BANK:
        print(f"internal error: built {len(buf)} bytes", file=sys.stderr)
        return 1
    with open(a.out, "wb") as f:
        f.write(buf)
    print(f"wrote {a.out}: {BANK:#x}-byte linked boot bank")
    for ls, le, ss, name, prov in MODULES:
        if not prov:
            print(f"  {name}: linked {ls:#06x}-{le:#06x} <- stored {ss:#06x}")
    print(f"map it at address 0 and start at linked {LINKED_ENTRY:#x}:")
    print(f"  NK_LOW_ROM=1 NK_LOW_ROM_IMAGE={a.out} NK_ENTRY={LINKED_ENTRY:#x} \\")
    print("    NK_R11=0x80000000 NK_R10=0x80000000 NK_RECOVER=1 NK_CODE_ONLY=1 \\")
    print("    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --rom-image out/6600_runtime.bin")
    return 0


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom)
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("ok: " if cond else "FAIL: ") + msg)
        ok = ok and cond

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
    an.set_defaults(func=cmd_analyze)
    bd = sub.add_parser("build", help="write the linked 64 KiB boot-bank view")
    bd.add_argument("rom", nargs="?", default="6600_mcu.bin")
    bd.add_argument("out", nargs="?", default="out/6600_bootbank_linked.bin")
    bd.set_defaults(func=cmd_build)
    vf = sub.add_parser("verify", help="assert the measured invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
