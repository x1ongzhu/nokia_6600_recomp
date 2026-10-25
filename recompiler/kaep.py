#!/usr/bin/env python3
"""kaep.py — unpack the KaeP/PeaK boot container and measure the page grid.

The first 7 MiB of the 6600 flash image are not a plain byte stream.  From
file ``0x20b0`` on, a six-byte *page tag* is inserted every ``0x20ec`` bytes::

    20 00 00 00 dc 23

The first real tag is at ``0x20b0`` and the last at ``0x6d9134``: **852**
tags.  The kernel text starts on a tag (file ``0x326924`` = runtime
``0x50310000``), which is why its entry at ``0x50310054`` is valid while code
after the first text page is shifted by six bytes per tag.  The tag semantics
are not documented; this module makes the structure measurable instead of
guessing.

The ``KaeP`` record sits just before the paged region::

    +0x00  "KaeP"      ; the 32-bit little-endian constant 0x5065614B ("PeaK")
    +0x04  u32 size     (0x20)
    +0x08  u32 length   (0x1423dc)
    +0x0a  u8  record[0x20]   ; starts at file 0x12e, overlaps the top of +0x08
    +0x2a  u8  image[length]  ; starts at file 0x14e

The 0x20-byte record at file ``0x12e`` is preserved verbatim; it is **not**
decoded as a synthetic descriptor.  The embedded image starts at file
``0x14e`` and runs for ``0x1423dc`` bytes (ending at ``0x14252a``).  Its first
word is an ARM vector table entry (``ldr pc,[pc,#0x18]``) and image ``+0x38``
(file ``0x186``) contains real ARM boot code, so this is a container payload
rather than a checksum.  The 2-byte overlap is deliberate in the packing:
``value``'s high half is the first halfword of the record's branch stub.

The mask ROM would normally apply its own (still undocumented) transform to
the embedded image before handing control to the secondary loader.  This
module keeps that boundary explicit:

* ``unpack`` extracts the record and the embedded image byte-for-byte;
* ``install`` writes an executable ARM ``ldr pc`` trampoline at linked ``0x80``
  plus the boot-image list node the loader consumes.  The trampoline targets
  the kernel entry, so the round-15/16 handoff actually enters the kernel
  instead of executing the KaeP record bytes as instructions;
* ``synth`` is kept as the old, purely synthetic bring-up stand-in.

The 0x20-byte record codec is still opaque.  ``unpack`` and ``install`` do not
pretend to decrypt it; they make the container boundary and the handoff
reproducible.

Commands::

    py recompiler/kaep.py analyze 6600_mcu.bin
    py recompiler/kaep.py unpack  6600_mcu.bin \
                                   out/6600_kaep_record.bin \
                                   out/6600_kaep_image.bin
    py recompiler/kaep.py install out/6600_bootbank_linked.bin 6600_mcu.bin \
                                   out/6600_bootbank_kaep.bin
    py recompiler/kaep.py despan  6600_mcu.bin out/6600_despanned.bin
    py recompiler/kaep.py synth   out/6600_bootbank_linked.bin \
                                   out/6600_bootbank_kaep.bin
    py recompiler/kaep.py verify  6600_mcu.bin
"""
from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import struct
import sys

import bootregions

KAE_P_MAGIC = b"KaeP"
PAGE_TAG = bytes.fromhex("20000000dc23")
PAGE_STRIDE = 0x20EC
KAE_P_OFF = 0x124
# The header is 10 bytes: magic, the 0x20-byte record size, then the image
# size.  The record itself overlaps the top half of the image-size word, which
# is why it starts at 0x12e and the image at 0x14e; the image then begins with
# the ARM vector table (`ldr pc,[pc,#0x18]`) on a 4-byte-aligned word.
KAE_P_RECORD_OFF = KAE_P_OFF + 0x0A          # 0x12e
KAE_P_IMAGE_OFF = KAE_P_RECORD_OFF + 0x20    # 0x14e
KAE_P_RECORD_SIZE = 0x20
KAE_P_IMAGE_SIZE = 0x1423DC
FIRST_TAG = 0x20B0
SPAN_END = 0x6D9134
TAG_LEN = len(PAGE_TAG)
RAM_BASE = 0x80000000
KERNEL_TEXT = 0x326924
KERNEL_ENTRY = 0x50310054
TRAMPOLINE = 0x80
LIST_HEAD = 0xFD00
NODE = 0xFD10
NODE_TYPE = 0x05040000

# `ldr pc, [pc, #-4]` followed by the absolute target.  The loader consumes the
# descriptor fields at +0x0c and above; only the first two words are code.
TRAMPOLINE_WORD = 0xE51FF004

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


