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
flash itself is paged as `0x20ec`-byte records (`0xec` header + `0x2000`
payload); `pagestream.py` removes the headers and all offsets in this module
are **packed-stream** offsets unless explicitly called "raw".  The runtime
layout is simple:

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

import pagestream

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


def load_packed(path: str) -> bytes:
    """Read a flash image and return its page-header-free packed stream."""
    return pagestream.build(open(path, "rb").read())


def packed(rom: bytes) -> bytes:
    """Return `rom` as a page-header-free packed stream (idempotent)."""
    return pagestream.build(rom)


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
            "entry": u32(rom, base + 0x08),   # legacy alias: iTimeHi, not an entry
            "time_lo": u32(rom, base + 0x04),
            "time_hi": u32(rom, base + 0x08),
            "rom_base": u32(rom, base + 0x0C),
            "rom_size": u32(rom, base + 0x10),
            "root_dir_list": u32(rom, base + 0x14),
            "kern_data": u32(rom, base + 0x18),
            "kern_limit": u32(rom, base + 0x1C),
            "primary_file": u32(rom, base + 0x20),
            "secondary_file": u32(rom, base + 0x24),
            "checksum2": u32(rom, base + 0x28),
            "variant_file": u32(rom, base + 0x4c),
            "extension_file": u32(rom, base + 0x50),
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

    # Packed-stream fallback.  In the deinterleaved view the directory block
    # no longer sits at the raw `+0x162b0` bias.  Locate the first (large)
    # \System\Libs directory by its first entry name; the root, \System and
    # \System\Programs directories are then found by content from there.
    needle = "AcmClassController.dll".encode("utf-16le")
    pos = rom.find(needle)
    while pos >= 0:
        off = pos - 14                    # TRomDir + entry header
        if off >= 0:
            d = read_rom_dir_full(rom, off)
            if len(d.entries) >= 100:
                # A TRomRootDirectoryList (12 bytes: count + one address)
                # normally precedes the TRomDir.  The runtime root pointer
                # refers to this list, and build_image copies the whole
                # block from it.
                root = off - 12
                if (root >= 0 and 1 <= u32(rom, root) <= 8 and
                        ROM_BASE <= u32(rom, root + 8) < ROM_BASE + ROM_SIZE):
                    return root
                return off
        pos = rom.find(needle, pos + 1)
    return None


@dataclass
class RomfsEntry:
    name: str
    size: int
    addr: int
    attr: int


@dataclass
class RomDir:
    """One packed TRomDir plus how much of its declared size is usable.

    The 6600 flash is a *packed* image: after the last valid entry of
    \\System\\Programs the next image record's code begins, although the
    directory's `iSize` still claims several kilobytes.  Treating the bytes
    that follow as directory entries produces garbage names and absurd
    addresses (and can consume the following image).  Keep the truncation
    explicit so callers can report it instead of inventing entries.
    """

    entries: list[RomfsEntry]
    off: int
    end: int                 # declared end: off + 4 + iSize
    parsed_end: int          # first byte after the last valid entry
    truncated: bool

    @property
    def missing(self) -> int:
        return max(0, self.end - self.parsed_end)


def _romfs_entry_ok(sz: int, addr: int, attr: int, name: str) -> bool:
    """Reject the bytes that follow a truncated directory.

    A real entry is an ASCII file/directory name and a runtime address in the
    ROM window.  The packed record that overwrites the directory tail fails
    both tests immediately.
    """
    if not name or len(name) > 200:
        return False
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in name):
        return False
    if not (ROM_BASE <= addr < ROM_BASE + ROM_SIZE):
        return False
    if sz > 0x04000000:
        return False
    return True


def read_rom_dir_full(rom: bytes, off: int) -> RomDir:
    """Parse a packed TRomDir and report whether its tail is present."""
    if off < 0 or off + 4 > len(rom):
        return RomDir([], off, off, off, True)
    size = u32(rom, off)
    p = off + 4
    end = p + size
    if size == 0 or end > len(rom):
        return RomDir([], off, min(end, len(rom)), p, True)
    out: list[RomfsEntry] = []
    last = p
    while p + 10 <= end:
        sz, addr = u32(rom, p), u32(rom, p + 4)
        attr, nlen = rom[p + 8], rom[p + 9]
        if nlen == 0 or nlen > 200 or p + 10 + 2 * nlen > end:
            break
        name = rom[p + 10:p + 10 + 2 * nlen].decode("utf-16le", "replace")
        if not _romfs_entry_ok(sz, addr, attr, name):
            break
        out.append(RomfsEntry(name, sz, addr, attr))
        p += 10 + 2 * nlen
        p = (p + 3) & ~3
        last = p
    return RomDir(out, off, end, last, last < end)


