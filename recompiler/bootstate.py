#!/usr/bin/env python3
"""bootstate.py - pin the EKA1 boot hand-off state discovered in round 28.

Booting the kernel's E32 entry directly skips the mask ROM, which normally
leaves a small amount of state in the fixed super page (0x40000000) before
jumping to the kernel.  Round 28 recovered three pieces of that state from
the kernel's own code and the ROM header:

  * ``[0x400000d0]`` is the primary (ekern.exe) TRomEntry pointer.  The
    kernel reads ``[entry+4]`` to get its own TRomImageHeader, then copies
    iStackSize/iHeapSizeMin/iHeapSizeMax out of it (0x5031e594 and
    0x5031edc8).  Without the hand-off the read falls through to address 4
    (the low exception vector word) and the initial thread fields are junk.

  * The initial DThread's TStack object is allocated at
    ``iPrimaryFile + iStackSize``.  In the flash image that is inside the
    read-only 64 KiB ROMFS directory block, so the mask ROM must provide a
    writable copy; only iPrimaryFile needs repointing (variant/extension
    entries stay at their ROM addresses).

  * The first TStack object is created with ``operator new(0x74, block)``
    and the real base constructor is 0x503a023c (it stores the size at
    0x0/0x4/0xc and allocates the backing store).  The round-27 K=1361
    exception 0x503a0224 only zeroes 16 bytes and leaves the stack-size
    field at zero; TStack::Set then panics PLAT 0x51.

Round 29 then closed the apparent time-cluster frontier: the out-of-range
TTime was caused by two ARMv4T interpreter bugs (undecoded long multiply and
non-S data-processing instructions clobbering the flags).  The static time
and idle sequences are still pinned here; the live boot acceptance is
tools/test_round29.sh (NK_SYSTEM_TIME installs the 0x50000084 TTime hand-off).

Commands::

    py recompiler/bootstate.py verify 6600_mcu.bin
"""
from __future__ import annotations

import argparse
import struct
import sys

import imports
import romimage

KERNEL_UID3 = 0x100058E8
KERNEL_HDR_VA = 0x5030FF9C
KERNEL_CODE_VA = 0x50310000
SUPERPAGE = 0x40000000


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def stream_off(img: romimage.Image, va: int) -> int | None:
    for sec in img.sections:
        if sec.va <= va < sec.va + sec.size:
            return sec.file_off + (va - sec.va)
    return None


