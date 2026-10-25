#!/usr/bin/env python3
"""wd2.py — unpack and inspect Nokia WD2 (NHL-10 / 6600) firmware containers.

The Nokia 6600 is a DCT4 *UPP_WD2* phone.  Its firmware is distributed as a
`WD2 BT2` / `WD2 ALGORITHM` container (for 5.53.0: `NHL105530.C1` = MCU/ROM,
`NHL105530.22` = PPM).  Unlike the older DCT4 FLS containers, the WD2 payload is
not wrapped in `DCT4` chunks: after a small container header the file holds an
EKA1 Symbian ROM image (vector table, ROM header, kernel E32Image header, then
the ROM file system).

    py wd2.py extract fw/NHL105530.C1 6600_mcu.bin
    py wd2.py info    6600_mcu.bin       # also accepts fw/NHL105530.C1
    py wd2.py kernel  6600_mcu.bin fw/6600_kernel.bin
    py wd2.py list    6600_mcu.bin

`info` prints the ROM header (load address, size, kernel data, root directory)
and every E32Image header found.  `kernel` carves the kernel image described by
the E32Image header with the EKA1 kernel UID (0x100058e8) out of the ROM.

The ROM is an EKA1 (Symbian 7.0s) image: it is linked at 0x50000000, its kernel
data lives at 0x80000000, and the ROM file system stores its entries with a
+0x162b0 bias on the 6600 (the ROMFS is appended after the 0x162b0-byte kernel
area).  These are structural facts recovered from the image itself, not from a
vendor document; see docs/FIRMWARE-FORMAT.md.
"""
import argparse
import struct
import sys

WD2_MAGIC = b"WD2 "
VECTOR_MAGIC = bytes.fromhex("750100ea780100ea7b0100ea")  # b,x8, Thumb-capable
EKA1_ROM_BASE = 0x50000000

# EKA1 kernel UID (same in the N-Gage and 6600 firmware builds).
KERNEL_UID3 = 0x100058E8
# E32Image UID1 values (EKA1).  Note the order is the opposite of what the
# names suggest at first glance: 0x1000007a is the executable UID and
# 0x10000079 is the DLL UID (e32uid.h: KExecutableImageUidValue /
# KDynamicLibraryUidValue).  The kernel (uid3 0x100058e8) is an EXE.
UID_EXE = 0x1000007A
UID_DLL = 0x10000079


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def p32(b, o):
    return b[o:o + 4]


def find_vector_table(raw):
    """Return the offset of the ROM vector table, or -1."""
    return raw.find(VECTOR_MAGIC)


def is_wd2(raw):
    # 6600 v5.53.0: four-byte words at 0x00/0x04, then a CRC at 0x08 and the
    # "WD2 BT2\0" tag at 0x0c.  Don't assume the tag sits at a fixed offset.
    return (len(raw) > 0x40 and b"WD2 BT2" in raw[:0x20]
            and b"WD2 ALGORITHM" in raw[:0x40])


def extract_container(raw):
    """Strip the WD2 container header and return the embedded EKA1 ROM image."""
    if not is_wd2(raw):
        raise SystemExit("not a WD2 container (no WD2 BT2 / WD2 ALGORITHM header)")
    off = find_vector_table(raw)
    if off < 0:
        raise SystemExit("WD2 container has no ROM vector table")
    return raw[off:], off


def parse_rom_header(rom):
    """Parse the EKA1 ROM header.  The 6600 layout starts at +0x7c; the N-Gage
    layout at +0x80.  The common marker is rom_base == 0x50000000."""
    hdr = {}
    for shift in (0x7C, 0x80):
        if len(rom) < shift + 0x2C:
            continue
        if u32(rom, shift + 0x0C) == EKA1_ROM_BASE:
            hdr["header_offset"] = shift
            hdr["checksum"] = u32(rom, shift + 0x04)
            hdr["entry"] = u32(rom, shift + 0x08)
            hdr["rom_base"] = u32(rom, shift + 0x0C)
            hdr["rom_size"] = u32(rom, shift + 0x10)
            hdr["root_dir_list"] = u32(rom, shift + 0x14)
            hdr["kern_data"] = u32(rom, shift + 0x18)
            hdr["kern_limit"] = u32(rom, shift + 0x1C)
            hdr["primary_file"] = u32(rom, shift + 0x20)
            hdr["secondary_file"] = u32(rom, shift + 0x24)
            hdr["checksum2"] = u32(rom, shift + 0x28)
            break
    if "rom_base" not in hdr:
        raise SystemExit("no EKA1 ROM header (rom_base 0x50000000 not found)")
    return hdr