def read_rom_dir(rom: bytes, off: int) -> tuple[list[RomfsEntry], int]:
    """Backwards-compatible wrapper around read_rom_dir_full()."""
    d = read_rom_dir_full(rom, off)
    return d.entries, d.end


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
    plugins_off: int = -1
    plugins_entries: list[RomfsEntry] | None = None
    root_dir: RomDir | None = None
    system_dir: RomDir | None = None
    libs_dir: RomDir | None = None
    programs_dir: RomDir | None = None
    plugins_dir: RomDir | None = None

    def dir_reports(self) -> list[tuple[str, RomDir | None]]:
        return [("root", self.root_dir), ("\\System", self.system_dir),
                ("\\System\\Libs", self.libs_dir),
                ("\\System\\Programs", self.programs_dir),
                ("\\System\\Libs\\Plugins", self.plugins_dir)]

    def dirs_by_va(self) -> list[tuple[str, int, int]]:
        """(name, stored VA, packed file offset) for every \\System subdir.

        The packed stream keeps every directory at its *runtime* VA when the
        block below the kernel is read linearly from the root list.  This
        walks the parent's address fields and turns each into the matching
        packed offset, so callers can verify the layout instead of guessing.
        """
        out: list[tuple[str, int, int]] = []
        for e in self.system_entries:
            if not (e.attr & 0x10):
                continue
            out.append((e.name, e.addr,
                        self.root_list_off + (e.addr - self.root_list_va)))
        return out

    def truncation_warnings(self) -> list[str]:
        out = []
        for name, d in self.dir_reports():
            if d is not None and d.truncated:
                out.append(
                    f"romfs: {name} directory declares {d.end - d.off - 4:#x} "
                    f"bytes but only {d.parsed_end - d.off - 4:#x} are present "
                    f"({d.missing:#x} bytes overwritten by the next packed "
                    f"record); {len(d.entries)} valid entries")
        return out


def find_boot_dirs(rom: bytes, root_off: int, root_va: int) -> BootDirs:
    r"""Recover the root, \System, \System\Libs and \System\Programs dirs.

    The root list sits at `root_off` (file) / `root_va` (runtime).  The root
    directory itself is packed near the end of the directory block; `\System`
    lists Libs/Programs/Apps/...

    The names must be matched by *content*, not by position: round 19 proved
    that the large directory packed first below the kernel is `\System\Libs`
    (586 entries, starting with `ekern.exe`/`ecust.dll`), not Programs.
    `\System\Programs` is the 55-entry server list (`BTTestServer.exe`, ...),
    and the 171-entry list of `AcmClassController.dll` is `\System\Libs\Plugins`.
    """
    root_dir_off, root_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"system", "nokia"})
    system_off, system_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"libs", "programs", "data"})
    libs_off, libs_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"ekern.exe", "ecust.dll",
                                            "euser.dll"})
    programs_off, programs_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"bttestserver.exe",
                                            "shareddataserver.exe"})
    plugins_off, plugins_entries = find_dir_by_names(
        rom, root_off, root_off + 0x30000, {"acmclasscontroller.dll",
                                            "httpclient.dll"})
    return BootDirs(root_off, root_va, root_dir_off, root_entries,
                    system_off, system_entries, libs_off, libs_entries,
                    programs_off, programs_entries,
                    plugins_off=plugins_off, plugins_entries=plugins_entries,
                    root_dir=read_rom_dir_full(rom, root_dir_off)
                    if root_dir_off >= 0 else None,
                    system_dir=read_rom_dir_full(rom, system_off)
                    if system_off >= 0 else None,
                    libs_dir=read_rom_dir_full(rom, libs_off)
                    if libs_off >= 0 else None,
                    programs_dir=read_rom_dir_full(rom, programs_off)
                    if programs_off >= 0 else None,
                    plugins_dir=read_rom_dir_full(rom, plugins_off)
                    if plugins_off >= 0 else None)


def image_by_header_address(images: list[Image], va: int) -> Image | None:
    """Map a ROMFS entry address (which points at the image header) to its image."""
    for im in images:
        if im.code - 0x64 == va:
            return im
    return None


