#!/usr/bin/env python3
"""bitgdi_symbols.py - map the SDK bitgdi.lib export order to ROM addresses.

The ROM BitGdi export directory (TRomImageHeader.iExportDir at 0x506a7e78,
185 entries) is a plain array of addresses with no names.  The matching
Series 60 2.0 SDK import library references/.../bitgdi.lib carries the
mangled C++ names in export order, so symbol i maps to export i.

This prints the addresses for the drawing entry points we need for the
guest framebuffer pipeline (Clear/DrawBitmap/BitBlt).  The tail of the
export table also contains DLL-ref entries, so indices near the end are
less reliable.
"""
import json
import re
import struct
import sys

LIB = "references/Series60_v20/Epoc32/release/armi/urel/bitgdi.lib"
LAYOUT = "out/6600_runtime_layout.json"
IMAGE = "out/6600_runtime.bin"
BITGDI_UID3 = 0x10003B18


def lib_names(path):
    d = open(path, "rb").read()
    assert d[:8] == b"!<arch>\n"
    o = 8
    symtab = None
    while o + 60 <= len(d):
        hdr = d[o:o + 60]
        name = hdr[0:16].decode("latin1").strip()
        size = int(hdr[48:58].decode().strip())
        data = d[o + 60:o + 60 + size]
        if name == "/":
            symtab = data
        o += 60 + size + (size & 1)
    assert symtab, "no symbol table"
    names = []
    for m in re.finditer(rb"__imp_([ -~]{4,})", symtab):
        n = m.group(1).decode()
        if n not in names:
            names.append(n)
    return names


def main():
    try:
        names = lib_names(LIB)
    except FileNotFoundError:
        print("SKIP: %s missing" % LIB)
        return 0
    j = json.load(open(LAYOUT))
    img = [x for x in j["images"] if x["uid3"] == BITGDI_UID3][0]
    d = open(IMAGE, "rb").read()
    base = 0x50000000
    ed = img["export_dir"]
    for i, n in enumerate(names):
        if n.startswith(("Clear__9CFbsBitGc", "DrawBitmap__9CFbsBitGc",
                         "BitBlt__9CFbsBitGc")):
            a = struct.unpack_from("<I", d, ed - base + i * 4)[0]
            print("%3d %#010x %s" % (i, a, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