def scan_e32(rom):
    """Find EKA1 E32Image/ROM image headers (UID1 = EXE/DLL)."""
    out = []
    for o in range(0, len(rom) - 0x70, 4):
        uid1 = u32(rom, o)
        if uid1 not in (UID_EXE, UID_DLL):
            continue
        uid2, uid3, uidc, entry, code, data, csize, tsize, dsize, bss = \
            struct.unpack_from("<10I", rom, o + 4)
        if not (EKA1_ROM_BASE <= entry < EKA1_ROM_BASE + 0x2000000):
            continue
        if not (EKA1_ROM_BASE <= code < EKA1_ROM_BASE + 0x2000000):
            continue
        if csize == 0 or csize > 0x2000000:
            continue
        out.append({
            "offset": o,
            "uid1": uid1, "uid2": uid2, "uid3": uid3, "uid_checksum": uidc,
            "entry": entry, "code": code, "data": data,
            "code_size": csize, "text_size": tsize, "data_size": dsize,
            "bss_size": bss,
            # EKA1 serializes a 0x64-byte TRomImageHeader; code follows it.
            # (An earlier version of this tool used +0x6c for the kernel and
            # shifted every kernel instruction by 8 bytes.)
            "code_offset": o + 0x64,
        })
    return out


def find_kernel(rom):
    for e in scan_e32(rom):
        if e["uid3"] == KERNEL_UID3:
            return e
    raise SystemExit("kernel E32Image header (uid3 0x100058e8) not found")


def romfs_root(rom, hdr):
    """Locate the ROMFS root-directory list.

    The stored header pointer is relative to the start of the ROMFS area; on the
    6600 the root list is at rom_base + 0x162b0.  We also accept the pointer
    directly if it happens to be valid.
    """
    cands = []
    p = hdr["root_dir_list"]
    if EKA1_ROM_BASE <= p < EKA1_ROM_BASE + len(rom):
        cands.append(p)
    # On the 6600 the stored pointer is biased by +0x162b0 (the ROMFS starts
    # after the ROM header / kernel area; the archive stores 0x50300000).
    cands.append((p + 0x162B0) & 0xFFFFFFFF)
    for addr in cands:
        o = addr - EKA1_ROM_BASE
        if 0 <= o + 12 <= len(rom) and 1 <= u32(rom, o) <= 8:
            return addr
    return None


def read_dir_entry(rom, p, extra=False):
    """Read one directory entry.

    Ordinary directory entries are {size, address, attr, name_len, name}.
    The top-level ROMFS list stores an extra word before the address
    ({size, extra, address, attr, name_len, name}); pass extra=True for it.
    """
    if extra:
        if p + 14 > len(rom):
            return None
        size, extra_word, addr = struct.unpack_from("<III", rom, p)
        attr = rom[p + 12]
        nlen = rom[p + 13]
        name_off = p + 14
    else:
        if p + 10 > len(rom):
            return None
        size, addr = struct.unpack_from("<II", rom, p)
        extra_word = 0
        attr = rom[p + 8]
        nlen = rom[p + 9]
        name_off = p + 10
    if nlen == 0 or nlen > 255 or name_off + 2 * nlen > len(rom):
        return None
    try:
        name = rom[name_off:name_off + 2 * nlen].decode("utf-16le")
    except UnicodeDecodeError:
        return None
    if not all(0x20 <= ord(c) < 0x7F for c in name):
        return None
    nxt = (name_off + 2 * nlen + 3) & ~3
    return {"name": name, "size": size, "address": addr, "attr": attr,
            "extra": extra_word, "next": nxt}


def read_dir_entry_any(rom, p):
    """Try the regular layout, then the 'extra word' layout.

    The 6600's top-level ROMFS list starts with one entry that carries an extra
    word (its file checksum/size), while the entries that follow are regular.
    Trying both makes the listing robust without special-casing offsets.
    """
    return read_dir_entry(rom, p) or read_dir_entry(rom, p, extra=True)


def list_entries(rom, start, limit=64, extra=False):
    out = []
    p = start
    while len(out) < limit:
        e = read_dir_entry(rom, p, extra=extra) if extra is not None else read_dir_entry_any(rom, p)
        if not e:
            break
        out.append(e)
        p = e["next"]
    return out


def read_rom_dir(rom, packed_off, limit=1024):
    """Parse a TRomDir at a *packed flash offset*.

    EKA1's TRomDir is `iSize` followed by TRomEntry records
    `{size, address_lin, attr, name_len, UTF-16 name}` padded to 4 bytes.
    On the 6600 the directory is packed immediately after the 12-byte
    TRomRootDirectoryList, so callers pass `root_list_offset + 12`.  This is
    the correct parser; the older `read_dir_entry_any` heuristic is kept for
    compatibility.
    """
    if packed_off < 0 or packed_off + 4 > len(rom):
        return [], packed_off
    size = u32(rom, packed_off)
    p = packed_off + 4
    end = p + size
    if size == 0 or end > len(rom):
        return [], packed_off
    out = []
    while p + 10 <= end and len(out) < limit:
        sz, addr = u32(rom, p), u32(rom, p + 4)
        attr, nlen = rom[p + 8], rom[p + 9]
        if nlen == 0 or nlen > 255 or p + 10 + 2 * nlen > end:
            break
        try:
            name = rom[p + 10:p + 10 + 2 * nlen].decode("utf-16le")
        except UnicodeDecodeError:
            break
        out.append({"name": name, "size": sz, "address": addr,
                    "attr": attr, "next": p})
        p += 10 + 2 * nlen
        p = (p + 3) & ~3
        out[-1]["next"] = p
    return out, end