def scan_e32_files(rom: bytes) -> dict[int, int]:
    """Map ROMFS file runtime addresses to packed E32Image file offsets.

    Besides the ROM image records (TRomImageHeader) the flash also stores
    plain E32Image *files* for the applications.  Their header layout starts
    with the same UID1/UID2/UID3 words and `iCodeAddress = file_addr + 0x64`;
    the ROMFS directory entry for `<App>.app` points at that header.  A
    TRomImageHeader-only scan misses them because they are not followed by a
    record boundary.  This loose scan recovers the 63 application binaries
    (SnakeEx.app, mixpix.app, ...) without treating arbitrary data as code.
    """
    out: dict[int, int] = {}
    for o in range(0, len(rom) - 0x64, 2):
        uid1 = u32(rom, o)
        if uid1 not in (UID_EXE, UID_DLL):
            continue
        (uid2, uid3, uidc, entry, code, data, csize, tsize, dsize,
         bss) = struct.unpack_from("<10I", rom, o + 4)
        if not (ROM_BASE <= code < ROM_BASE + ROM_SIZE):
            continue
        if csize == 0 or csize > 0x400000 or tsize > csize:
            continue
        if dsize > 0x100000 or bss > 0x100000:
            continue
        out.setdefault(code - 0x64, o)
    return out


def find_app_companions(rom: bytes, root_off: int,
                        e32: dict[int, int]) -> list[tuple[RomfsEntry, int]]:
    """Locate the AIF and MBM companions stored in each app's packed run.

    The packed app records are `[<App>.app E32Image][AIF][MBM]...`, in the
    same order as the runtime addresses.  The AIF and MBM files start with a
    0xff/zero prefix and a well-known UID; scanning for that UID inside the
    app's run recovers them without a full E32 header parser.  The `.r01`
    resources live in the separate compressed data area and are not handled
    here.
    """
    tree = read_app_tree(rom, root_off)
    if tree is None:
        return []
    apps: list[tuple[int, RomDir]] = []
    for d in tree.apps.values():
        app = next((e for e in d.entries if e.name.lower().endswith(".app")), None)
        if app is None:
            continue
        foff = e32.get(app.addr)
        if foff is not None:
            apps.append((foff, d))
    apps.sort(key=lambda t: t[0])
    out: list[tuple[RomfsEntry, int]] = []
    for i, (foff, d) in enumerate(apps):
        end = apps[i + 1][0] if i + 1 < len(apps) else min(len(rom), foff + 0x200000)
        for e in d.entries:
            low = e.name.lower()
            if low.endswith(".aif"):
                uid = b"\x32\xb0\x1f\x10"
                prefix = 0x0A
            elif low.endswith(".mbm"):
                uid = b"\x41\x00\x00\x10"
                prefix = 0x10
            else:
                continue
            pos = rom.find(uid, foff, end)
            if pos < 0 or pos < prefix:
                continue
            start = pos - prefix
            if start + e.size > end and i + 1 < len(apps):
                continue
            if start + e.size > len(rom):
                continue
            out.append((e, start))
    return out


def collect_romfs_files(rom: bytes, root_off: int) -> list[tuple[RomfsEntry, bool]]:
    """All file entries we can name: Libs, Programs and the app tree.

    The boolean marks an app-tree entry: `<App>.app` files are plain
    E32Image files and must be copied whole, even when their header also
    looks like a ROM image record.
    """
    hdr = find_rom_header(rom)
    dirs = find_boot_dirs(rom, root_off, hdr["root_dir_list"])
    out: list[tuple[RomfsEntry, bool]] = []
    seen: set[tuple[str, int, int]] = set()

    def add(entries: list[RomfsEntry], is_app: bool):
        for e in entries:
            if e.attr & 0x10 or not e.size:
                continue
            key = (e.name.lower(), e.addr, e.size)
            if key in seen:
                continue
            seen.add(key)
            out.append((e, is_app))

    add(dirs.libs_entries, False)
    add(dirs.programs_entries, False)
    if dirs.plugins_entries:
        add(dirs.plugins_entries, False)
    tree = read_app_tree(rom, root_off)
    if tree is not None:
        for d in tree.apps.values():
            add(d.entries, True)
    return out


