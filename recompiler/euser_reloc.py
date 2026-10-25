#!/usr/bin/env python3
"""euser_reloc.py - relocate the kernel's EUser imports onto the ROM's EUser.

Round 27 found that the kernel image and the EUser.dll linked into the same
ROM were built from **different export lists**:

  * the kernel's ``.def`` order is the generic 7.0 list with one export
    missing before ``AddL`` (kernel ordinal K = generic ordinal G - 1);
  * the ROM's EUser.dll is the same list with four exports missing before
    ``AddL`` (ROM export index M = G - 4);
  * therefore, for K >= 6, the desired symbol is at ROM export **K - 3**.

The shift is visible in every cluster that has been resolved by call-site
semantics: CObject (K=177/178/480/799/1266/1396), CObjectCon / ObjectIx
(K=6/9/10/421/725/277), TInt64/TTime (K=970/1147/1378/1455/1457/1484/
1486/1562/1611), the descriptor/name cluster (K=67/88/90/717/718/1281/1282/
1417/1419/1620) and the queue iterators (K=362/1336).  The first three
entries are special: K=0 is the ROM's memset, K=1 is ``Mem::Copy`` and K=2
is ``User::Alloc`` (the kernel's low ordinal block is not the generic one).
The round-27 profile also pins K=1361: the ROM's own target (`0x503a0224`)
is the 16-byte-zeroing constructor used by the boot-file object.

Round 28's boot profile originally kept four call-site-derived local
exceptions.  Round 29 showed that the three time-cluster ones were a symptom
of two interpreter bugs (undecoded ARMv4T long multiply and non-S
data-processing instructions clobbering the flags): with those fixed, K=294
-> `TTime::DateTime` (`0x503a4020`), K=1069 -> `TDateTime::Set`
(`0x503a3900`) and K=1375 -> `TTime::TTime(const TDateTime&)` (`0x503a3af8`)
are the plain edata[K-3] slots.  Only K=1361 remains, because the first boot
thread's `operator new(0x74, block)` needs the buffer/stack constructor
`0x503a023c` rather than the ROM's 16-byte-zeroing `0x503a0224`.

This tool emits the 236-slot kernel -> EUser boot relocation map and verifies
the known anchors.

Commands::

    py recompiler/euser_reloc.py analyze 6600_mcu.bin
    py recompiler/euser_reloc.py build 6600_mcu.bin config/imports-r29-6600.txt --profile boot
    py recompiler/euser_reloc.py verify 6600_mcu.bin
    py recompiler/euser_reloc.py verify 6600_mcu.bin --profile boot
"""
from __future__ import annotations

import argparse
import os
import re
import struct
import sys

import imports

EUSER_UID3 = 0x100039E5
KERNEL_UID3 = 0x100058E8
ELOCL_UID3 = 0x100065A5

# The three low kernel ordinals whose target is not edata[K - 3].
LOW_FIXED = {
    0x503B3798: (1, 0x5038CFE0, "Mem::Copy / memcpy"),
    0x503B379C: (2, 0x503988F0, "User::Alloc"),
}

# Local deviations from the K-3 rule: the ROM's export order has an extra
# symbol in this cluster.  K=1361 constructs the base of the 0x74-byte boot
# file object; the shifted target (0x5039c148) writes at +0x7c and overruns
# the object into the next TRomEntry, while the ROM's own K target
# (0x503a0224) zeroes a 16-byte base.  The call-site object size and the
# observed overrun pin the exception.
EXCEPTIONS = {
    0x503B4CD8: (1361, 0x503A0224, "boot file base ctor (local ROM order)"),
}

# Round 28 boot profile.  The first boot thread is allocated with
# operator new(0x74, block); the real base constructor is the buffer/stack
# constructor 0x503a023c (it stores the size at +0, +4, +0xc and allocates
# the backing store), not the 16-byte zeroing function 0x503a0224 used by
# the boot-file object.
#
# Round 29 correction: the three time-cluster "static" exceptions added in
# round 28 were a symptom of the missing ARM long multiply (SMULL/UMULL/
# UMLAL/SMLAL were executed as a register-shifted SBC).  Once the interpreter
# computes 64-bit products, the plain edata[K-3] targets are the correct
# symbols: K=294 -> edata[291] = TTime::DateTime (0x503a4020), K=1069 ->
# edata[1066] = TDateTime::Set (0x503a3900), K=1375 -> edata[1372] =
# TTime::TTime(const TDateTime&) (0x503a3af8).  Only K=1361 still needs the
# local exception.
BOOT_EXCEPTIONS = dict(EXCEPTIONS)
BOOT_EXCEPTIONS.update({
    0x503B4CD8: (1361, 0x503A023C, "TStack/TBuf base ctor (boot profile)"),
})