def normalise_kernel(rom, kern, name):
    """Materialise the kernel *text* at its link address.

    The code follows the E32Image header at +0x64 in the **page-header-free
    packed stream**.  The raw flash inserts a 0xec-byte page header at that
    point, so slicing `rom[code_offset:]` used to carve the page header as
    the first bytes of the kernel (the round-16 correction).  Keep the raw
    path as a fallback for images that are not paged.
    `iTextSize` is the executable text; `iCodeSize` also includes constant
    data.
    """
    size = kern.get("text_size") or kern["code_size"]
    if size <= 0 or size > kern["code_size"]:
        size = kern["code_size"]
    import pagestream
    stream = pagestream.build(rom)
    sk = pagestream.find_kernel(stream)
    if sk is not None:
        return bytes(stream[sk["text"]:sk["text"] + size])
    return bytes(rom[kern["code_offset"]:kern["code_offset"] + size])


def cmd_extract(a):
    raw = open(a.input, "rb").read()
    rom, off = extract_container(raw)
    open(a.output, "wb").write(rom)
    hdr = parse_rom_header(rom)
    print(f"container header {off:#x}; ROM {len(rom):#x} bytes -> {a.output}")
    print(f"  base {hdr['rom_base']:#x}  size {hdr['rom_size']:#x}  "
          f"entry(mask ROM) {hdr['entry']:#x}")


def load_any(path):
    """Accept either the original WD2 container or the extracted raw ROM."""
    raw = open(path, "rb").read()
    if is_wd2(raw):
        raw, off = extract_container(raw)
        print(f"WD2 container: ROM image at +{off:#x}, {len(raw):#x} bytes")
    return raw


def cmd_info(a):
    rom = load_any(a.input)
    hdr = parse_rom_header(rom)
    print(f"ROM {len(rom):#x} bytes")
    for k in ("header_offset", "checksum", "entry", "rom_base", "rom_size",
              "root_dir_list", "kern_data", "kern_limit", "primary_file",
              "secondary_file", "checksum2"):
        print(f"  {k:16} {hdr[k]:#010x}")
    root = romfs_root(rom, hdr)
    print(f"  ROMFS root list  {root:#x}" if root else "  ROMFS root list  <not found>")
    print("\nE32Image headers:")
    for e in scan_e32(rom):
        tag = ""
        if e["uid3"] == KERNEL_UID3:
            tag = "  <-- kernel"
        print(f"  hdr {e['offset']:#08x} uid3 {e['uid3']:#010x} "
              f"entry {e['entry']:#010x} code {e['code']:#010x} "
              f"size {e['code_size']:#x}{tag}")


def cmd_kernel(a):
    rom = load_any(a.input)
    k = find_kernel(rom)
    import pagestream
    stream = pagestream.build(rom)
    sk = pagestream.find_kernel(stream)
    img = normalise_kernel(rom, k, a.output)
    open(a.output, "wb").write(img)
    where = (f"stream header @ {sk['header']:#x}, text @ {sk['text']:#x}"
             if sk else f"header @ {k['offset']:#x}, code @ {k['code_offset']:#x}")
    print(f"kernel {where}, link {k['code']:#x}, entry {k['entry']:#x}, "
          f"{len(img):#x} bytes")
    if sk:
        print(f"  raw page header @ {k['code_offset']:#x} skipped")
    print(f"-> {a.output}")


def cmd_list(a):
    rom = load_any(a.input)
    hdr = parse_rom_header(rom)
    root = romfs_root(rom, hdr)
    if not root:
        raise SystemExit("ROMFS root not found")
    # The 6600 packs the root TRomDir immediately after the 12-byte
    # TRomRootDirectoryList.  Fall back to the older heuristic if that
    # does not parse (e.g. a future linear dump).
    packed = root + 12 - EKA1_ROM_BASE
    es, end = read_rom_dir(rom, packed)
    if es:
        print(f"root list @ {root:#x}, TRomDir @ {packed:#x}, "
              f"{len(es)} entries, data @ {end:#x}")
    else:
        es = list_entries(rom, root + 12 - EKA1_ROM_BASE, extra=None)
        print(f"root list @ {root:#x}, {len(es)} entries (heuristic parser)")
    for e in es:
        print(f"  {e['name']:28} size={e['size']:#8x} addr={e['address']:#010x} "
              f"attr={e['attr']:#04x}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract")
    e.add_argument("input"); e.add_argument("output")
    e.set_defaults(func=cmd_extract)
    i = sub.add_parser("info")
    i.add_argument("input"); i.set_defaults(func=cmd_info)
    k = sub.add_parser("kernel")
    k.add_argument("input"); k.add_argument("output")
    k.set_defaults(func=cmd_kernel)
    l = sub.add_parser("list")
    l.add_argument("input"); l.set_defaults(func=cmd_list)
    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