# ---------------------------------------------------------------------------
# application tree
#
# The packed 64 KiB block below the kernel contains the whole ROMFS directory
# tree, not just t\System\Libs / Programs.  Directory records are not ordered
# by runtime address in the file, so the tree is recovered by content:
# \System\Apps is the only directory whose entries are all subdirectories, and
# each app directory is the small directory holding "<App>.app".  This makes
# the S60 2nd Edition app list (including SnakeEx and MixPix) enumerable even
# though the Programs directory tail is overwritten.
# ---------------------------------------------------------------------------

def find_dir_candidates(rom: bytes, lo: int, hi: int,
                        max_size: int = 0x4000) -> list[RomDir]:
    """Every validated TRomDir in [lo, hi).  Truncated tails are kept: the
    parsed prefix is still enough to identify an app directory."""
    out: list[RomDir] = []
    hi = min(hi, len(rom) - 8)
    for o in range(max(0, lo), hi, 2):
        d = read_rom_dir_full(rom, o)
        if len(d.entries) < 2:
            continue
        if d.end - d.off - 4 > max_size:
            continue
        out.append(d)
    return out


def find_apps_dir(cands: list[RomDir]) -> RomDir | None:
    """The \\System\\Apps directory: many entries, all subdirectories."""
    best = None
    for d in cands:
        if len(d.entries) < 10:
            continue
        if not all(e.attr & 0x10 for e in d.entries):
            continue
        if best is None or len(d.entries) > len(best.entries):
            best = d
    return best


def find_app_dir(cands: list[RomDir], app: str,
                 used: set[int]) -> RomDir | None:
    """Find the packed directory that holds `<app>.app`, `<app>.aif`, ..."""
    want = (app + ".app").lower()
    hits = []
    for d in cands:
        if d.off in used or len(d.entries) > 24:
            continue
        names = [e.name.lower() for e in d.entries]
        if want not in names:
            continue
        # prefer a directory whose first entry carries the app name (the
        # About/SnakeEx/... layout) and that has the fewest unrelated names
        prefix = d.entries[0].name.lower().startswith(app.lower())
        hits.append((0 if prefix else 1, len(d.entries), d))
    if not hits:
        return None
    hits.sort(key=lambda t: (t[0], t[1]))
    return hits[0][2]


@dataclass
class AppTree:
    apps_dir: RomDir
    apps: dict[str, RomDir]