def container(rom: bytes) -> dict:
    """Return the KaeP record and the embedded image byte-for-byte.

    The header is ``{magic, record_size, image_size}`` followed by that many
    bytes of opaque record and then the image.  ``unpack``/``install`` keep
    this boundary; they never claim to decode the record.
    """
    if len(rom) < KAE_P_RECORD_OFF:
        raise SystemExit("image is too small for the KaeP record")
    magic = rom[KAE_P_OFF:KAE_P_OFF + 4]
    record_size = u32(rom, KAE_P_OFF + 4)
    image_size = u32(rom, KAE_P_OFF + 8)
    if record_size <= 0 or KAE_P_RECORD_OFF + record_size > len(rom):
        raise SystemExit(f"bad KaeP record size {record_size:#x}")
    image_off = KAE_P_RECORD_OFF + record_size
    if image_off + image_size > len(rom):
        raise SystemExit(
            f"KaeP image {image_size:#x} at {image_off:#x} leaves the file")
    return {
        "header_offset": KAE_P_OFF,
        "magic": magic.decode("latin-1"),
        "record_offset": KAE_P_RECORD_OFF,
        "record_size": record_size,
        "image_offset": image_off,
        "image_size": image_size,
        "record": rom[KAE_P_RECORD_OFF:KAE_P_RECORD_OFF + record_size],
        "image": rom[image_off:image_off + image_size],
        "record_sha256": hashlib.sha256(
            rom[KAE_P_RECORD_OFF:KAE_P_RECORD_OFF + record_size]).hexdigest(),
        "image_sha256": hashlib.sha256(
            rom[image_off:image_off + image_size]).hexdigest(),
    }


def descriptor_fields(entry: int = KERNEL_ENTRY) -> dict[int, int]:
    """Fields the secondary loader consumes from the linked 0x80 descriptor."""
    return {
        0x0C: RAM_BASE,                          # linear key used by 0xc58
        0x14: entry,
        0x18: RAM_BASE,
        0x1C: bootregions.KERNEL_CODE,
        0x20: LIST_HEAD,
        0x24: bootregions.KERNEL_DATA_SIZE,
        0x28: bootregions.KERNEL_BSS_SIZE,
        0x2C: 0,
        0x34: bootregions.KERNEL_CODE_SIZE,
        0x48: (bootregions.KERNEL_DATA_SIZE +
               bootregions.KERNEL_BSS_SIZE),
        0x58: RAM_BASE,
        0x64: entry,
    }


def node_fields(entry: int = KERNEL_ENTRY) -> dict[int, int]:
    """Boot-image list node returned by the 0xc58 lookup."""
    return {
        0x04: bootregions.KERNEL_HEADER,
        0x10: entry,
        0x14: bootregions.KERNEL_CODE,
        0x1C: bootregions.KERNEL_CODE,
        0x2C: 0,
        0x34: bootregions.KERNEL_CODE_SIZE,
        0x48: (bootregions.KERNEL_DATA_SIZE +
               bootregions.KERNEL_BSS_SIZE),
        0x5C: 0,
        0x60: NODE_TYPE,
    }


