#!/usr/bin/env python3
"""executive.py — decode the EKA1 kernel executive-call (SWI) table.

EUser.dll implements the user-side kernel API as a dense table of one-
instruction stubs::

    ...  680080ef   svc #0x800068
         6900c0ef   svc #0xc00069
         ...

The SVC vector at kernel ``0x50310008`` enters the handler at
``0x50314f30``.  The handler masks the SWI immediate, bounds-checks it against
the literal at ``0x50314f7c`` (``0x444`` bytes = ``0x111`` entries), and
dispatches through a table of 32-bit service addresses at linked
``0x50314aec``.  Because the packed stream is the linked image, the table is
directly readable.

This tool makes that contract explicit and validates it:

* the handler's bound literal is ``0x444``;
* the table has ``0x111`` entries and every non-zero entry is inside the
  kernel text;
* the zero entries (unimplemented services) are listed instead of guessed;
* every ``svc`` instruction in every image is mapped back to its service
  address, so the runtime's ``NK_SWI_DIRECT`` HLE and the next kernel service
  to model are visible.

Commands::

    py recompiler/executive.py verify 6600_mcu.bin
    py recompiler/executive.py list   6600_mcu.bin --used
    py recompiler/executive.py stubs  6600_mcu.bin
    py recompiler/executive.py stubs  6600_mcu.bin --image 0x100039e5

The table is a *bring-up* map: the real handler also distinguishes user and
kernel callers, saves banked registers, and returns through SPSR.  The map is
the part that can be recovered from the packed image today; the exception
model around it is still the next CPU-model task.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import Counter, defaultdict

import pagestream
import romimage

KERNEL_UID3 = 0x100058E8
KERNEL_CODE = 0x50310000
KERNEL_TEXT_SIZE = 0x28AC0
TABLE_VA = 0x50314AEC
TABLE_COUNT = 0x111
HANDLER_LIMIT_VA = 0x50314F7C
HANDLER_LIMIT_WORD = 0x444
SVC_HANDLER_VA = 0x50314F30


def u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def load_stream(path: str) -> bytes:
    with open(path, "rb") as f:
        return pagestream.build(f.read())


def stream_off(img: romimage.Image, va: int) -> int | None:
    """Map a linked virtual address to an offset in the packed stream."""
    for sec in img.sections:
        if sec.va <= va < sec.va + sec.size:
            return sec.file_off + (va - sec.va)
    return None


def real_images(images: list[romimage.Image]) -> list[romimage.Image]:
    """Drop the 2-byte-scan false positives with impossible UID3 values."""
    return [im for im in images if 0x10000000 <= im.uid3 < 0x10200000]


def find_kernel(stream: bytes) -> romimage.Image:
    images = real_images(romimage.scan_images(stream))
    for im in images:
        if im.uid3 == KERNEL_UID3:
            return im
    raise SystemExit("kernel uid3 0x100058e8 not found in the stream")


def read_table(stream: bytes, img: romimage.Image,
               base: int = TABLE_VA, count: int = TABLE_COUNT) -> list[int]:
    off = stream_off(img, base)
    if off is None:
        raise SystemExit(f"service table {base:#x} is outside the kernel sections")
    end = off + count * 4
    if end > len(stream):
        raise SystemExit("service table runs past the stream")
    return [u32(stream, off + i * 4) for i in range(count)]


def check_table(stream: bytes, img: romimage.Image,
                base: int = TABLE_VA, count: int = TABLE_COUNT) -> dict:
    code_lo, code_hi = img.code, img.code + img.text_size
    entries = read_table(stream, img, base, count)
    zero = [i for i, v in enumerate(entries) if v == 0]
    outside = [(i, v) for i, v in enumerate(entries)
               if v and not (code_lo <= (v & ~1) < code_hi)]
    return {
        "base": base,
        "count": count,
        "zero": zero,
        "outside": outside,
        "entries": entries,
        "first": entries[0],
        "last": entries[-1],
        "code_lo": code_lo,
        "code_hi": code_hi,
    }


def _is_arm_term(w: int) -> bool:
    return ((w & 0xFFFF8000) == 0xE8BD8000 or       # pop {..., pc}
            w == 0xE12FFF1E or                      # bx lr
            w == 0xE1A0F00E)                        # mov pc, lr


def _arm_svc_words(stream: bytes, img: romimage.Image):
    """Yield (va, swi_index) for ARM `svc #imm` words in one image.

    A packed record also contains data with 0xEF in the top byte, so a raw
    decode finds tens of thousands of false positives.  A real stub is part
    of a run of SVCs, or sits next to a return; keep only those.
    """
    for sec in img.sections:
        if sec.name != "text":
            continue
        words = {}
        for o in range(sec.file_off, sec.file_off + sec.size - 3, 4):
            w = u32(stream, o)
            # ARM SWI: cond=1111, bits 27-24 = 1111.  The 24-bit immediate
            # carries the executive index in its low 9 bits.
            if (w & 0x0F000000) == 0x0F000000:
                words[o] = w & 0x1FF
        for o, idx in words.items():
            prev = u32(stream, o - 4) if o - 4 >= sec.file_off else 0
            nxt = u32(stream, o + 4) if o + 8 <= sec.file_off + sec.size else 0
            if (o - 4 in words or o + 4 in words or
                    _is_arm_term(prev) or _is_arm_term(nxt)):
                yield sec.va + (o - sec.file_off), idx


def _thumb_svc_halves(stream: bytes, img: romimage.Image):
    """Yield (va, swi_index) for Thumb `svc imm8` halfwords in one image."""
    for sec in img.sections:
        if sec.name != "text":
            continue
        for o in range(sec.file_off, sec.file_off + sec.size - 1, 2):
            h = struct.unpack_from("<H", stream, o)[0]
            if (h & 0xFF00) == 0xDF00:
                yield sec.va + (o - sec.file_off), h & 0x1FF


def collect_stubs(stream: bytes, images: list[romimage.Image],
                  table: list[int], thumb: bool = False) -> list[dict]:
    out = []
    for im in images:
        gen = _thumb_svc_halves(stream, im) if thumb else _arm_svc_words(stream, im)
        for va, idx in gen:
            if idx >= len(table):
                continue            # the handler's out-of-range path, not a call
            target = table[idx]
            out.append({
                "image": im.uid3,
                "va": va,
                "index": idx,
                "target": target,
                "isa": "Thumb" if thumb else "ARM",
            })
    return out


def cmd_verify(stream: bytes, _args) -> int:
    img = find_kernel(stream)
    st = check_table(stream, img)

    # The handler's bound is a literal in the kernel text.  Pinning it here
    # keeps TABLE_COUNT honest if the stream shifts again.
    lim_off = stream_off(img, HANDLER_LIMIT_VA)
    if lim_off is None:
        raise SystemExit("handler limit literal is outside the kernel text")
    lim = u32(stream, lim_off)
    handler = stream_off(img, SVC_HANDLER_VA)
    if handler is None:
        raise SystemExit("SVC handler is outside the kernel text")

    print(f"kernel: uid3 {img.uid3:#010x}, text {img.code:#010x}.."
          f"{img.code + img.text_size:#010x}")
    print(f"SVC handler {SVC_HANDLER_VA:#010x} (stream {handler:#x})")
    print(f"handler limit [{HANDLER_LIMIT_VA:#010x}] = {lim:#x} "
          f"({lim // 4} entries)")
    print(f"service table {st['base']:#010x}: {st['count']} entries")
    print(f"  first {st['first']:#010x}  last {st['last']:#010x}  "
          f"unique {len(set(st['entries']))}")
    print(f"  zero/unimplemented: {len(st['zero'])} "
          f"({', '.join(hex(i) for i in st['zero'])})")
    if st["outside"]:
        print("  OUTSIDE KERNEL TEXT:")
        for i, v in st["outside"]:
            print(f"    [{i:#x}] {v:#010x}")
    ok = (lim == HANDLER_LIMIT_WORD and st["count"] == TABLE_COUNT
          and not st["outside"] and st["zero"] == [0x8a, 0x94, 0x95, 0x96])
    if not ok:
        print("FAIL: executive table invariants changed", file=sys.stderr)
        return 1
    print("ok: 0x111-entry executive table, four unimplemented slots, "
          "all other targets in kernel text")
    return 0


def cmd_list(stream: bytes, args) -> int:
    img = find_kernel(stream)
    st = check_table(stream, img, args.table, args.count)
    entries = st["entries"]
    used = Counter()
    if args.used:
        for rec in collect_stubs(stream, real_images(romimage.scan_images(stream)),
                                 entries):
            used[rec["index"]] += 1

    print(f"# EKA1 executive table {st['base']:#x}: {st['count']} entries")
    print(f"{'idx':>5} {'target':>12} {'uses':>6}")
    for i, v in enumerate(entries):
        if args.used and not used[i]:
            continue
        if v and not (st["code_lo"] <= (v & ~1) < st["code_hi"]):
            continue
        print(f"{i:5d} {format(v, '#010x'):>12} {used[i]:6d}")
    if args.json:
        rows = [{"index": i, "target": v, "uses": used[i]}
                for i, v in enumerate(entries)]
        with open(args.json, "w") as f:
            json.dump({"table": st["base"], "count": st["count"],
                       "zero": st["zero"], "entries": rows}, f, indent=2)
        print(f"wrote {args.json}")
    return 0


def cmd_stubs(stream: bytes, args) -> int:
    img = find_kernel(stream)
    st = check_table(stream, img, args.table, args.count)
    table = st["entries"]
    images = real_images(romimage.scan_images(stream))
    if args.image:
        images = [im for im in images if im.uid3 == args.image]
        if not images:
            raise SystemExit(f"image {args.image:#x} not found")
    recs = collect_stubs(stream, images, table, thumb=args.thumb)
    by_image = defaultdict(int)
    by_index = Counter()
    for r in recs:
        by_image[r["image"]] += 1
        by_index[r["index"]] += 1
    print(f"# {len(recs)} {'Thumb' if args.thumb else 'ARM'} SVC stubs in "
          f"{len(by_image)} images")
    print(f"{'uid3':>12} {'stubs':>6}  services (index -> target)")
    for uid3, n in sorted(by_image.items(), key=lambda kv: -kv[1]):
        if args.limit and n < args.limit:
            continue
        idxs = sorted({r["index"] for r in recs if r["image"] == uid3})
        sample = " ".join(f"{i:#x}" for i in idxs[:12])
        if len(idxs) > 12:
            sample += " ..."
        print(f"{format(uid3, '#010x'):>12} {n:6d}  {sample}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"stubs": recs,
                       "by_index": {str(k): v for k, v in by_index.items()}},
                      f, indent=2)
        print(f"wrote {args.json}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("verify", "list", "stubs"))
    ap.add_argument("rom")
    ap.add_argument("--table", type=lambda x: int(x, 0), default=TABLE_VA)
    ap.add_argument("--count", type=lambda x: int(x, 0), default=TABLE_COUNT)
    ap.add_argument("--used", action="store_true",
                    help="list only services referenced by a SVC stub")
    ap.add_argument("--image", type=lambda x: int(x, 0),
                    help="restrict stubs to one image uid3")
    ap.add_argument("--thumb", action="store_true",
                    help="scan Thumb SVC halfwords instead of ARM words")
    ap.add_argument("--limit", type=int, default=0,
                    help="stubs: hide images with fewer than N stubs")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    stream = load_stream(args.rom)
    if args.command == "verify":
        return cmd_verify(stream, args)
    if args.command == "list":
        return cmd_list(stream, args)
    return cmd_stubs(stream, args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