def read_app_tree(rom: bytes, romfs_root: int) -> AppTree | None:
    cands = find_dir_candidates(rom, romfs_root, romfs_root + 0x30000)
    apps_dir = find_apps_dir(cands)
    if apps_dir is None:
        return None
    used = {apps_dir.off}
    apps: dict[str, RomDir] = {}
    for e in apps_dir.entries:
        d = find_app_dir(cands, e.name, used)
        if d is not None:
            apps[e.name] = d
            used.add(d.off)
    return AppTree(apps_dir, apps)




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
    #    stored *at its runtime addresses*: reading it linearly from the root
    #    list puts the root list at 0x50300000, \System\Libs\Plugins at
    #    0x5030000c, \System\Libs at 0x50301ec0, \System\Programs at
    #    0x50307964, and so on.  Round 19 found that an older build overlaid
    #    \System\Libs with the Plugins content (the 171-entry directory) and
    #    Programs with the Libs content, which destroyed the TRomEntry records
    #    the ROM header's iPrimaryFile/iSecondaryFile/iVariantFile/
    #    iExtensionFile point at (the kernel's boot loader reads them at
    #    0x500000c4..0x500000cc).  The linear copy is now authoritative; each
    #    \System subdirectory is verified in place instead of relocated.
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
            warnings.extend(dirs.truncation_warnings())

            # Fallback only: if a directory is not where its parent's address
            # says it is (a differently packed view), relocate it by content.
            known = {
                "libs": dirs.libs_off,
                "programs": dirs.programs_off,
                "plugins": dirs.plugins_off,
            }
            for name, va, off in dirs.dirs_by_va():
                if read_rom_dir_full(rom, off).entries:
                    continue
                src = known.get(name.lower(), -1)
                if src >= 0:
                    blob = rom[src:src + 4 + u32(rom, src)]
                    put(va, blob, f"romfs_{name}", src, overlay=True)
                    warnings.append(
                        f"romfs: {name} was packed away from its runtime VA "
                        f"{va:#x}; relocated by content")
                else:
                    warnings.append(
                        f"romfs: {name} at {va:#x} does not parse "
                        f"(packed offset {off:#x})")
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

    # 5. ROMFS E32Image files (the applications).  `<App>.app` entries point
    #    at a plain E32Image file header whose `iCodeAddress` is
    #    `entry_addr + 0x64`; the packed bytes are contiguous from that file
    #    offset.  The ROM-image entries are already placed by their sections
    #    above, so only the non-image headers are copied here.
    if not romfs_linear and root_off is not None:
        e32 = scan_e32_files(rom)
        image_hdrs = {im.code - 0x64 for im in images}

        def overlap(va: int, size: int) -> str | None:
            for p in placed:
                if p.overlay:
                    continue
                if p.va < va + size and va < p.va + p.size:
                    return p.name
            return None

        for e, is_app in collect_romfs_files(rom, root_off):
            if not is_app and e.addr in image_hdrs:
                continue
            foff = e32.get(e.addr)
            if foff is None:
                continue
            if foff + e.size > len(rom):
                warnings.append(f"romfs: {e.name} E32 file at {foff:#x} "
                                f"runs past the flash")
                continue
            if not is_app:
                clash = overlap(e.addr, e.size)
                if clash:
                    warnings.append(
                        f"romfs: {e.name} E32 file at {e.addr:#x} overlaps "
                        f"{clash}; skipped (loaded later by the file server)")
                    continue
            put(e.addr, rom[foff:foff + e.size], f"romfs_e32_{e.name}", foff,
                overlay=is_app)

        for e, foff in find_app_companions(rom, root_off, e32):
            if foff + e.size > len(rom):
                continue
            put(e.addr, rom[foff:foff + e.size], f"romfs_data_{e.name}", foff,
                overlay=True)

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
    rom = load_packed(a.rom)
    hdr = find_rom_header(rom)
    images = scan_images(rom)
    good = plausible_images(images)
    reach = reachable_images(images)
    print(f"packed stream {len(rom):#x} bytes (page headers removed), "
          f"header @ {hdr['header_offset']:#x}, base {hdr['rom_base']:#x}, "
          f"rom_size {hdr['rom_size']:#x}")
    print(f"images: {len(images)} header candidates ({len(good)} plausible, "
          f"{len(images) - len(good)} rejected), {len(reach)} reachable from "
          f"the kernel")
    span_lo = min(im.code - 0x64 for im in good)
    span_hi = max(im.code + im.text_size for im in good)
    print(f"  code map: {len(good)} images at {span_lo:#010x}..{span_hi:#010x} "
          f"({sum(im.text_size for im in good):#x} bytes of text)")
    for im in reach:
        print(f"\nuid3 {im.uid3:#010x}  stream {im.hdr_off:#08x}  "
              f"code {im.code:#010x}  entry {im.entry:#010x}")
        for s in im.sections:
            print(f"  {s.name:7} stream {s.file_off:#08x}  size {s.size:#08x}  "
                  f"va {s.va:#010x}")
        if im.rodata:
            print(f"  rodata  stream {im.rodata.file_off:#08x}  "
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
    for w in dirs.truncation_warnings():
        print(f"  ! {w}")
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
                      "libs_dir_file_off": dirs.libs_off,
                      "programs_dir_file_off": dirs.programs_off,
                      "plugins_dir_file_off": dirs.plugins_off},
        }
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