# Anchors verified by earlier rounds from call-site semantics.  (kernel
# ordinal, slot, expected ROM target, human label)
ANCHORS = [
    (6, 0x503B37AC, 0x503A2414, "TDblQueLinkBase::AddBefore"),
    (9, 0x503B37B8, 0x503851E0, "CObjectCon::AddL"),
    (10, 0x503B37BC, 0x50384DEC, "CObjectIx::AddL"),
    (25, 0x503B37F8, 0x503823A8, "CBitMapAllocator::AllocAt(int)"),
    (26, 0x503B37FC, 0x50382418, "CBitMapAllocator::AllocAt(int,int)"),
    (34, 0x503B381C, 0x5039890C, "User::AllocL"),
    (47, 0x503B3850, 0x50394AD8, "TDesC16::Alloc"),
    (67, 0x503B38A0, 0x50395B8C, "TDes16::AppendNumFixedWidth"),
    (88, 0x503B38F4, 0x5038877C, "TDes16::Append(TChar)"),
    (90, 0x503B38FC, 0x503887C4, "TDes16::Append(TDesC16&)"),
    (98, 0x503B391C, 0x50388474, "TDesC16::AtC"),
    (123, 0x503B3980, 0x50382880, "CBitMapAllocator::Avail"),
    (177, 0x503B3A58, 0x50384B3C, "CObject::Close"),
    (204, 0x503B3AC4, 0x50388E30, "TDesC8::Compare"),
    (247, 0x503B3B70, 0x50388360, "TDes16::Copy(TUint16*)"),
    (277, 0x503B3BE8, 0x5038598C, "CObjectConIx::CreateL"),
    (362, 0x503B3D3C, 0x503A2900, "TDblQueIterBase::DoPostInc"),
    (421, 0x503B3E28, 0x50385650, "CObjectCon::FindByName"),
    (474, 0x503B3EFC, 0x5038277C, "CBitMapAllocator::Free(int,int)"),
    (480, 0x503B3F14, 0x50384C34, "CObject::FullName"),
    (631, 0x503B4170, 0x503885CC, "TDesC16::Left"),
    (651, 0x503B41C0, 0x50388504, "TDesC16::LocateReverse"),
    (694, 0x503B426C, 0x503A4344, "TTime::MicroSecondsFrom"),
    (697, 0x503B4278, 0x50388654, "TDesC16::Mid"),
    (717, 0x503B42C8, 0x5039B230, "DProcess name suffix [uid]"),
    (718, 0x503B42CC, 0x50384BF8, "CObject::Name"),
    (725, 0x503B42E8, 0x50385858, "CObjectConIx::NewL"),
    (746, 0x503B433C, 0x50381B28, "CBitMapAllocator::New"),
    (799, 0x503B4410, 0x50384B28, "CObject::Open"),
    (970, 0x503B46BC, 0x503A4380, "TTime::SecondsFrom"),
    (1147, 0x503B4980, 0x5038CAE8, "TTrap::Trap"),
    (1266, 0x503B4B5C, 0x50384AC8, "CObject::~CObject"),
    (1281, 0x503B4B98, 0x503882C4, "TBufBase16(TDesC16&, int)"),
    (1282, 0x503B4B9C, 0x50388254, "TBufBase16(int)"),
    (1302, 0x503B4BEC, 0x503A25A4, "TDblQueBase(int)"),
    (1328, 0x503B4C54, 0x503A2684, "TDblQueBase()"),
    (1336, 0x503B4C74, 0x503A28B8, "TDblQueIterBase ctor"),
    (1378, 0x503B4D1C, 0x50389A40, "TInt64(int)"),
    (1384, 0x503B4D34, 0x50388984, "TPtrC8(const TUint8*)"),
    (1396, 0x503B4D64, 0x50384A98, "CObject::CObject"),
    (1417, 0x503B4DB8, 0x5039B2A0, "TUidType()"),
    (1419, 0x503B4DC0, 0x5039B2F0, "TUidType(TUid,TUid,TUid)"),
    (1455, 0x503B4E50, 0x50389AE8, "TInt64::operator/="),
    (1457, 0x503B4E58, 0x50389E20, "TInt64::operator<<="),
    (1484, 0x503B4EC4, 0x503A4F84, "TTime::operator+="),
    (1486, 0x503B4ECC, 0x50389A68, "TInt64::operator+="),
    (1562, 0x503B4FFC, 0x50389F0C, "TInt64::operator*"),
    (1611, 0x503B50C0, 0x50389FC8, "TInt64::operator>>"),
    (1620, 0x503B50E4, 0x5039B364, "TUidType::operator[]"),
]


