#!/usr/bin/env python3
"""kaep.py — measure the KaeP block and the paged boot image.

The first 7 MiB of the 6600 flash image are not a plain byte stream.  From
file ``0x20b0`` on, a six-byte *page tag* is inserted every ``0x20ec`` bytes::

    20 00 00 00 dc 23

The first real tag is at ``0x20b0`` and the last at ``0x6d9134``: **852**
tags.  The kernel text starts on a tag (file ``0x326924`` = runtime
``0x50310000``), which is why its entry at ``0x50310054`` is valid while code
after the first text page is shifted by six bytes per tag.  The tag semantics
are not documented; this module makes the structure measurable instead of
guessing.

The ``KaeP`` header sits just before the paged region::

    +0x00  "KaeP"
    +0x04  u32 size   (0x20)
    +0x08  u32 value  (0x1423dc, inside the paged region)

The bytes at ``0x128`` (``20 00 00 00 dc 23``) look like a page tag but are
the size field plus the low half of the value; they are **not** a page tag.
The mask ROM normally turns that block into the boot-image list the secondary
loader consumes.  ``synth`` is an explicit **bring-up stand-in**: it writes a
synthetic descriptor/list node into a linked boot-bank view so the loader gets
past the KaeP lookup.  It is not a reconstruction of the real KaeP transform.

Commands::

    py recompiler/kaep.py analyze 6600_mcu.bin
    py recompiler/kaep.py despan  6600_mcu.bin out/6600_despanned.bin
    py recompiler/kaep.py synth   out/6600_bootbank_linked.bin \
                                  out/6600_bootbank_kaep.bin
    py recompiler/kaep.py verify  6600_mcu.bin
"""
from __future__ import annotations

import argparse
import bisect
import json
import struct
import sys

KAE_P_MAGIC = b"KaeP"
PAGE_TAG = bytes.fromhex("20000000dc23")
PAGE_STRIDE = 0x20EC
KAE_P_OFF = 0x124
FIRST_TAG = 0x20B0
SPAN_END = 0x6D9134
TAG_LEN = len(PAGE_TAG)
RAM_BASE = 0x80000000
KERNEL_TEXT = 0x326924
KERNEL_ENTRY = 0x50310054

# The synthetic descriptor fields used by `synth`.  They are deliberately
# explicit: the loader reads +0x0c (heap/key), +0x14 (entry), +0x1c (code),
# +0x20 (boot-image list head), +0x58 and +0x64 (image metadata).
SYNTH_DESCRIPTOR = {
    0x0C: 0x80000000,
    0x14: KERNEL_ENTRY,
    0x1C: 0x50310000,
    0x20: 0x0000FD00,
    0x34: 0x00029238,
    0x58: 0x80000000,
    0x64: KERNEL_ENTRY,
}
SYNTH_NODE = {
    0x04: 0x5030FF9C,      # linear address of the kernel TRomImageHeader
    0x10: KERNEL_ENTRY,
    0x14: 0x50310000,
    0x34: 0x00029238,
    0x5C: 0,
    0x60: 0x05040000,
}


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def tags(rom: bytes) -> list[int]:
    """All page tags, in file order."""
    out: list[int] = []
    i = 0
    while True:
        j = rom.find(PAGE_TAG, i)
        if j < 0:
            return out
        out.append(j)
        i = j + 1


def span_tags(rom: bytes) -> list[int]:
    """Tags that belong to the paged span (FIRST_TAG..SPAN_END)."""
    return [t for t in tags(rom) if FIRST_TAG <= t <= SPAN_END]


def analyze(rom: bytes) -> dict:
    all_tags = tags(rom)
    span = span_tags(rom)
    if len(rom) < KAE_P_OFF + 12:
        raise SystemExit("image is too small for a KaeP header")
    magic = rom[KAE_P_OFF:KAE_P_OFF + 4]
    size = u32(rom, KAE_P_OFF + 4)
    value = u32(rom, KAE_P_OFF + 8)
    # Expected grid: 0x20b0, 0x419c, 0x6288, ...
    grid = list(range(FIRST_TAG, SPAN_END + 1, PAGE_STRIDE))
    gaps = [b - a for a, b in zip(span, span[1:])]
    entry_file = KERNEL_TEXT + (KERNEL_ENTRY - 0x50310000)
    entry_bytes = rom[entry_file:entry_file + 4]
    return {
        "kaep": {
            "file_offset": KAE_P_OFF,
            "magic": magic.decode("latin-1"),
            "size": size,
            "value": value,
            "value_in_span": FIRST_TAG <= value < SPAN_END,
        },
        "tags": {
            "all": len(all_tags),
            "span": len(span),
            "first": span[0] if span else None,
            "last": span[-1] if span else None,
            "stride": PAGE_STRIDE,
            "grid_matches": span == grid,
            "regular_gaps": sorted(set(gaps)) if gaps else gaps,
            "count_expected": len(grid),
            "kaep_size_low_half_looks_like_tag": (
                rom[KAE_P_OFF + 4:KAE_P_OFF + 10] == PAGE_TAG),
        },
        "kernel": {
            "text_file": KERNEL_TEXT,
            "text_on_tag": rom[KERNEL_TEXT:KERNEL_TEXT + TAG_LEN] == PAGE_TAG,
            "entry_file": entry_file,
            "entry_bytes": entry_bytes.hex(),
            "entry_is_nop_push": entry_bytes[:4] == bytes.fromhex("000090b5"),
            "tag_index_at_text": bisect.bisect_left(span, KERNEL_TEXT),
        },
        "span_bytes": (span[-1] - span[0]) if span else 0,
        "tag_bytes": TAG_LEN * len(span),
    }


