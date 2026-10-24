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
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import dataclass, field, asdict

ROM_BASE = 0x50000000
ROM_SIZE = 0x01600000

UID_EXE = 0x10000079
UID_DLL = 0x1000007A
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
    if o < 0 or o + 0x70 > len(rom) or (o & 3):
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
    return [o for o in range(0, len(rom) - 0x70, 4) if is_e32_header(rom, o)]


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


# ---------------------------------------------------------------------------
# reachability (the only images the kernel actually needs)
# ---------------------------------------------------------------------------

def reachable_images(images: list[Image]) -> list[Image]:
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
    """Parse the root list and the root directory.

    The 6600's ROMFS is flat: the root directory is packed immediately after
    the 12-byte list and contains all 171 entries.  Sub-directories are not
    present in this ROM (all entries have attr 0x01), so no recursive packed
    directory search is needed; the parser still handles the general shape.
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
                do_snap: bool = True) -> tuple[bytes, list[str], list[Section]]:
    """Assemble a flat ROM at runtime addresses.  Returns (buf, warnings, placed)."""
    buf = bytearray(ROM_SIZE)
    placed: list[Section] = []
    warnings: list[str] = []

    def put(va: int, data: bytes, name: str, file_off: int):
        if va < ROM_BASE or va + len(data) > ROM_BASE + ROM_SIZE:
            warnings.append(f"{name}: {va:#x}+{len(data):#x} outside the 22 MiB ROM")
            return
        off = va - ROM_BASE
        old = bytes(buf[off:off + len(data)])
        if any(old) and old != data:
            warnings.append(f"{name}: overwrites existing data at {va:#x}")
        buf[off:off + len(data)] = data
        placed.append(Section(name, file_off, len(data), va))

    # 1. boot area: the first 64 KiB are linear in the file
    boot_len = min(0x10000, len(rom))
    put(ROM_BASE, rom[:boot_len], "boot", 0)

    # 2. every reachable ROM image, at its header addresses.  The 0x64-byte
    #    TRomImageHeader sits at code-0x64; the ROMFS directory block stops
    #    exactly there, so the two do not collide.  A later image's header may
    #    also live in the 4-byte gap after the previous image's export dir.
    for im in images:
        tag = f"uid3_{im.uid3:08x}"
        put(im.code - 0x64, rom[im.hdr_off:im.hdr_off + 0x64],
            tag + "_hdr", im.hdr_off)
        for s in im.sections:
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

    # 3. ROMFS directory area.  On the 6600 the packed directories occupy
    #    exactly the 64 KiB below the kernel: file [root, root+span) maps to
    #    [root_dir_list, root_dir_list+span).  The individual iAddress fields
    #    inside the list are stale, so the whole packed area is copied as one
    #    block instead of trusting them.
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
            entries = parse_romfs(rom, root_off)
            if not entries:
                warnings.append("romfs: root directory did not parse")
    elif root_off is not None:
        warnings.append(f"romfs: implausible directory span {span:#x}")

    # 4. ROMFS files.  On the 6600 they are stored linearly at their runtime
    #    address, so file_off == va - ROM_BASE.
    for e in romfs:
        if e.attr & 0x10:
            continue
        foff = e.addr - ROM_BASE
        if foff < 0 or foff + e.size > len(rom):
            warnings.append(f"romfs: {e.name} at {e.addr:#x} outside the file")
            continue
        put(e.addr, rom[foff:foff + e.size], f"romfs_{e.name}", foff)

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
    reach = reachable_images(images)
    print(f"ROM {len(rom):#x} bytes, header @ {hdr['header_offset']:#x}, "
          f"base {hdr['rom_base']:#x}, size {hdr['rom_size']:#x}")
    print(f"images: {len(images)} headers, {len(reach)} reachable from the kernel")
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
          f"{len(entries)} entries ({len(files)} files)")
    bad = [e for e in files if e.addr - ROM_BASE + e.size > len(rom)]
    print(f"  files stored linearly at va - {ROM_BASE:#x}: "
          f"{'all ok' if not bad else str(len(bad)) + ' out of range'}")
    if a.json:
        payload = {
            "rom_header": hdr,
            "images": [asdict(im) for im in images],
            "reachable": [im.uid3 for im in reach],
            "romfs": {"root_file_off": root,
                      "entries": [asdict(e) for e in entries]},
        }
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    hdr = find_rom_header(rom)
    images = scan_images(rom)
    reach = reachable_images(images)
    root = find_romfs_root(rom, hdr["root_dir_list"])
    romfs = parse_romfs(rom, root) if root is not None else []
    buf, warnings, placed = build_image(rom, reach, romfs, a.include_rodata,
                                        do_snap=not a.no_snap)
    patches = load_patches(a.patch) if a.patch else []
    if patches:
        buf = bytearray(buf)
        warnings.extend(apply_patches(buf, patches))
        buf = bytes(buf)
    open(a.output, "wb").write(buf)
    print(f"wrote {a.output}: {len(buf):#x} bytes at {ROM_BASE:#x}")
    print(f"  {len(placed)} sections from {len(reach)} images, "
          f"{len(romfs)} ROMFS entries")
    for w in warnings:
        print(f"  ! {w}")
    kernel = next(im for im in reach if im.uid3 == UID_KERNEL)
    print(f"  kernel entry {kernel.entry:#010x}")
    if a.json:
        payload = {
            "rom_header": hdr,
            "images": [asdict(im) for im in reach],
            "placed": [asdict(s) for s in placed],
            "patches": [{"va": va, "bytes": data.hex(), "line": line}
                        for va, data, line in patches],
            "warnings": warnings,
        }
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


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
    b.set_defaults(func=cmd_build)

    c = sub.add_parser("calls")
    c.add_argument("rom")
    c.add_argument("--limit", type=int, default=8)
    c.set_defaults(func=cmd_calls)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