def load(path: str):
    stream = imports.load_stream(path)
    images = imports.real_images(stream)
    euser = next((im for im in images if im.uid3 == EUSER_UID3), None)
    if euser is None:
        raise SystemExit(f"{path}: EUser uid3 {EUSER_UID3:#x} not found")
    return stream, images, euser


def edata_values(stream: bytes, euser) -> list[int]:
    ed = euser.section("edata")
    return [struct.unpack_from("<I", stream, ed.file_off + 4 * i)[0]
            for i in range(euser.export_count)]


def generic_symbols() -> dict[int, str]:
    """Optional: the generic 7.0 EUser .def from the local references."""
    path = os.path.join("references", "symbian-kernelhwsrv", "kernel", "eka",
                        "bmarm", "7.0-euseru.def")
    out: dict[int, str] = {}
    if not os.path.exists(path):
        return out
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = re.match(r"\s*(\S+)\s+@\s+(\d+)", line)
            if m:
                out[int(m.group(2))] = m.group(1)
    return out


def rows(stream: bytes, euser, edata: list[int], exceptions=None):
    if exceptions is None:
        exceptions = EXCEPTIONS
    res = imports.scan(stream, KERNEL_UID3)
    out = []
    for r in res["rows"]:
        if r["owner"] != EUSER_UID3:
            continue
        k = r["ordinal"]
        if r["slot"] in exceptions:
            target = exceptions[r["slot"]][1]
            kind = "exception"
        elif k >= 6:
            target = edata[k - 3]
            kind = "shift"
        elif r["slot"] in LOW_FIXED:
            target = LOW_FIXED[r["slot"]][1]
            kind = "low-fixed"
        else:
            target = r["value"]
            kind = "keep"
        out.append({"slot": r["slot"], "k": k, "current": r["value"],
                    "target": target, "kind": kind})
    out.sort(key=lambda x: x["k"])
    return out


def write_map(path: str, mapping: dict[int, str], header: list[str]):
    with open(path, "w") as f:
        for line in header:
            f.write(f"# {line}\n" if line else "#\n")
        for slot in sorted(mapping):
            f.write(f"{slot:#x} {mapping[slot]}\n")
    print(f"wrote {path}: {len(mapping)} slot overrides")


def cmd_analyze(a):
    stream, _images, euser = load(a.rom)
    edata = edata_values(stream, euser)
    sym = generic_symbols()
    print(f"EUser uid3 {EUSER_UID3:#x}: {len(edata)} exports; "
          f"kernel imports {sum(1 for r in rows(stream, euser, edata))}")
    print(f"{'K':>5} {'slot':>10} {'current':>10} {'target':>10} "
          f"{'kind':8} generic[K+1]")
    for r in rows(stream, euser, edata):
        g = sym.get(r["k"] + 1, "")
        if r["slot"] in LOW_FIXED:
            g = LOW_FIXED[r["slot"]][2]
        elif r["slot"] in EXCEPTIONS:
            g = EXCEPTIONS[r["slot"]][2]
        print(f"{r['k']:5d} {r['slot']:#010x} {r['current']:#010x} "
              f"{r['target']:#010x} {r['kind']:8} {g}")


