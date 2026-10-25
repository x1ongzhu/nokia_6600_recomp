#!/usr/bin/env python3
"""pagestream.py — reconstruct the packed-record byte stream.

The 6600 flash image is not a plain byte stream.  Starting at file ``0x20b0``
it is organised as ``0x20ec``-byte records::

    +0x000  0xec-byte page header  (starts with ``20 00 00 00 dc 23``)
    +0x0ec  0x2000-byte payload

The payloads are the packed records the ROM build actually produced (image
headers, text, data, export tables, ROMFS directories).  The page headers are
**not** part of the packed image: round 7-15 treated the first six bytes as a
6-byte "page tag" and kept the other ``0xe6`` bytes inline, which shifted every
page after the first by ``0xec`` bytes.  That is why the kernel export table
looked unrelated to the stored text.

This module makes the payload stream explicit::

    first 0x20b0 bytes        file header / boot area, unchanged
    payload 0                file 0x20b0 + 0xec .. +0x20ec
    payload 1                file 0x40b0 + 0xec .. +0x20ec
    ...
    tail                     everything from the last page header on

The resulting stream keeps every packed record contiguous: the kernel's
``TRomImageHeader`` is followed by its ``.text`` at ``+0x64`` (the old raw
view inserted a page header between them).  After this transform the kernel's
478 exports land on function starts 469 times (98.1%); the 1788 exports of DLL
``0x100039e5`` land 1757 times (98.3%).

Commands::

    py recompiler/pagestream.py analyze 6600_mcu.bin
    py recompiler/pagestream.py build   6600_mcu.bin out/6600_pagestream.bin
    py recompiler/pagestream.py verify  6600_mcu.bin
"""
from __future__ import annotations

import argparse
import struct
import sys

TAG = bytes.fromhex("20000000dc23")
FIRST_TAG = 0x20B0
STRIDE = 0x20EC
HEADER = 0xEC
PAGE = STRIDE - HEADER          # 0x2000
LAST_TAG = 0x6D9134             # last page header in the 6600 v5.53.0 image
EXPECTED_TAGS = 852

UID_EXE = 0x1000007A
UID_DLL = 0x10000079
UID_KERNEL = 0x100058E8
KERNEL_CODE = 0x50310000
KERNEL_ENTRY = 0x50310054


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def tags(rom: bytes) -> list[int]:
    """Every page header in file order (they sit on the 0x20ec grid)."""
    out: list[int] = []
    i = 0
    while True:
        j = rom.find(TAG, i)
        if j < 0:
            return out
        out.append(j)
        i = j + 1


def grid_tags(rom: bytes) -> list[int]:
    """Page headers that belong to the 0x20ec grid starting at FIRST_TAG."""
    out: list[int] = []
    t = FIRST_TAG
    while t + HEADER <= len(rom):
        if rom[t:t + 6] != TAG:
            break
        out.append(t)
        t += STRIDE
    return out


def is_raw(rom: bytes) -> bool:
    """True when `rom` still contains the 0x20ec page headers."""
    return (len(rom) >= FIRST_TAG + 6 and
            rom[FIRST_TAG:FIRST_TAG + 6] == TAG)


def build(rom: bytes) -> bytes:
    """Return the packed-record stream (page headers removed)."""
    if not is_raw(rom):
        return rom                      # already a stream
    span = grid_tags(rom)
    if not span:
        return rom
    last = span[-1]
    out = bytearray(rom[:FIRST_TAG])
    for t in span:
        out += rom[t + HEADER:t + STRIDE]
    # The last page header has no complete record after it in this image; the
    # bytes from it on are the linear tail (the paged span ends there).
    out += rom[last:]
    return bytes(out)


def raw_to_stream(rom: bytes, off: int) -> int | None:
    """Map a raw file offset to the payload stream; None inside a page header."""
    if not is_raw(rom):
        return off
    span = grid_tags(rom)
    if not span:
        return off
    last = span[-1]
    if off < FIRST_TAG:
        return off
    if off >= last:
        return FIRST_TAG + len(span) * PAGE + (off - last)
    i, rem = divmod(off - FIRST_TAG, STRIDE)
    if rem < HEADER:
        return None
    return FIRST_TAG + i * PAGE + (rem - HEADER)


def stream_to_raw(rom: bytes, off: int) -> int | None:
    """Inverse of raw_to_stream()."""
    if not is_raw(rom):
        return off
    span = grid_tags(rom)
    if not span:
        return off
    last = span[-1]
    if off < FIRST_TAG:
        return off
    payload_end = FIRST_TAG + len(span) * PAGE
    if off >= payload_end:
        return last + (off - payload_end)
    i, rem = divmod(off - FIRST_TAG, PAGE)
    t = FIRST_TAG + i * STRIDE
    if t >= last:
        return None
    return t + HEADER + rem