def install(bank: bytes, rom: bytes, entry: int = KERNEL_ENTRY) -> bytes:
    """Install the loader descriptor, list node and executable handoff.

    The first two words at linked 0x80 become ``ldr pc,[pc,#-4]`` plus the
    absolute kernel entry.  The loader only checks the +0/+4/+8 fields when
    its ``0x40000000`` flag is set, which the boot-bank entry does not do, so
    the trampoline can share the descriptor with the fields it does consume.
    """
    if len(bank) != 0x10000:
        raise SystemExit("linked boot bank must be 64 KiB")
    container(rom)                             # validate the source image
    out = bytearray(bank)
    struct.pack_into("<I", out, TRAMPOLINE, TRAMPOLINE_WORD)
    struct.pack_into("<I", out, TRAMPOLINE + 4, entry)
    for off, value in descriptor_fields(entry).items():
        struct.pack_into("<I", out, TRAMPOLINE + off, value)
    for off in range(0, 0x80, 4):
        struct.pack_into("<I", out, LIST_HEAD + off, 0)
    struct.pack_into("<I", out, LIST_HEAD + 4, NODE)
    for off, value in node_fields(entry).items():
        struct.pack_into("<I", out, NODE + off, value)
    return bytes(out)


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
    c = container(rom)
    image = c["image"]
    return {
        "kaep": {
            "file_offset": KAE_P_OFF,
            "magic": magic.decode("latin-1"),
            "size": size,
            "value": value,
            "value_in_span": FIRST_TAG <= value < SPAN_END,
            "record_offset": c["record_offset"],
            "record_size": c["record_size"],
            "image_offset": c["image_offset"],
            "image_size": c["image_size"],
            "image_end": c["image_offset"] + c["image_size"],
            "record_sha256": c["record_sha256"],
            "image_sha256": c["image_sha256"],
            "image_first_word": u32(image, 0) if len(image) >= 4 else None,
            "image_second_word": u32(image, 4) if len(image) >= 8 else None,
            "image_code_word": u32(image, 0x38) if len(image) >= 0x3C else None,
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


def cmd_unpack(a):
    rom = open(a.rom, "rb").read()
    c = container(rom)
    with open(a.record, "wb") as f:
        f.write(c["record"])
    with open(a.image, "wb") as f:
        f.write(c["image"])
    print(f"KaeP @ {c['header_offset']:#x}: {c['magic']!r} "
          f"record {c['record_size']:#x} @ {c['record_offset']:#x}, "
          f"image {c['image_size']:#x} @ {c['image_offset']:#x}.."
          f"{c['image_offset'] + c['image_size']:#x}")
    print(f"wrote {a.record}: {len(c['record'])} bytes "
          f"(sha256 {c['record_sha256'][:16]}...)")
    print(f"wrote {a.image}: {len(c['image'])} bytes "
          f"(sha256 {c['image_sha256'][:16]}...)")
    print("the 0x20-byte record is preserved verbatim; the mask-ROM codec for "
          "it is still undocumented")
    if a.json:
        info = dict(c)
        info.pop("record")
        info.pop("image")
        info["record_offset"] = c["record_offset"]
        info["image_offset"] = c["image_offset"]
        with open(a.json, "w") as f:
            json.dump(info, f, indent=2)
        print(f"wrote {a.json}")
    return 0


def cmd_install(a):
    bank = open(a.bank, "rb").read()
    rom = open(a.rom, "rb").read()
    out = install(bank, rom, a.entry)
    with open(a.out, "wb") as f:
        f.write(out)
    print(f"wrote {a.out}: {len(out):#x}-byte linked boot bank")
    print(f"  linked 0x80: ldr pc,[pc,#-4]; .word {a.entry:#010x} "
          f"(executable handoff)")
    print(f"  list head 0x{LIST_HEAD:x} -> node 0x{NODE:x} "
          f"(type 0x{NODE_TYPE:08x}, next 0)")
    print("  the KaeP record is still present in the bank; this installs the "
          "boot-image handoff, not a decoded record")
    print(f"  NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 "
          f"NK_LOW_ROM_IMAGE={a.out} \\")
    print(f"    NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 "
          f"NK_ENTRY=0x30c \\")
    print("    NK_R11=0x80000000 NK_R10=0x80000000 NK_RECOVER=1 "
          "NK_CODE_ONLY=1 \\")
    print("    NK_BUDGET=1500000 NK_MMIO_N=0 "
          "./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin "
          "--rom-image out/6600_runtime.bin")
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
    check(k["record_offset"] == KAE_P_RECORD_OFF,
          f"KaeP record starts at file {KAE_P_RECORD_OFF:#x}")
    check(k["record_size"] == KAE_P_RECORD_SIZE,
          f"KaeP record is {KAE_P_RECORD_SIZE:#x} bytes")
    check(k["image_offset"] == KAE_P_IMAGE_OFF,
          f"KaeP image starts at file {KAE_P_IMAGE_OFF:#x}")
    check(k["image_size"] == KAE_P_IMAGE_SIZE,
          f"KaeP image length is {KAE_P_IMAGE_SIZE:#x}")
    check(k["image_end"] == KAE_P_IMAGE_OFF + KAE_P_IMAGE_SIZE,
          f"KaeP image ends at file {k['image_end']:#x}")
    c = container(rom)
    check(c["record"] == rom[KAE_P_RECORD_OFF:
                             KAE_P_RECORD_OFF + KAE_P_RECORD_SIZE],
          "KaeP record is extracted verbatim")
    check(u32(c["image"], 0) == 0xE59FF018,
          "embedded image starts with an ARM `ldr pc,[pc,#0x18]` vector")
    check(u32(c["image"], 0x38) == 0xE59F11A0,
          "embedded image has ARM code at +0x38 (`ldr r1,[pc,#0x1a0]`)")
    probe = install(bytes(0x10000), rom)
    check(struct.unpack_from("<II", probe, TRAMPOLINE) ==
          (TRAMPOLINE_WORD, KERNEL_ENTRY),
          "installed handoff at 0x80 is `ldr pc,[pc,#-4]; .word kernel entry`")
    check(struct.unpack_from("<I", probe, TRAMPOLINE + 0x14)[0] == KERNEL_ENTRY,
          "descriptor entry field is the kernel entry")
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
    up = sub.add_parser("unpack", help="extract the KaeP record and image")
    up.add_argument("rom", nargs="?", default="6600_mcu.bin")
    up.add_argument("record", nargs="?", default="out/6600_kaep_record.bin")
    up.add_argument("image", nargs="?", default="out/6600_kaep_image.bin")
    up.add_argument("--json")
    up.set_defaults(func=cmd_unpack)
    in_ = sub.add_parser("install",
                         help="install the executable boot-image handoff")
    in_.add_argument("bank", nargs="?", default="out/6600_bootbank_linked.bin")
    in_.add_argument("rom", nargs="?", default="6600_mcu.bin")
    in_.add_argument("out", nargs="?", default="out/6600_bootbank_kaep.bin")
    in_.add_argument("--entry", type=lambda s: int(s, 0),
                     default=KERNEL_ENTRY)
    in_.set_defaults(func=cmd_install)
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
