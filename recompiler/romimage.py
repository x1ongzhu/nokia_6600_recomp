#!/usr/bin/env python3
"""romimage.py — reconstruct the 6600 EKA1 runtime ROM layout.

The WD2 flash image (`6600_mcu.bin`) is a *section database*, not a linear
dump.  Each ROM image is stored as one packed record:

    TRomImageHeader (0x64)
    .text            iTextSize          -> iCodeAddress
    .rodata/.rdata   (not described by the header)
    .data            iDataSize          -> iDataAddress
    .edata           iExportDirCount*4  -> iExportDir
    TDllRefTable     (if iDllRefTable)  -> iDllRefTable

and the ROM file system stores its data at yet another set of offsets.  The
runtime layout, however, is simple:

    0x50000000  ROM boot code / vectors
    0x5030_0000 ROMFS root list + directories
    0x5031_0000 kernel text/data/edata/dllref
    ...         DLLs
    0x5043_fc90 ROMFS files (stored linearly: file = va - 0x5000_0000)

`build` writes a flat 22 MiB image at those runtime addresses; the boot
harness can map it directly and start at the kernel entry.  `scan` and
`check` print what was recovered, including the section the header does not
describe (the debug/rodata block between .text and .data).

    py romimage.py scan 6600_mcu.bin
    py romimage.py build 6600_mcu.bin out/6600_runtime.bin
    py romimage.py build 6600_mcu.bin out/6600_runtime.bin --json out/layout.json
    py romimage.py calls 6600_mcu.bin
    py romimage.py names 6600_mcu.bin            # root / \\System / boot table
    py romimage.py names 6600_mcu.bin --all      # ... plus \\System\\Libs

Packed records are only 2-byte aligned (the ROM build removed the linker's
4-byte padding), so the header scan steps by 2.  `build` places every plausible
image at its runtime address, not just the kernel's direct DLL references.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import dataclass, field, asdict

ROM_BASE = 0x50000000
ROM_SIZE = 0x01600000

UID_EXE = 0x1000007A          # KExecutableImageUidValue (e32uid.h)
UID_DLL = 0x10000079          # KDynamicLibraryUidValue
UID_KERNEL = 0x100058E8

# The ROMFS root-list pointer in the ROM header is stored 0x162b0 below the
# list's file position on the 6600 (the ROMFS was moved during ROM build).
ROMFS_ROOT_BIAS = 0x162B0


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


# ---------------------------------------------------------------------------
# TRomHeader
# ---------------------------------------------------------------------------

def find_rom_header(rom: bytes) -> dict:
    """Decode the 6600's EKA1 TRomHeader.

    The 6600 build puts the header at +0x7c (a 0x7c-byte boot area), four
    bytes earlier than the later EKA2 builds documented in romimage.rtf.
    """
    for base in (0x7C, 0x80):
        if len(rom) < base + 0x2C:
            continue
        if u32(rom, base + 0x0C) != ROM_BASE:
            continue
        return {
            "header_offset": base,
            "checksum": u32(rom, base + 0x04),
            "entry": u32(rom, base + 0x08),
            "rom_base": u32(rom, base + 0x0C),
            "rom_size": u32(rom, base + 0x10),
            "root_dir_list": u32(rom, base + 0x14),
            "kern_data": u32(rom, base + 0x18),
            "kern_limit": u32(rom, base + 0x1C),
            "primary_file": u32(rom, base + 0x20),
            "secondary_file": u32(rom, base + 0x24),
            "checksum2": u32(rom, base + 0x28),
        }
    raise SystemExit("no EKA1 ROM header (rom_base 0x50000000)")


# ---------------------------------------------------------------------------
# TRomImageHeader records
# ---------------------------------------------------------------------------

@dataclass
class Section:
    name: str
    file_off: int
    size: int
    va: int
    overlay: bool = False

    @property
    def file_end(self):
        return self.file_off + self.size

    @property
    def va_end(self):
        return self.va + self.size


@dataclass
class Image:
    hdr_off: int
    next_hdr_off: int
    uid1: int
    uid2: int
    uid3: int
    entry: int
    code: int
    data_addr: int
    code_size: int
    text_size: int
    data_size: int
    bss_size: int
    dll_ref: int
    export_count: int
    export_dir: int
    flags: int
    databss: int
    sections: list[Section] = field(default_factory=list)
    rodata: Section | None = None
    dllref_size: int = 0
    dllrefs: list[int] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def text(self) -> Section:
        return self.sections[0]

    def section(self, name: str) -> Section | None:
        for s in self.sections:
            if s.name == name:
                return s
        return None


def is_e32_header(rom: bytes, o: int) -> bool:
    # Packed image records are only 2-byte aligned: the ROM build removes the
    # linker's 4-byte padding, so a TRomImageHeader can start at 2 mod 4 (for
    # example /System/Libs/MmfAudioController.dll's header sits at file
    # 0x7271ca).  Scanning every 4th byte used to drop those images entirely.
    if o < 0 or o + 0x70 > len(rom) or (o & 1):
        return False
    if u32(rom, o) not in (UID_EXE, UID_DLL):
        return False
    uid2, uid3 = u32(rom, o + 4), u32(rom, o + 8)
    entry, code, data = u32(rom, o + 0x10), u32(rom, o + 0x14), u32(rom, o + 0x18)
    csize, tsize, dsize = u32(rom, o + 0x1C), u32(rom, o + 0x20), u32(rom, o + 0x24)
    if not 0x10000000 <= uid2 < 0x10200000 or uid3 == 0:
        return False
    if not ROM_BASE <= entry < ROM_BASE + 0x2000000:
        return False
    if not ROM_BASE <= code < ROM_BASE + 0x2000000:
        return False
    if not 0x40 <= csize <= 0x1000000 or not 0 < tsize <= csize:
        return False
    if dsize > 0x1000000:
        return False
    return True


def scan_headers(rom: bytes) -> list[int]:
    return [o for o in range(0, len(rom) - 0x70, 2) if is_e32_header(rom, o)]


def find_dll_ref_table(rom: bytes, hdr: int, nxt: int) -> tuple[int, int]:
    """Locate the TDllRefTable at the end of a packed record.

    Returns (file_offset, size).  The table is
    `{u16 flags; u16 count; u32 entry[count][2]; u32 0xffffffff}`.
    """
    if nxt >= len(rom) or u32(rom, nxt - 4) != 0xFFFFFFFF:
        return 0, 0
    for count in range(1, 33):
        start = nxt - 4 - count * 8 - 4
        if start < hdr + 0x64:
            break
        if (u32(rom, start) >> 16) == count:
            return start, 4 + count * 8 + 4
    return 0, 0


def parse_image(rom: bytes, hdr: int, nxt: int) -> Image:
    img = Image(
        hdr_off=hdr,
        next_hdr_off=nxt,
        uid1=u32(rom, hdr),
        uid2=u32(rom, hdr + 4),
        uid3=u32(rom, hdr + 8),
        entry=u32(rom, hdr + 0x10),
        code=u32(rom, hdr + 0x14),
        data_addr=u32(rom, hdr + 0x18),
        code_size=u32(rom, hdr + 0x1C),
        text_size=u32(rom, hdr + 0x20),
        data_size=u32(rom, hdr + 0x24),
        bss_size=u32(rom, hdr + 0x28),
        dll_ref=u32(rom, hdr + 0x38),
        export_count=u32(rom, hdr + 0x3C),
        export_dir=u32(rom, hdr + 0x40),
        flags=u32(rom, hdr + 0x50),
        databss=u32(rom, hdr + 0x58),
    )
    if nxt <= hdr + 0x64:
        nxt = len(rom)

    dll_off, dll_size = (find_dll_ref_table(rom, hdr, nxt)
                         if img.dll_ref else (0, 0))
    img.dllref_size = dll_size
    if dll_size:
        count = u16(rom, dll_off + 2)
        img.dllrefs = [u32(rom, dll_off + 4 + i * 8) for i in range(count)]

    edata_size = img.export_count * 4
    data_size = img.data_size if img.data_addr else 0
    data_off = nxt - dll_size - edata_size - data_size
    edata_off = data_off + data_size
    text_off = hdr + 0x64

    img.sections = [
        Section("text", text_off, img.text_size, img.code),
    ]
    if data_size:
        img.sections.append(Section("data", data_off, data_size, img.data_addr))
    if edata_size:
        img.sections.append(Section("edata", edata_off, edata_size, img.export_dir))
    if dll_size:
        img.sections.append(Section("dllref", dll_off, dll_size, img.dll_ref))

    middle_off, middle_size = text_off + img.text_size, data_off - (text_off + img.text_size)
    if middle_size > 0:
        # A few bytes here are alignment padding between .text and .edata;
        # the kernel and the big DLLs carry a real, header-less block.
        name = "rodata" if middle_size >= 16 else "padding"
        img.rodata = Section(name, middle_off, middle_size, 0)

    # ---- validation -------------------------------------------------------
    if data_off < text_off + img.text_size:
        img.errors.append(
            f"section layout overlaps: data starts at {data_off:#x}, "
            f"text ends at {text_off + img.text_size:#x}")
    if img.code_size < img.text_size:
        img.errors.append(f"code_size {img.code_size:#x} < text_size {img.text_size:#x}")
    if img.data_addr and img.data_addr != img.code + img.text_size:
        img.errors.append(
            f"data address {img.data_addr:#x} does not follow text "
            f"({img.code + img.text_size:#x})")
    if img.export_dir and not (ROM_BASE <= img.export_dir < ROM_BASE + ROM_SIZE):
        img.errors.append(f"export dir {img.export_dir:#x} outside ROM")
    if img.entry and not (ROM_BASE <= img.entry < ROM_BASE + ROM_SIZE):
        img.errors.append(f"entry {img.entry:#x} outside ROM")
    return img


def scan_images(rom: bytes) -> list[Image]:
    hs = scan_headers(rom)
    out = []
    for i, o in enumerate(hs):
        nxt = hs[i + 1] if i + 1 < len(hs) else len(rom)
        out.append(parse_image(rom, o, nxt))
    return out


def record_is_plausible(im: Image) -> bool:
    """Reject 2-byte-scan false positives.

    A packed record is `header + text + [rodata] + data + edata + dllref`, and
    the next header starts right after it.  The header describes every byte
    except the header-less rodata/debug block, which is small.  A candidate
    whose declared sections do not fit before the next header, or leave a huge
    unexplained gap, is data that happened to look like a header.
    """
    if im.errors:
        return False
    declared = (0x64 + im.text_size +
                (im.data_size if im.data_addr else 0) +
                im.export_count * 4 + im.dllref_size)
    actual = im.next_hdr_off - im.hdr_off
    return 0 <= actual - declared <= 0x2000


def plausible_images(images: list[Image]) -> list[Image]:
    return [im for im in images if record_is_plausible(im)]


# ---------------------------------------------------------------------------
# reachability (the images the kernel references directly)
# ---------------------------------------------------------------------------

def reachable_images(images: list[Image]) -> list[Image]:
    images = plausible_images(images)
    by_code = {im.code: im for im in images}
    kernel = next((im for im in images if im.uid3 == UID_KERNEL), None)
    if kernel is None:
        raise SystemExit("kernel image (uid3 0x100058e8) not found")
    seen, todo = {kernel.hdr_off}, [kernel]
    while todo:
        im = todo.pop()
        for ref in im.dllrefs:
            dep = by_code.get(ref)
            if dep is not None and dep.hdr_off not in seen:
                seen.add(dep.hdr_off)
                todo.append(dep)
    return [im for im in images if im.hdr_off in seen]



# ---------------------------------------------------------------------------
# ROMFS
# ---------------------------------------------------------------------------

def find_romfs_root(rom: bytes, root_dir_list: int) -> int | None:
    """Return the file offset of the TRomRootDirectoryList."""
    candidates = []
    p = root_dir_list - ROM_BASE
    if 0 <= p < len(rom):
        candidates.append(p)
    # The 6600 stores the pointer 0x162b0 below the actual list.
    p2 = root_dir_list - ROM_BASE + ROMFS_ROOT_BIAS
    if 0 <= p2 < len(rom):
        candidates.append(p2)
    for off in candidates:
        if off + 12 > len(rom):
            continue
        count = u32(rom, off)
        if not 1 <= count <= 8:
            continue
        ok = True
        for i in range(count):
            addr = u32(rom, off + 4 + i * 8 + 4)
            if not ROM_BASE <= addr < ROM_BASE + ROM_SIZE:
                ok = False
                break
        if ok:
            return off
    return None


@dataclass
class RomfsEntry:
    name: str
    size: int
    addr: int
    attr: int


def read_rom_dir(rom: bytes, off: int) -> tuple[list[RomfsEntry], int]:
    """Parse a packed TRomDir.  Returns (entries, end_offset)."""
    if off + 4 > len(rom):
        return [], off
    size = u32(rom, off)
    p = off + 4
    end = p + size
    if size == 0 or end > len(rom):
        return [], off
    out = []
    while p + 10 <= end:
        sz, addr = u32(rom, p), u32(rom, p + 4)
        attr, nlen = rom[p + 8], rom[p + 9]
        if nlen == 0 or nlen > 255 or p + 10 + 2 * nlen > end:
            break
        name = rom[p + 10:p + 10 + 2 * nlen].decode("utf-16le", "replace")
        out.append(RomfsEntry(name, sz, addr, attr))
        p += 10 + 2 * nlen
        p = (p + 3) & ~3
    return out, end


def parse_romfs(rom: bytes, root_off: int) -> list[RomfsEntry]:
    """Parse the first packed directory after the root list.

    This is the flat view used by `wd2.py list`: on the 6600 the 64 KiB block
    below the kernel starts with the `\\System\\Libs` directory (DLLs and
    resources).  The real ROMFS is a tree; see `find_boot_dirs` for the root
    directory, which is packed separately just below the kernel header.
    """
    count = u32(rom, root_off)
    entries: list[RomfsEntry] = []
    for i in range(count):
        addr = u32(rom, root_off + 4 + i * 8 + 4)
        off = root_off + 12 if i == 0 else None
        if off is None:
            # Locate the packed directory by its recorded runtime address.
            # The 6600 stores the first (and only) directory inline; a future
            # ROM may need a packed-offset table here.
            return entries
        es, _ = read_rom_dir(rom, off)
        entries.extend(es)
    return entries


# ---------------------------------------------------------------------------
# ROMFS directory tree
#
# The stored `iAddress` fields are *final-layout* addresses, while the packed
# bytes were written after the ROM build removed alignment gaps, so a single
# file-offset bias does not map the whole tree.  What is stable is the packed
# order: the big directory block below the kernel holds `\System` and its
# subdirectories, and the root directory is packed on its own, immediately
# before the kernel header.  We therefore locate directories by content (the
# set of names they contain) inside the packed block.
# ---------------------------------------------------------------------------

def find_dir_by_names(rom: bytes, lo: int, hi: int,
                      required: set[str]) -> tuple[int, list[RomfsEntry]]:
    """Find the packed TRomDir in [lo, hi) that contains all `required` names."""
    hi = min(hi, len(rom) - 8)
    for o in range(max(0, lo), hi, 2):
        size = u32(rom, o)
        if size < 0x10:
            continue
        es, end = read_rom_dir(rom, o)
        if not es or end > len(rom):
            continue
        names = {e.name.lower() for e in es}
        # Requiring the first entry to be one of the expected names rejects a
        # window that starts in the middle of a directory: those parse too,
        # but their first "entry" is a fragment of an earlier record.
        if required <= names and es[0].name.lower() in required:
            return o, es
    return -1, []


@dataclass
class BootDirs:
    root_list_off: int
    root_list_va: int
    root_off: int
    root_entries: list[RomfsEntry]
    system_off: int
    system_entries: list[RomfsEntry]
    libs_off: int
    libs_entries: list[RomfsEntry]
    programs_off: int
    programs_entries: list[RomfsEntry]


def find_boot_dirs(rom: bytes, root_off: int, root_va: int) -> BootDirs:
    """Recover the root, \\System, \\System\\Libs and \\System\\Programs dirs.

    The root list sits at `root_off` (file) / `root_va` (runtime).  The root
    directory itself is packed near the end of the directory block; `\\System`
    lists Libs/Programs/Apps/...; `\\System\\Libs` holds the shared DLLs and
    `\\System\\Programs` holds the boot executables (ekern.exe, ecust.dll, ...).
    """
    root_dir_off, root_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"system", "nokia"})
    system_off, system_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"libs", "programs", "data"})
    libs_off, libs_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"acmclasscontroller.dll",
                                            "httpclient.dll"})
    programs_off, programs_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"ekern.exe", "ecust.dll"})
    return BootDirs(root_off, root_va, root_dir_off, root_entries,
                    system_off, system_entries, libs_off, libs_entries,
                    programs_off, programs_entries)


def image_by_header_address(images: list[Image], va: int) -> Image | None:
    """Map a ROMFS entry address (which points at the image header) to its image."""
    for im in images:
        if im.code - 0x64 == va:
            return im
    return None



# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def snap_exports(rom: bytes, im: Image, edata: bytes) -> tuple[bytes, int]:
    """Bring-up aid: move export entries back to the ARM prologue.

    The packed image's export values point a few bytes into the callee (the
    ROM linker's interworking veneer is missing).  This mirrors the runtime's
    NK_CALL_INFER/NK_SNAP_ENTRY behaviour so a flat image can be tested.
    """
    text = rom[im.text.file_off:im.text.file_end]
    out = bytearray(edata)
    fixed = 0

    def rd32(va):
        o = va - im.code
        if 0 <= o <= len(text) - 4:
            return u32(text, o)
        return 0

    def term_before(va):
        w = rd32(va - 4)
        return (w in (0, 0xFFFFFFFF, 0xE12FFF1E, 0xE1A0F00E) or
                (w & 0xFFFF8000) == 0xE8BD8000 or
                (w & 0x0F000000) == 0x0A000000 or
                0x50000000 <= w < 0x81000000)

    def prologue(va):
        if va & 3:
            return False
        w = rd32(va)
        return ((w & 0xFFFF0000) == 0xE92D0000 or
                (w & 0xFFFFF000) == 0xE24DD000 or
                w == 0xE1A0C00D)

    for i in range(0, len(out), 4):
        v = u32(out, i)
        if not (im.code <= v < im.code + len(text)) or v & 3:
            continue
        if prologue(v) and term_before(v):
            continue
        for d in range(4, 0x21, 4):
            a = (v - d) & ~3
            if a < im.code + 4:
                break
            if prologue(a) and term_before(a):
                struct.pack_into("<I", out, i, a)
                fixed += 1
                break
    return bytes(out), fixed


def build_image(rom: bytes, images: list[Image], romfs: list[RomfsEntry],
                include_rodata: bool = False,
                do_snap: bool = True,
                romfs_linear: bool = False) -> tuple[bytes, list[str], list[Section]]:
    """Assemble a flat ROM at runtime addresses.  Returns (buf, warnings, placed).

    `images` is the set to place.  `cmd_build` passes every plausible image
    (the ROM's full code map), not just the kernel's direct DLL references:
    the 6600's boot loader and the window server need images that the kernel's
    TDllRefTable does not name, and their packed records are all present in
    the flash.  `--only-reachable` passes the old 3-image set instead.
    """
    buf = bytearray(ROM_SIZE)
    placed: list[Section] = []
    warnings: list[str] = []

    def put(va: int, data: bytes, name: str, file_off: int,
            overlay: bool = False):
        if va < ROM_BASE or va + len(data) > ROM_BASE + ROM_SIZE:
            warnings.append(f"{name}: {va:#x}+{len(data):#x} outside the 22 MiB ROM")
            return
        off = va - ROM_BASE
        old = bytes(buf[off:off + len(data)])
        if not overlay and any(old) and old != data:
            warnings.append(f"{name}: overwrites existing data at {va:#x}")
        buf[off:off + len(data)] = data
        placed.append(Section(name, file_off, len(data), va, overlay))


    # 1. boot area: the first 64 KiB are linear in the file
    boot_len = min(0x10000, len(rom))
    put(ROM_BASE, rom[:boot_len], "boot", 0)

    # 2. Every ROM image at its header addresses.  The 0x64-byte
    #    TRomImageHeader sits at code-0x64; header+text are contiguous in the
    #    packed record.  data/edata/dllref follow at their own runtime
    #    addresses.  The plain image placement is disjoint for this ROM (the
    #    text ranges, data, export dirs and DLL-ref tables do not overlap), so
    #    a clash here means a bogus header; report it instead of hiding it.
    for im in images:
        tag = f"uid3_{im.uid3:08x}"
        hdr_plus_text = rom[im.hdr_off:im.text.file_end]
        put(im.code - 0x64, hdr_plus_text, tag + "_hdr_text", im.hdr_off)
        for s in im.sections:
            if s.name == "text":
                continue
            data = rom[s.file_off:s.file_end]
            if do_snap and s.name == "edata":
                data, fixed = snap_exports(rom, im, data)
                if fixed:
                    warnings.append(
                        f"{tag}: snapped {fixed} export entries to their prologue "
                        f"(bring-up aid; the ROM linker's veneers are still missing)")
            put(s.va, data, f"{tag}_{s.name}", s.file_off)
        if include_rodata and im.rodata:
            # Experimental: treat the unaccounted block as text appended after
            # the declared text.  Data/edata/dllref and every later image would
            # then have to move; report the shift instead of silently
            # corrupting the map.
            warnings.append(
                f"{tag}: rodata {im.rodata.size:#x} at file {im.rodata.file_off:#x} "
                f"is not placed (use `scan` to inspect it)")

    # 3. ROMFS directory area.  The packed directory block below the kernel is
    #    stored in packed order; its first bytes map onto the ROM header's
    #    root_dir_list (0x50300000).  Copy that block, then overlay the two
    #    directories that live in a separately packed run next to the kernel
    #    header: the root directory and \System.  Their stored addresses are
    #    authoritative, and the packed bytes are found by content (see
    #    find_boot_dirs), because a single file<->VA bias does not cover the
    #    whole tree.
    hdr = find_rom_header(rom)
    root_off = find_romfs_root(rom, hdr["root_dir_list"])
    kernel = next(im for im in images if im.uid3 == UID_KERNEL)
    span = kernel.code - hdr["root_dir_list"]
    # The kernel's TRomImageHeader occupies the 0x64 bytes immediately before
    # the code; keep the directory blob below them so the two never collide.
    if span > 0x64:
        span -= 0x64
    if root_off is not None and 0 < span <= 0x100000:
        if root_off + span > len(rom):
            warnings.append(f"romfs: directory span {span:#x} runs past the file")
        else:
            put(hdr["root_dir_list"], rom[root_off:root_off + span],
                "romfs_dirs", root_off)
            if not parse_romfs(rom, root_off):
                warnings.append("romfs: directory block did not parse")
            dirs = find_boot_dirs(rom, root_off, hdr["root_dir_list"])

            def place_dir(off: int, va: int, name: str):
                if off < 0 or not va:
                    return
                blob = rom[off:off + 4 + u32(rom, off)]
                put(va, blob, name, off, overlay=True)

            # The stored addresses are authoritative.  The packed block above
            # is a compressed copy, so a linear copy puts \System\Libs at
            # 0x5030000c instead of its real 0x50301ec0; the overlay repairs
            # the directories the boot path needs.
            root_va = u32(rom, root_off + 8) if u32(rom, root_off) == 1 else 0
            system_va = next((e.addr for e in dirs.root_entries
                              if e.name.lower() == "system"), 0)
            libs_va = next((e.addr for e in dirs.system_entries
                            if e.name.lower() == "libs"), 0)
            programs_va = next((e.addr for e in dirs.system_entries
                                if e.name.lower() == "programs"), 0)
            place_dir(dirs.root_off, root_va, "romfs_root")
            place_dir(dirs.system_off, system_va, "romfs_system")
            place_dir(dirs.libs_off, libs_va, "romfs_libs")
            place_dir(dirs.programs_off, programs_va, "romfs_programs")
            if dirs.root_off < 0 or dirs.system_off < 0:
                warnings.append("romfs: root/System directory not located")
    elif root_off is not None:
        warnings.append(f"romfs: implausible directory span {span:#x}")

    # 4. ROMFS data files.  They are *not* stored at addr - ROM_BASE: the flash
    #    keeps them in packed FS order (0xff-padded, with a variable bias), so
    #    copying from the linear address splices unrelated code into the image.
    #    `romfs_linear` keeps the old behaviour for experiments only.
    if romfs_linear:
        for e in romfs:
            if e.attr & 0x10:
                continue
            foff = e.addr - ROM_BASE
            if foff < 0 or foff + e.size > len(rom):
                warnings.append(f"romfs: {e.name} at {e.addr:#x} outside the file")
                continue
            put(e.addr, rom[foff:foff + e.size], f"romfs_{e.name}", foff)
    elif romfs:
        warnings.append(
            f"romfs: {sum(1 for e in romfs if not e.attr & 0x10)} data files are "
            f"packed in the FS area, not at addr-{ROM_BASE:#x}; not placed")

    return bytes(buf), warnings, placed



# ---------------------------------------------------------------------------
# bring-up text patches
# ---------------------------------------------------------------------------

def load_patches(path: str) -> list[tuple[int, bytes, str]]:
    """Read `<va> <hex bytes>  # comment` lines.

    The packed image is missing the tail of at least one Thumb function (the
    bytes at 0x5039adcc are data, not `pop {r4,r7,pc}`).  Patching the flat
    image is a bring-up aid: it lets the caller return instead of running into
    the following data.  Patches are kept in config/ and are never applied
    silently.
    """
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 2:
                raise SystemExit(f"{path}:{lineno}: expected <va> <hex bytes>")
            va = int(parts[0], 0)
            data = bytes.fromhex(parts[1])
            out.append((va, data, line))
    return out


def apply_patches(buf: bytearray, patches: list[tuple[int, bytes, str]]) -> list[str]:
    warnings = []
    for va, data, line in patches:
        if va < ROM_BASE or va + len(data) > ROM_BASE + len(buf):
            warnings.append(f"patch outside the ROM: {line}")
            continue
        off = va - ROM_BASE
        buf[off:off + len(data)] = data
        warnings.append(f"patched {va:#010x} ({len(data)} bytes): {line}")
    return warnings


# ---------------------------------------------------------------------------
# call-site report
# ---------------------------------------------------------------------------

def call_report(rom: bytes, im: Image, limit: int = 24) -> dict:
    """Classify direct ARM BL sites in one image.

    ARMv4T has no immediate BLX, so a Thumb->ARM call needs a linker veneer.
    This report counts the ARM BLs that do / do not land on a plausible
    function start, and records the backward distance to the nearest one.
    It is a diagnostic for the missing ROM-build pass, not a linker.
    """
    text = rom[im.text.file_off:im.text.file_end]
    code = im.code

    def rd32(va):
        o = va - code
        if 0 <= o <= len(text) - 4:
            return u32(text, o)
        return 0

    def terminator_before(va):
        w = rd32(va - 4)
        if w in (0, 0xFFFFFFFF, 0xE12FFF1E, 0xE1A0F00E):
            return True
        if (w & 0xFFFF8000) == 0xE8BD8000:       # pop {...,pc}
            return True
        if (w & 0x0F000000) == 0x0A000000:       # b
            return True
        if 0x50000000 <= w < 0x81000000:         # literal/pointer
            return True
        return False

    def prologue_at(va):
        if va & 3 or va < code + 4 or va + 4 > code + len(text):
            return False
        w = rd32(va)
        return ((w & 0xFFFF0000) == 0xE92D0000 or
                (w & 0xFFFFF000) == 0xE24DD000 or
                w == 0xE1A0C00D)

    exact = biased = unknown = 0
    biases = {}
    samples = []
    for off in range(0, len(text) - 4, 4):
        w = u32(text, off)
        if (w & 0x0F000000) != 0x0B000000 or (w >> 28) == 0xF:
            continue
        rel = w & 0x00FFFFFF
        if rel & 0x00800000:
            rel -= 0x01000000
        target = code + off + 8 + (rel << 2)
        if not (code <= target < code + len(text)):
            continue
        if prologue_at(target) and terminator_before(target):
            exact += 1
            continue
        hit = None
        for d in range(4, 0x401, 4):
            a = (target - d) & ~3
            if a < code + 4:
                break
            if prologue_at(a) and terminator_before(a):
                hit = d
                break
        if hit is not None:
            biased += 1
            biases[hit] = biases.get(hit, 0) + 1
            if len(samples) < limit:
                samples.append({"site": code + off, "target": target,
                                "entry": (target - hit) & ~3, "bias": hit})
        else:
            unknown += 1
    return {
        "uid3": im.uid3,
        "text": hex(im.text.va),
        "text_size": hex(im.text.size),
        "exact_entry": exact,
        "biased_entry": biased,
        "unknown": unknown,
        "bias_histogram": {hex(k): v for k, v in sorted(biases.items())},
        "samples": samples,
    }


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_scan(a):
    rom = open(a.rom, "rb").read()
    hdr = find_rom_header(rom)
    images = scan_images(rom)
    good = plausible_images(images)
    reach = reachable_images(images)
    print(f"ROM {len(rom):#x} bytes, header @ {hdr['header_offset']:#x}, "
          f"base {hdr['rom_base']:#x}, size {hdr['rom_size']:#x}")
    print(f"images: {len(images)} header candidates ({len(good)} plausible, "
          f"{len(images) - len(good)} rejected), {len(reach)} reachable from "
          f"the kernel")
    span_lo = min(im.code - 0x64 for im in good)
    span_hi = max(im.code + im.text_size for im in good)
    print(f"  code map: {len(good)} images at {span_lo:#010x}..{span_hi:#010x} "
          f"({sum(im.text_size for im in good):#x} bytes of text)")
    for im in reach:
        print(f"\nuid3 {im.uid3:#010x}  file {im.hdr_off:#08x}  "
              f"code {im.code:#010x}  entry {im.entry:#010x}")
        for s in im.sections:
            print(f"  {s.name:7} file {s.file_off:#08x}  size {s.size:#08x}  "
                  f"va {s.va:#010x}")
        if im.rodata:
            print(f"  rodata  file {im.rodata.file_off:#08x}  "
                  f"size {im.rodata.size:#08x}  (not described by the header)")
        print(f"  bss {im.bss_size:#x} @ RAM {im.databss:#010x}  "
              f"flags {im.flags:#x}  dllrefs {[hex(x) for x in im.dllrefs]}")
        for e in im.errors:
            print(f"  ! {e}")
    root = find_romfs_root(rom, hdr["root_dir_list"])
    if root is None:
        print("\nROMFS: root list not found")
        return
    entries = parse_romfs(rom, root)
    files = [e for e in entries if not e.attr & 0x10]
    print(f"\nROMFS: root list @ file {root:#x} (va {hdr['root_dir_list']:#x}), "
          f"{len(entries)} entries ({len(files)} files) in the first directory")
    dirs = find_boot_dirs(rom, root, hdr["root_dir_list"])
    def show(name, off, es):
        va = next((e.addr for e in es if e.name.lower() == name), 0)
        print(f"  {name:10} file {off:#08x}  {len(es):3d} entries"
              + (f"  va {va:#010x}" if va else ""))
    show("root", dirs.root_off, dirs.root_entries)
    show("system", dirs.system_off, dirs.system_entries)
    show("libs", dirs.libs_off, dirs.libs_entries)
    show("programs", dirs.programs_off, dirs.programs_entries)
    by_hdr = {im.code - 0x64: im for im in good}
    for es in (dirs.programs_entries, dirs.libs_entries):
        for e in es:
            if e.name.lower() in ("ekern.exe", "ecust.dll", "cbus.dll",
                                  "helper.ldd", "euser.dll"):
                im = by_hdr.get(e.addr)
                if im:
                    print(f"  {e.name} -> uid3 {im.uid3:#010x}, "
                          f"code {im.code:#010x}, packed file {im.hdr_off:#x}")
    print(f"  image records named by ROMFS: "
          f"{sum(1 for es in (dirs.libs_entries,) for e in es if e.addr in by_hdr)}"
          f"/{len(dirs.libs_entries)} in \\System\\Libs, "
          f"{sum(1 for e in dirs.programs_entries if e.addr in by_hdr)}"
          f"/{len(dirs.programs_entries)} in \\System\\Programs")
    print("  note: file data is packed in FS order, not at addr - ROM_BASE")
    if a.json:
        payload = {
            "rom_header": hdr,
            "images": [asdict(im) for im in images],
            "plausible": [im.uid3 for im in good],
            "reachable": [im.uid3 for im in reach],
            "romfs": {"root_file_off": root,
                      "entries": [asdict(e) for e in entries],
                      "root_dir_file_off": dirs.root_off,
                      "system_dir_file_off": dirs.system_off,
                      "libs_dir_file_off": dirs.libs_off},
        }
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    hdr = find_rom_header(rom)
    images = scan_images(rom)
    good = plausible_images(images)
    reach = reachable_images(images)
    place = reach if a.only_reachable else good
    root = find_romfs_root(rom, hdr["root_dir_list"])
    romfs = parse_romfs(rom, root) if root is not None else []
    buf, warnings, placed = build_image(rom, place, romfs, a.include_rodata,
                                        do_snap=not a.no_snap,
                                        romfs_linear=a.romfs_linear)
    patches = load_patches(a.patch) if a.patch else []
    if patches:
        buf = bytearray(buf)
        warnings.extend(apply_patches(buf, patches))
        buf = bytes(buf)
    open(a.output, "wb").write(buf)
    print(f"wrote {a.output}: {len(buf):#x} bytes at {ROM_BASE:#x}")
    print(f"  {len(placed)} sections from {len(place)} images, "
          f"{len(romfs)} ROMFS entries")
    for w in warnings[:40]:
        print(f"  ! {w}")
    if len(warnings) > 40:
        print(f"  ! ... {len(warnings) - 40} more warnings")
    kernel = next(im for im in reach if im.uid3 == UID_KERNEL)
    print(f"  kernel entry {kernel.entry:#010x}")
    if a.json:
        payload = {
            "rom_header": hdr,
            "images": [asdict(im) for im in place],
            "placed": [asdict(s) for s in placed],
            "patches": [{"va": va, "bytes": data.hex(), "line": line}
                        for va, data, line in patches],
            "warnings": warnings,
            "mode": ("reachable" if a.only_reachable else "all-images"),
        }
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


def cmd_names(a):
    """Map ROMFS image names to packed records (the boot-file table)."""
    rom = open(a.rom, "rb").read()
    hdr = find_rom_header(rom)
    good = plausible_images(scan_images(rom))
    by_hdr = {im.code - 0x64: im for im in good}
    root = find_romfs_root(rom, hdr["root_dir_list"])
    if root is None:
        raise SystemExit("ROMFS root list not found")
    dirs = find_boot_dirs(rom, root, hdr["root_dir_list"])

    def dump(path, es):
        for e in es:
            # The packed Programs directory has one entry whose tail was
            # overwritten by following data (the name ends in a space and the
            # next record is code bytes); skip entries that cannot be real.
            if (not e.name or
                    any(ord(c) < 32 or ord(c) > 126 for c in e.name) or
                    not (ROM_BASE <= e.addr < ROM_BASE + ROM_SIZE) or
                    e.size > 0x1000000):
                continue
            p = path + "\\" + e.name
            kind = "dir " if e.attr & 0x10 else "file"
            im = by_hdr.get(e.addr)
            tail = ""
            if im is not None:
                tail = (f"  -> uid3 {im.uid3:#010x} code {im.code:#010x} "
                        f"packed {im.hdr_off:#08x}")
            print(f"  {kind} {p:44s} {e.size:#08x} @ {e.addr:#010x}{tail}")

    if dirs.root_off < 0:
        raise SystemExit("packed root directory not located")
    print(f"root directory: file {dirs.root_off:#x}, "
          f"{len(dirs.root_entries)} entries")
    dump("", dirs.root_entries)
    if dirs.system_off >= 0:
        print(f"\n\\System: file {dirs.system_off:#x}, "
              f"{len(dirs.system_entries)} entries")
        dump("\\System", dirs.system_entries)
    if dirs.programs_off >= 0:
        print(f"\n\\System\\Programs: file {dirs.programs_off:#x}, "
              f"{len(dirs.programs_entries)} entries")
        dump("\\System\\Programs", dirs.programs_entries)
    if a.all and dirs.libs_off >= 0:
        print(f"\n\\System\\Libs: file {dirs.libs_off:#x}, "
              f"{len(dirs.libs_entries)} entries")
        dump("\\System\\Libs", dirs.libs_entries)
        mapped = sum(1 for e in dirs.libs_entries if e.addr in by_hdr)
        print(f"  ({mapped}/{len(dirs.libs_entries)} entries map to packed images)")




def cmd_calls(a):
    rom = open(a.rom, "rb").read()
    images = scan_images(rom)
    reach = reachable_images(images)
    for im in reach:
        rep = call_report(rom, im)
        total = rep["exact_entry"] + rep["biased_entry"] + rep["unknown"]
        print(f"\nuid3 {im.uid3:#010x}: {total} direct ARM BL sites")
        print(f"  exact function entry : {rep['exact_entry']}")
        print(f"  biased into callee   : {rep['biased_entry']}")
        print(f"  no nearby entry      : {rep['unknown']}")
        top = sorted(rep["bias_histogram"].items(), key=lambda kv: -kv[1])[:8]
        print(f"  common biases        : "
              + ", ".join(f"{k} x{v}" for k, v in top))
        for s in rep["samples"][:a.limit]:
            print(f"    {s['site']:#010x} -> {s['target']:#010x}  "
                  f"(entry {s['entry']:#010x}, +{s['bias']:#x})")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan")
    s.add_argument("rom")
    s.add_argument("--json")
    s.set_defaults(func=cmd_scan)

    b = sub.add_parser("build")
    b.add_argument("rom")
    b.add_argument("output")
    b.add_argument("--json")
    b.add_argument("--include-rodata", action="store_true",
                   help="report (do not place) the header-less rodata block")
    b.add_argument("--no-snap", action="store_true",
                   help="keep raw export values instead of snapping them to "
                        "the enclosing function prologue (bring-up aid)")
    b.add_argument("--patch",
                   help="apply bring-up text patches from this file "
                        "('<va> <hex bytes>' per line)")
    b.add_argument("--only-reachable", action="store_true",
                   help="place only the kernel + its direct DLL references "
                        "(the old 3-image behaviour); default places every "
                        "plausible image found in the flash")
    b.add_argument("--romfs-linear",
                   action="store_true",
                   help="also copy ROMFS data files from addr - ROM_BASE "
                        "(unverified: the flash stores them in packed FS order)")
    b.set_defaults(func=cmd_build)

    c = sub.add_parser("calls")
    c.add_argument("rom")
    c.add_argument("--limit", type=int, default=8)
    c.set_defaults(func=cmd_calls)

    n = sub.add_parser("names")
    n.add_argument("rom")
    n.add_argument("--all", action="store_true",
                   help="also dump \\System\\Libs")
    n.set_defaults(func=cmd_names)

    a = ap.parse_args()
    a.func(a)



if __name__ == "__main__":
    main()