def cmd_build(a):
    rom = load_packed(a.rom)
    hdr = find_rom_header(rom)
    images = scan_images(rom)
    good = plausible_images(images)
    reach = reachable_images(images)
    place = reach if a.only_reachable else good
    root = find_romfs_root(rom, hdr["root_dir_list"])
    romfs = parse_romfs(rom, root) if root is not None else []
    dirs = find_boot_dirs(rom, root, hdr["root_dir_list"]) if root is not None else None
    # Snapping was a bring-up aid for the misaligned packed text.  The
    # page-header-free stream now matches the export table at ~98%, so keep
    # the raw export addresses unless --snap is requested explicitly.
    buf, warnings, placed = build_image(rom, place, romfs, a.include_rodata,
                                        do_snap=a.snap,
                                        romfs_linear=a.romfs_linear)
    patches = load_patches(a.patch) if a.patch else []
    if patches:
        buf = bytearray(buf)
        warnings.extend(apply_patches(buf, patches))
        buf = bytes(buf)
    open(a.output, "wb").write(buf)
    print(f"wrote {a.output}: {len(buf):#x} bytes at {ROM_BASE:#x}")
    print(f"  {len(placed)} sections from {len(place)} images")
    if dirs is not None:
        print(f"  ROMFS: \\System\\Libs {len(dirs.libs_entries)} entries, "
              f"\\System\\Programs {len(dirs.programs_entries)}, "
              f"Plugins {len(dirs.plugins_entries or [])}")
    e32n = sum(1 for s in placed if s.name.startswith("romfs_e32_"))
    if e32n:
        print(f"  ROMFS E32Image files: {e32n} placed at their runtime addresses")
    datan = sum(1 for s in placed if s.name.startswith("romfs_data_"))
    if datan:
        print(f"  ROMFS app companions: {datan} AIF/MBM files placed")
    for w in warnings[:40]:
        print(f"  ! {w}")
    if len(warnings) > 40:
        print(f"  ! ... {len(warnings) - 40} more warnings")
    kernel = next(im for im in reach if im.uid3 == UID_KERNEL)
    print(f"  kernel entry {kernel.entry:#010x}")
    if a.json:
        payload = {
            "source": "page-header-free packed stream",
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
    rom = load_packed(a.rom)
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
    for w in dirs.truncation_warnings():
        print(f"  ! {w}")
    if a.all and dirs.libs_off >= 0:
        print(f"\n\\System\\Libs: file {dirs.libs_off:#x}, "
              f"{len(dirs.libs_entries)} entries")
        dump("\\System\\Libs", dirs.libs_entries)
        mapped = sum(1 for e in dirs.libs_entries if e.addr in by_hdr)
        print(f"  ({mapped}/{len(dirs.libs_entries)} entries map to packed images)")
        if dirs.plugins_off >= 0 and dirs.plugins_entries:
            print(f"\n\\System\\Libs\\Plugins: file {dirs.plugins_off:#x}, "
                  f"{len(dirs.plugins_entries)} entries")
            dump("\\System\\Libs\\Plugins", dirs.plugins_entries)




def cmd_tree(a):
    r"""Recover the S60 app tree (\System\Apps\<App>\*) by content."""
    rom = load_packed(a.rom)
    hdr = find_rom_header(rom)
    root = find_romfs_root(rom, hdr["root_dir_list"])
    if root is None:
        raise SystemExit("ROMFS root list not found")
    tree = read_app_tree(rom, root)
    if tree is None:
        raise SystemExit("\\System\\Apps directory not found in the packed block")
    print(f"\\System\\Apps: packed file {tree.apps_dir.off:#x}, "
          f"{len(tree.apps_dir.entries)} app directories, "
          f"{len(tree.apps)} resolved")
    by_hdr = {im.code - 0x64: im for im in plausible_images(scan_images(rom))}
    for e in tree.apps_dir.entries:
        d = tree.apps.get(e.name)
        if d is None:
            print(f"  {e.name:22s} @ {e.addr:#010x}  (directory bytes not located)")
            continue
        files = [x for x in d.entries if not x.attr & 0x10]
        images = sum(1 for x in files if x.addr in by_hdr)
        print(f"  {e.name:22s} @ {e.addr:#010x}  packed {d.off:#08x}  "
              f"{len(files)} files, {images} images")
        if a.verbose:
            for x in files:
                im = by_hdr.get(x.addr)
                tail = f"  -> uid3 {im.uid3:#010x}" if im else ""
                print(f"      {x.name:34s} {x.size:#08x}{tail}")
    if a.json:
        payload = {
            "apps_dir": {"file_off": tree.apps_dir.off,
                         "entries": [asdict(e) for e in tree.apps_dir.entries]},
            "apps": {
                name: {"file_off": d.off,
                       "entries": [asdict(x) for x in d.entries]}
                for name, d in tree.apps.items()
            },
        }
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


def cmd_calls(a):
    rom = load_packed(a.rom)
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
    b.add_argument("--snap", action="store_true",
                   help="snap export values to the enclosing function "
                        "prologue (legacy bring-up aid; the packed stream "
                        "matches the export table without it)")
    b.add_argument("--no-snap", action="store_true",
                   help="accepted for compatibility; snapping is off by "
                        "default")
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

    t = sub.add_parser("tree")
    t.add_argument("rom")
    t.add_argument("--verbose", action="store_true",
                   help="list every file in each app directory")
    t.add_argument("--json")
    t.set_defaults(func=cmd_tree)

    a = ap.parse_args()
    a.func(a)



if __name__ == "__main__":
    main()