def despan(rom: bytes, skip: int = TAG_LEN) -> bytes:
    """Remove the page tags from the paged span (experimental view)."""
    span = span_tags(rom)
    out = bytearray()
    pos = 0
    for t in span:
        if t < pos:
            continue
        out += rom[pos:t]
        pos = t + skip
    out += rom[pos:]
    return bytes(out)


def synth(bank: bytes) -> bytes:
    """Patch a linked boot-bank view with the bring-up KaeP stand-in."""
    if len(bank) < 0x10000:
        raise SystemExit("linked boot bank must be 64 KiB")
    out = bytearray(bank)
    # Descriptor at linked 0x80 (the KaeP payload).
    for off in range(0, 0x80, 4):
        struct.pack_into("<I", out, 0x80 + off,
                         SYNTH_DESCRIPTOR.get(off, 0))
    # Boot-image list node at linked 0xfd00.
    for off in range(0, 0x64, 4):
        struct.pack_into("<I", out, 0xFD00 + off, SYNTH_NODE.get(off, 0))
    return bytes(out)


def cmd_analyze(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom)
    k = info["kaep"]
    t = info["tags"]
    print(f"# KaeP @ file {k['file_offset']:#x}: {k['magic']!r} "
          f"size={k['size']:#x} value={k['value']:#x}")
    print(f"page tags: {t['span']} in the span, stride {t['stride']:#x}")
    print(f"  first {t['first']:#x}, last {t['last']:#x}")
    print(f"  grid matches: {t['grid_matches']} "
          f"(expected {t['count_expected']} tags)")
    print(f"  gaps: {[hex(g) for g in t['regular_gaps']]}")
    print(f"  KaeP size/value prefix also matches the tag: "
          f"{t['kaep_size_low_half_looks_like_tag']} (coincidence, not a tag)")
    kn = info["kernel"]
    print(f"kernel text file {kn['text_file']:#x} on a tag: "
          f"{kn['text_on_tag']} (tag index {kn['tag_index_at_text']})")
    print(f"  entry file {kn['entry_file']:#x} bytes {kn['entry_bytes']} "
          f"(nop;push: {kn['entry_is_nop_push']})")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(info, f, indent=2)
        print(f"wrote {a.json}")
    return 0


def cmd_despan(a):
    rom = open(a.rom, "rb").read()
    out = despan(rom)
    with open(a.out, "wb") as f:
        f.write(out)
    print(f"wrote {a.out}: {len(out):#x} bytes "
          f"({len(rom) - len(out):#x} tag bytes removed)")
    print("experimental: the tag semantics are not yet verified; "
          "use `verify` for the structural invariants")
    return 0


def cmd_synth(a):
    bank = open(a.bank, "rb").read()
    out = synth(bank)
    with open(a.out, "wb") as f:
        f.write(out)
    print(f"wrote {a.out}: synthetic KaeP descriptor at 0x80, "
          f"boot-image node at 0xfd00")
    print("run it with the linear-translation boot-region table:")
    print(f"  .venv/bin/python recompiler/bootregions.py build 6600_mcu.bin "
          f"out/6600_bootregions_linear.bin --profile linear")
    print("  NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 "
          f"NK_LOW_ROM_IMAGE={a.out} \\")
    print("    NK_REGIONS=out/6600_bootregions_linear.bin@0x80000000 \\")
    print("    NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \\")
    print("    NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \\")
    print("    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin "
          "--rom-image out/6600_runtime.bin")
    return 0


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom)
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("ok: " if cond else "FAIL: ") + msg)
        ok = ok and cond

    k = info["kaep"]
    t = info["tags"]
    kn = info["kernel"]
    check(k["magic"] == "KaeP", "KaeP magic at 0x124")
    check(k["size"] == 0x20, "KaeP size is 0x20")
    check(k["value"] == 0x1423DC, "KaeP value is 0x1423dc")
    check(k["value_in_span"], "KaeP value lies inside the paged span")
    check(t["first"] == FIRST_TAG, "first page tag is 0x20b0")
    check(t["last"] == SPAN_END, "last page tag is 0x6d9134")
    check(t["stride"] == PAGE_STRIDE, "page stride is 0x20ec")
    check(t["grid_matches"], "every tag lies on the 0x20ec grid")
    check(t["span"] == t["count_expected"],
          f"span has {t['count_expected']} tags (got {t['span']})")
    check(t["kaep_size_low_half_looks_like_tag"],
          "the KaeP size/value prefix looks like a tag (known coincidence)")
    check(kn["text_on_tag"], "kernel text starts on a page tag")
    check(kn["entry_is_nop_push"],
          "kernel entry at +0x54 is `nop; push {r4,r7,lr}`")
    # Removing the tag at the text start makes the entry +0x4e.
    check(rom[KERNEL_TEXT + 6 + 0x4E:KERNEL_TEXT + 6 + 0x52]
          == bytes.fromhex("000090b5"),
          "despanned entry (+0x4e) is also `nop; push`")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    an = sub.add_parser("analyze", help="print the KaeP block and page grid")
    an.add_argument("rom", nargs="?", default="6600_mcu.bin")
    an.add_argument("--json")
    an.set_defaults(func=cmd_analyze)
    ds = sub.add_parser("despan", help="remove page tags (experimental)")
    ds.add_argument("rom", nargs="?", default="6600_mcu.bin")
    ds.add_argument("out", nargs="?", default="out/6600_despanned.bin")
    ds.set_defaults(func=cmd_despan)
    sy = sub.add_parser("synth", help="patch a linked boot bank for bring-up")
    sy.add_argument("bank", nargs="?", default="out/6600_bootbank_linked.bin")
    sy.add_argument("out", nargs="?", default="out/6600_bootbank_kaep.bin")
    sy.set_defaults(func=cmd_synth)
    vf = sub.add_parser("verify", help="assert the page-grid invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