def cmd_build(a):
    stream, _images, euser = load(a.rom)
    edata = edata_values(stream, euser)
    mapping = {}
    for r in rows(stream, euser, edata, BOOT_EXCEPTIONS):
        if r["kind"] == "keep":
            continue
        mapping[r["slot"]] = f"{r['target']:#x}"
    # The ELocl export-table hole is independent of the EUser relocation.
    mapping[0x5037D0E8] = "zero"
    header = [
        f"{os.path.basename(a.out)} - kernel EUser boot relocation (round 29)",
        "",
        "The kernel was linked against an EUser .def one export shorter",
        "than the generic 7.0 list; the ROM EUser.dll is four exports",
        "shorter.  For kernel ordinal K >= 6 the desired symbol is at",
        "ROM EUser export K-3.  K=0 (memset), K=1 (Mem::Copy) and K=2",
        "(User::Alloc) are the low special cases.  K=1361 is the only local",
        "exception: the initial thread's TStack/TBuf constructor 0x503a023c.",
        "The ELocl export hole (ordinal 20) is the zero-return stub.",
        "",
        "Generated by: py recompiler/euser_reloc.py build ... --profile boot",
        "Do not hand-edit; add an anchor/exception to the tool instead.",
    ]
    write_map(a.out, mapping, header)


def cmd_verify(a):
    stream, _images, euser = load(a.rom)
    edata = edata_values(stream, euser)
    profile = getattr(a, "profile", "full")
    exceptions = BOOT_EXCEPTIONS if profile == "boot" else EXCEPTIONS
    allrows = rows(stream, euser, edata, exceptions)
    by_slot = {r["slot"]: r for r in allrows}
    ok = True
    print(f"kernel EUser imports: {len(allrows)} ({profile} profile)")
    if len(allrows) != 236:
        print(f"FAIL: expected 236 EUser imports, got {len(allrows)}")
        ok = False
    for k, slot, want, label in ANCHORS:
        r = by_slot.get(slot)
        if r is None:
            print(f"FAIL: no import at slot {slot:#x} ({label})")
            ok = False
            continue
        if r["target"] != want:
            print(f"FAIL: K={k} {label}: target {r['target']:#x} != {want:#x}")
            ok = False
        else:
            print(f"ok: K={k:4d} {label:38} -> {want:#010x}")
    for slot, (k, want, label) in exceptions.items():
        r = by_slot.get(slot)
        if r is None or r["target"] != want:
            print(f"FAIL: exception K={k} {label}: "
                  f"got {r['target'] if r else None}")
            ok = False
        else:
            print(f"ok: exception K={k:4d} {label:38} -> {want:#010x}")
    # The full profile must be exactly the shift rule (plus the low cases
    # and the documented local exceptions).
    bad = [r for r in allrows
           if r["kind"] == "shift" and r["target"] != edata[r["k"] - 3]]
    if bad:
        print(f"FAIL: {len(bad)} slots do not follow edata[K-3]")
        ok = False
    # The ROM export at K-3 must be code, not zero, for every shifted K.
    zero = [r for r in allrows if r["kind"] == "shift" and r["target"] == 0]
    if zero:
        print(f"FAIL: {len(zero)} shifted targets are zero")
        ok = False
    if not ok:
        raise SystemExit(1)
    shift = sum(1 for r in allrows if r["kind"] == "shift")
    fixed = sum(1 for r in allrows if r["kind"] == "low-fixed")
    exc = sum(1 for r in allrows if r["kind"] == "exception")
    keep = sum(1 for r in allrows if r["kind"] == "keep")
    print(f"PASS: {shift} EUser slots follow edata[K-3]; {exc} local "
          f"exception(s); {fixed} low specials; {keep} kept; ELocl hole separate")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("analyze")
    p.add_argument("rom")
    p.set_defaults(func=cmd_analyze)
    p = sub.add_parser("build")
    p.add_argument("rom")
    p.add_argument("out")
    p.add_argument("--profile", choices=("boot",), default="boot")
    p.set_defaults(func=cmd_build)
    p = sub.add_parser("verify")
    p.add_argument("rom")
    p.add_argument("--profile", choices=("full", "boot"), default="full")
    p.set_defaults(func=cmd_verify)
    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