def find_kernel(stream: bytes) -> dict | None:
    """Locate the kernel E32Image record in a packed stream."""
    for o in range(0, len(stream) - 0x70, 2):
        if u32(stream, o) != UID_EXE:
            continue
        if u32(stream, o + 8) != UID_KERNEL:
            continue
        entry = u32(stream, o + 0x10)
        code = u32(stream, o + 0x14)
        csize = u32(stream, o + 0x1C)
        tsize = u32(stream, o + 0x20)
        if code < 0x50000000 or code >= 0x52000000:
            continue
        if not 0x40 <= csize <= 0x1000000 or not 0 < tsize <= csize:
            continue
        return {
            "header": o,
            "text": o + 0x64,
            "entry": entry,
            "code": code,
            "code_size": csize,
            "text_size": tsize,
        }
    return None


def analyze(rom: bytes) -> dict:
    span = grid_tags(rom)
    stream = build(rom)
    first = span[0] if span else None
    last = span[-1] if span else None
    kernel = find_kernel(stream)
    if kernel is not None:
        kernel["entry_word"] = u32(
            stream, kernel["text"] + (kernel["entry"] - kernel["code"]))
    return {
        "raw_size": len(rom),
        "stream_size": len(stream),
        "tags": len(span),
        "first_tag": first,
        "last_tag": last,
        "stride": STRIDE,
        "header": HEADER,
        "page": PAGE,
        "grid": bool(span) and all(
            span[i] == FIRST_TAG + i * STRIDE for i in range(len(span))),
        "kernel": kernel,
    }


def _check(ok: bool, msg: str) -> bool:
    print(("ok: " if ok else "FAIL: ") + msg)
    return ok


def cmd_analyze(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom)
    k = info["kernel"]
    print(f"# raw {info['raw_size']:#x} bytes, packed stream "
          f"{info['stream_size']:#x} bytes")
    print(f"page headers: {info['tags']} at {info['first_tag']:#x}.."
          f"{info['last_tag']:#x}, stride {info['stride']:#x} "
          f"(header {info['header']:#x}, payload {info['page']:#x})")
    if k:
        print(f"kernel header {k['header']:#x}  text {k['text']:#x} "
              f"code {k['code']:#010x}  entry {k['entry']:#010x}")
        print(f"  header+0x64 == text: {k['text'] == k['header'] + 0x64}  "
              f"entry word {k['entry_word']:#010x}")
    else:
        print("kernel record not found")
    if a.json:
        with open(a.json, "w") as f:
            import json
            json.dump(info, f, indent=2)
        print(f"wrote {a.json}")
    return 0


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    stream = build(rom)
    with open(a.out, "wb") as f:
        f.write(stream)
    print(f"wrote {a.out}: {len(stream):#x} bytes "
          f"({len(rom) - len(stream):#x} header bytes removed)")
    k = find_kernel(stream)
    if k:
        print(f"kernel record: header {k['header']:#x}, text {k['text']:#x}, "
              f"entry {k['entry']:#010x} (word {u32(stream, k['text'] +
              (k['entry'] - k['code'])):#010x})")
    return 0


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    info = analyze(rom)
    k = info["kernel"]
    ok = True
    ok &= _check(info["tags"] == EXPECTED_TAGS,
                 f"{EXPECTED_TAGS} page headers (got {info['tags']})")
    ok &= _check(info["first_tag"] == FIRST_TAG, "first page header 0x20b0")
    ok &= _check(info["last_tag"] == LAST_TAG, "last page header 0x6d9134")
    ok &= _check(info["grid"], "page headers lie on the 0x20ec grid")
    ok &= _check(info["stream_size"] < info["raw_size"],
                 "packed stream is shorter than the raw flash")
    ok &= _check(k is not None, "kernel E32Image record found")
    if k:
        ok &= _check(k["code"] == KERNEL_CODE,
                     f"kernel code address {k['code']:#010x}")
        ok &= _check(k["entry"] == KERNEL_ENTRY,
                     f"kernel entry {k['entry']:#010x}")
        ok &= _check(k["text"] == k["header"] + 0x64,
                     "kernel text follows the 0x64-byte header")
        ok &= _check((k["entry_word"] & 0xFFFF0000) == 0xE92D0000,
                     f"kernel entry word {k['entry_word']:#010x} is an ARM "
                     f"push {{..,lr}}")
        # The first text word is the ARM exception vector table.
        w0 = u32(build(rom), k["text"])
        ok &= _check((w0 & 0xFFFFF000) == 0xE59FF000,
                     f"kernel text starts with an ARM vector table "
                     f"({w0:#010x})")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    an = sub.add_parser("analyze", help="print the page/record layout")
    an.add_argument("rom", nargs="?", default="6600_mcu.bin")
    an.add_argument("--json")
    an.set_defaults(func=cmd_analyze)
    bd = sub.add_parser("build", help="write the page-header-free stream")
    bd.add_argument("rom", nargs="?", default="6600_mcu.bin")
    bd.add_argument("out", nargs="?", default="out/6600_pagestream.bin")
    bd.set_defaults(func=cmd_build)
    vf = sub.add_parser("verify", help="assert the stream invariants")
    vf.add_argument("rom", nargs="?", default="6600_mcu.bin")
    vf.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