def word(stream: bytes, img: romimage.Image, va: int) -> int:
    o = stream_off(img, va)
    if o is None:
        raise SystemExit(f"{va:#x} is not in {img.uid3:#x}'s sections")
    return u32(stream, o)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("verify")
    p.add_argument("rom")
    a = ap.parse_args()
    if a.cmd != "verify":
        return 2

    stream = imports.load_stream(a.rom)
    images = imports.real_images(stream)
    kern = next((im for im in images if im.uid3 == KERNEL_UID3), None)
    if kern is None:
        raise SystemExit("kernel image not found")
    hdr = kern.hdr_off
    uid3 = u32(stream, hdr + 0x08)
    entry = u32(stream, hdr + 0x10)
    stack = u32(stream, hdr + 0x34)
    heap_min = u32(stream, hdr + 0x2C)
    heap_max = u32(stream, hdr + 0x30)
    primary = u32(stream, 0x7C + 0x20)

    ok = True
    def check(cond, label):
        nonlocal ok
        print(("ok:   " if cond else "FAIL: ") + label)
        ok = ok and cond

    check(uid3 == KERNEL_UID3, f"kernel header uid3 {uid3:#x}")
    check(entry == 0x50310054, f"kernel entry {entry:#x} (ARM)")
    check(stack == 0x4000, f"kernel iStackSize {stack:#x}")
    check(heap_min == 0x20000, f"kernel iHeapSizeMin {heap_min:#x}")
    check(heap_max == 0x1000000, f"kernel iHeapSizeMax {heap_max:#x}")
    check(primary == 0x50301EC4,
          f"ROM header iPrimaryFile {primary:#x} (ekern.exe TRomEntry)")

    # 0x5031e5a8: ldr r3,[ip,#0xd0] ; ldr sb,[r3,#4]
    check(word(stream, kern, 0x5031E5A8) == 0xE59C30D0 and
          word(stream, kern, 0x5031E5AC) == 0xE5939004,
          "Kernel::Init reads the super-page [0x400000d0] -> image header")

    # 0x5031ede4..0x5031ee04: the stack base = iPrimaryFile + iStackSize
    seq = [
        (0x5031EDE4, 0xE3A03101),  # mov r3,#0x40000000
        (0x5031EDE8, 0xE59330D0),  # ldr r3,[r3,#0xd0]
        (0x5031EDEC, 0xE5932004),  # ldr r2,[r3,#4]
        (0x5031EDF0, 0xE3A03205),  # mov r3,#0x50000000
        (0x5031EDF4, 0xE593309C),  # ldr r3,[r3,#0x9c] (iPrimaryFile)
        (0x5031EDF8, 0xE5920034),  # ldr r0,[r2,#0x34] (iStackSize)
        (0x5031EDFC, 0xE0830000),  # add r0,r3,r0
        (0x5031EE00, 0xE592102C),  # ldr r1,[r2,#0x2c] (iHeapSizeMin)
        (0x5031EE04, 0xEB000BB9),  # bl 0x50321cf0
    ]
    for va, want in seq:
        got = word(stream, kern, va)
        check(got == want, f"stack-base sequence {va:#x}: {got:#010x}")

    # 0x50321d84 TStack::Set checks [this] == aSize and panics PLAT 0x51.
    check(word(stream, kern, 0x50321D94) == 0xE5942000 and
          word(stream, kern, 0x50321D98) == 0xE1520003 and
          word(stream, kern, 0x50321D9C) == 0x13A00051 and
          word(stream, kern, 0x50321DA0) == 0x1BFFFF33,
          "TStack::Set compares [this] with the requested size, PLAT 0x51")

    # The boot profile's K=1361 target 0x503a023c stores the size fields.
    def euser_word(va: int) -> int:
        euser = next(im for im in images if im.uid3 == 0x100039E5)
        return word(stream, euser, va)
    check(euser_word(0x503A023C) == 0xE92D4010 and
          euser_word(0x503A0240) == 0xE1A04000 and
          euser_word(0x503A0244) == 0xE5841004 and
          euser_word(0x503A0248) == 0xE5841000,
          "boot TStack ctor 0x503a023c stores the size (K=1361 exception)")

    # The time frontier: the conversion writes 0x800017ec, SecondsFrom is
    # 0x5033645c -> K=970, and Kern::Init1 panics MKERN-WD2 24 at 0x50310b30.
    check(word(stream, kern, 0x503126E4) == 0xEB008F5C,
          "time path calls the K=970 TTime slot at 0x503126e4")
    check(word(stream, kern, 0x50310B24) == 0xEB000B38 and
          word(stream, kern, 0x50310B2C) == 0x13A00018 and
          word(stream, kern, 0x50310B30) == 0x1B000832,
          "Kern::Init1 panics MKERN-WD2 24 when 0x5031380c returns nonzero")

    # The idle loop: call 0x5031252c, then spin while [0x8000000c] == 0.
    check(word(stream, kern, 0x50310F84) == 0xEB000568 and
          word(stream, kern, 0x50310F88) == 0xE5943000 and
          word(stream, kern, 0x50310F90) == 0x0AFFFFFB,
          "idle loop 0x50310f84 waits for [0x8000000c]")

    if not ok:
        raise SystemExit(1)
    print("PASS: round-28 boot hand-off, stack constructor and time/idle sequences")
    return 0


if __name__ == "__main__":
    sys.exit(main())
