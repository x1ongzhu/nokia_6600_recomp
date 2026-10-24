#!/usr/bin/env python3
"""relayout.py — restore the ROM linker's 4-byte alignment padding.

Round 5 found the packed kernel text is missing the 2-byte alignment padding
that the ROM linker inserts before 4-byte-aligned entities (literal pools and
functions).  This tool reconstructs the final layout from the packed text:

    ldr rd,[pc,#imm]  ->  literal pool start
    push/stmdb/...    ->  function start

Both must be 4-byte aligned in the linked image.  Walking the packed text in
address order and inserting two bytes before an entity whenever its *final*
address would be 2 mod 4 is exactly the inverse of the linker's padding pass.

The packed bytes themselves are unchanged; only gaps are inserted.  The tool
reports the resulting shift function (packed address -> final address), which
is what the encoded BL targets and the export directory expect.

    py relayout.py analyze 6600_mcu.bin
    py relayout.py analyze 6600_mcu.bin --json out/relayout.json
    py relayout.py build   6600_mcu.bin out/6600_kernel_relaid.bin
    py relayout.py verify  6600_mcu.bin out/6600_kernel_relaid.bin

`build` writes the kernel *text only*; moving .data/.edata/dllref and the
following images is a separate layout step (see docs/PROGRESS.md).
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import dataclass, field

from capstone import CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB, Cs

import romimage

# The 6600 kernel, used when no --uid3 is given.
KERNEL_UID3 = 0x100058E8

# A literal pool is a run of 32-bit words referenced by PC-relative loads.
POOL_WINDOW = 0x100
POOL_SEARCH = 0x600
FUNC_MAX = 0x4000


def u16(text: bytes, off: int) -> int:
    return struct.unpack_from("<H", text, off)[0]


def u32(text: bytes, off: int) -> int:
    return struct.unpack_from("<I", text, off)[0]


def h_at(text: bytes, code: int, va: int):
    o = va - code
    return u16(text, o) if 0 <= o <= len(text) - 2 else None


def w_at(text: bytes, code: int, va: int):
    o = va - code
    return u32(text, o) if 0 <= o <= len(text) - 4 else None


# ---------------------------------------------------------------------------
# function discovery (enough to find real ldr sites and function starts)
# ---------------------------------------------------------------------------

@dataclass
class Func:
    start: int
    mode: str          # "A" or "T"
    end: int
    ldr_sites: list[tuple[int, int]] = field(default_factory=list)
    calls: list[tuple[int, int]] = field(default_factory=list)   # (site, packed target)


def _is_terminator(ins, mode: str) -> bool:
    if mode == "T":
        return ((ins.mnemonic == "pop" and "pc" in ins.op_str) or
                (ins.mnemonic == "bx" and "lr" in ins.op_str) or
                (ins.mnemonic == "mov" and ins.op_str.replace(" ", "") == "pc,lr"))
    return ((ins.mnemonic == "ldm" and "pc" in ins.op_str) or
            (ins.mnemonic == "bx" and "lr" in ins.op_str) or
            (ins.mnemonic == "mov" and ins.op_str.replace(" ", "") == "pc,lr"))


def discover_function(text: bytes, code: int, seed: int, mode: str) -> Func | None:
    """Decode one function by following its intra-function branches.

    The packed text has stale inter-function call targets, so BL targets are
    only *recorded*, never followed.  A seed that turns out to be data usually
    fails to reach a terminator or decodes garbage; it is then rejected.
    """
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB if mode == "T" else CS_MODE_ARM)
    limit = code + len(text)
    work = [seed]
    seen: set[int] = set()
    ldr_sites: list[tuple[int, int]] = []
    calls: list[tuple[int, int]] = []
    terminated = False
    while work:
        a = work.pop()
        while a not in seen and code <= a < limit:
            ins = next(md.disasm(text[a - code:a - code + 4], a, count=1), None)
            if ins is None or ins.mnemonic in ("udf", "undefined"):
                break
            if mode == "A" and a & 3:
                break
            seen.add(a)
            if len(seen) > FUNC_MAX // 2:
                return None
            op = ins.op_str
            if ins.mnemonic == "ldr" and "pc" in op:
                # [pc, #imm] only; a register offset is not a literal.
                import re
                m = re.search(r"\[pc, #(0x[0-9a-f]+|\d+)\]", op)
                if m:
                    imm = int(m.group(1), 0)
                    tgt = (((a + 4) & ~3) if mode == "T" else (a + 8)) + imm
                    if code <= tgt < limit:
                        ldr_sites.append((a, tgt))
            if _is_terminator(ins, mode):
                terminated = True
                break
            if ins.mnemonic in ("b", "bl") and op.startswith("#"):
                tgt = int(op[1:], 16)
                if ins.mnemonic == "bl":
                    if code <= tgt < limit:
                        calls.append((a, tgt))
                    a += ins.size
                    continue
                # unconditional branch: follow it, do not fall through
                if code <= tgt < limit:
                    work.append(tgt)
                a = None
                break
            if ins.mnemonic.startswith("b") and op.startswith("#"):
                tgt = int(op[1:], 16)
                if code <= tgt < limit:
                    work.append(tgt)
            a += ins.size
    if not terminated or not seen:
        return None
    return Func(seed, mode, max(seen) + 4, ldr_sites, calls)


def find_seeds(text: bytes, code: int) -> list[tuple[int, str]]:
    seeds: list[tuple[int, str]] = []
    for o in range(0, len(text) - 2, 2):
        hw = u16(text, o)
        # thumb push {...,lr}: 0xB5xx (the lr bit is 0x0100)
        if (hw & 0xFF00) == 0xB500:
            seeds.append((code + o, "T"))
        if o % 4 == 0:
            w = u32(text, o)
            if ((w & 0xFFFF0000) == 0xE92D0000 or
                    (w & 0xFFFFF000) == 0xE24DD000 or
                    w == 0xE1A0C00D):
                seeds.append((code + o, "A"))
    return seeds


# ---------------------------------------------------------------------------
# literal pools
# ---------------------------------------------------------------------------

def _terminator_size(text: bytes, code: int, va: int) -> int:
    hw = h_at(text, code, va)
    w = w_at(text, code, va)
    if hw is not None and (hw & 0xFF00) == 0xBD00:
        return 2                                   # thumb pop {...,pc}
    if hw == 0x4770:
        return 2                                   # thumb bx lr
    if hw is not None and (hw & 0xF800) == 0xE000:
        return 2                                   # thumb b
    if w is not None and (w & 0xFFFF8000) == 0xE8BD8000:
        return 4                                   # arm ldm sp!,{...,pc}
    if w is not None and w == 0xE12FFF1E:
        return 4                                   # arm bx lr
    if w is not None and (w & 0x0F000000) == 0x0A000000:
        return 4                                   # arm b
    return 0


def _plausible_literal(v: int | None, code: int, size: int) -> bool:
    if v is None:
        return False
    return (code <= v < code + size or
            0x80000000 <= v < 0x80300000 or
            0x50000000 <= v < 0x51600000 or
            v < 0x100000 or v in (0, 0xFFFFFFFF))


def pool_start_for(text: bytes, code: int, target: int) -> int | None:
    """Walk back from a literal target to the function terminator."""
    for back in range(2, POOL_SEARCH, 2):
        p = target - back
        if p < code + 2:
            break
        ts = _terminator_size(text, code, p)
        if ts and p + ts <= target:
            q = p + ts
            while q + 2 <= target and h_at(text, code, q) == 0:
                q += 2
            return q
    return None


def find_pools(text: bytes, code: int, funcs: list[Func]) -> dict[int, list[tuple[int, int]]]:
    groups: dict[int, list[tuple[int, int]]] = {}
    for f in funcs:
        for site, target in f.ldr_sites:
            start = pool_start_for(text, code, target)
            if start is None or start > target or target - start > POOL_WINDOW:
                continue
            if site >= start:
                continue
            if not (_plausible_literal(w_at(text, code, target), code, len(text)) or
                    _plausible_literal(w_at(text, code, target - 2), code, len(text))):
                continue
            groups.setdefault(start, []).append((site, target))
    return groups


def is_data_table(groups: dict[int, list[tuple[int, int]]], start: int) -> bool:
    """Pick out the 8-byte address-pair tables that look like small pools."""
    return sum(1 for d in (8, 16, 24, 32) if (start - d) in groups) >= 3


# ---------------------------------------------------------------------------
# alignment plan
# ---------------------------------------------------------------------------

@dataclass
class Plan:
    entities: list[int]
    inserts: list[int]                 # packed addresses where 2 bytes go
    shift: int                         # total bytes inserted (2 * len(inserts))
    shift_at: dict[int, int]

    def move(self, packed: int) -> int:
        """Final address of a packed address after the padding pass."""
        n = 0
        for e in self.inserts:
            if e <= packed:
                n += 1
            else:
                break
        return packed + 2 * n


def make_plan(entities: list[int]) -> Plan:
    shift = 0
    inserts: list[int] = []
    shift_at: dict[int, int] = {}
    for e in sorted(set(entities)):
        if (e + shift) & 3:
            inserts.append(e)
            shift += 2
        shift_at[e] = shift
    return Plan(sorted(set(entities)), inserts, shift, shift_at)


def apply_plan(text: bytes, code: int, plan: Plan) -> bytes:
    out = bytearray()
    pos = 0
    for e in plan.inserts:
        off = e - code
        if off < pos:
            continue
        out += text[pos:off]
        out += b"\0\0"
        pos = off
    out += text[pos:]
    return bytes(out)


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def kernel_text(rom: bytes, uid3: int):
    images = romimage.scan_images(rom)
    reach = romimage.reachable_images(images)
    im = next((x for x in reach if x.uid3 == uid3), None)
    if im is None:
        raise SystemExit(f"uid3 {uid3:#010x} not reachable from the kernel")
    return im, rom[im.text.file_off:im.text.file_end]


def build_plan(rom: bytes, uid3: int):
    """Decode the image and return (image, text, functions, pools, plan)."""
    im, text = kernel_text(rom, uid3)
    code = im.text.va
    seeds = find_seeds(text, code)
    funcs: list[Func] = []
    rejected = 0
    seen_starts: set[int] = set()
    for seed, mode in seeds:
        if seed in seen_starts:
            continue
        f = discover_function(text, code, seed, mode)
        if f is None:
            rejected += 1
            continue
        funcs.append(f)
        seen_starts.add(seed)
    groups = find_pools(text, code, funcs)
    pools = [s for s in sorted(groups) if not is_data_table(groups, s)]
    plan = make_plan(sorted(seen_starts | set(pools)))
    return im, text, funcs, groups, pools, plan, rejected, len(seeds)


def analyse(rom: bytes, uid3: int) -> dict:
    im, text, funcs, groups, pools, plan, rejected, nseeds = build_plan(rom, uid3)
    code = im.text.va
    seen_starts = {f.start for f in funcs}

    # Which entities actually required padding, and why.
    inserts = []
    kinds = {p: "pool" for p in pools}
    for s in seen_starts:
        kinds.setdefault(s, "func")
    for e in plan.inserts:
        inserts.append({"packed": f"{e:#010x}", "kind": kinds.get(e, "func")})

    pool_report = []
    pools_aligned = 0
    for s in pools:
        aligned = plan.move(s) % 4 == 0
        pools_aligned += aligned
        pool_report.append({
            "packed": f"{s:#010x}",
            "final": f"{plan.move(s):#010x}",
            "aligned": aligned,
            "refs": len(groups[s]),
        })

    # BL diagnostic: where does an encoded target land in the final layout?
    bl_exact = bl_entity = bl_other = 0
    finals = {plan.move(e) for e in plan.entities}
    for f in funcs:
        for site, packed_target in f.calls:
            final_site = plan.move(site)
            # The packed target recorded by Capstone is site+8+rel in the
            # *packed* layout; the linker's encoded offset is the same, so
            # add the site's shift to get the final encoded target.
            final_target = packed_target + plan.move(site) - site
            if final_target in finals:
                bl_entity += 1
            elif final_target % 4 == 0:
                bl_exact += 1
            else:
                bl_other += 1

    return {
        "uid3": f"{uid3:#010x}",
        "code": f"{code:#010x}",
        "text_size": len(text),
        "seeds": nseeds,
        "functions": len(funcs),
        "rejected_seeds": rejected,
        "pools": len(pools),
        "pools_aligned": pools_aligned,
        "pool_groups": len(groups),
        "inserts": len(plan.inserts),
        "shift": plan.shift,
        "text_size_after": len(text) + plan.shift,
        "shift_at": {
            "first_call_callee": f"{plan.move(0x5031261C):#010x}",
            "entry_pool": f"{plan.move(0x5031008E):#010x}",
        },
        "insert_points": inserts[:200],
        "pools_report": pool_report[:200],
        "bl_lands_on_entity": bl_entity,
        "bl_lands_aligned": bl_exact,
        "bl_misaligned": bl_other,
    }


def cmd_analyze(a):
    rom = open(a.rom, "rb").read()
    rep = analyse(rom, a.uid3)
    print(f"uid3 {rep['uid3']} text {rep['text_size']:#x} at {rep['code']}")
    print(f"  seeds {rep['seeds']}, decoded functions {rep['functions']} "
          f"({rep['rejected_seeds']} rejected)")
    print(f"  literal pools {rep['pools']} (raw groups {rep['pool_groups']})")
    print(f"  insertions {rep['inserts']} -> shift {rep['shift']:#x} bytes, "
          f"text becomes {rep['text_size_after']:#x}")
    print(f"  entry pool -> {rep['shift_at']['entry_pool']}  "
          f"first call callee -> {rep['shift_at']['first_call_callee']}")
    print(f"  direct calls: {rep['bl_lands_on_entity']} land on an entity, "
          f"{rep['bl_lands_aligned']} on another aligned address, "
          f"{rep['bl_misaligned']} misaligned")
    bad = [p for p in rep['pools_report'] if not p['aligned']]
    print(f"  pools aligned after plan: {rep['pools_aligned']}/{rep['pools']}")
    for p in bad[:8]:
        print(f"    ! pool {p['packed']} -> {p['final']} not aligned")
    if a.json:
        open(a.json, "w").write(json.dumps(rep, indent=1))
        print(f"-> {a.json}")


def cmd_build(a):
    rom = open(a.rom, "rb").read()
    rep = analyse(rom, a.uid3)
    im, text, funcs, groups, pools, plan, _, _ = build_plan(rom, a.uid3)
    code = im.text.va
    out = apply_plan(text, code, plan)
    open(a.output, "wb").write(out)
    print(f"wrote {a.output}: {len(text):#x} -> {len(out):#x} bytes "
          f"({len(plan.inserts)} insertions, shift {plan.shift:#x})")
    payload = dict(rep)
    payload["output"] = a.output
    payload["insert_points"] = [f"{e:#010x}" for e in plan.inserts]
    if a.json:
        open(a.json, "w").write(json.dumps(payload, indent=1))
        print(f"-> {a.json}")


def cmd_verify(a):
    rom = open(a.rom, "rb").read()
    im, text, funcs, groups, pools, plan, _, _ = build_plan(rom, a.uid3)
    code = im.text.va
    out = open(a.output, "rb").read()
    if len(out) != len(text) + plan.shift:
        print(f"  ! output size {len(out):#x}, want {len(text) + plan.shift:#x}")
        return 1
    # The entry's first ldr is at packed 0x50310070.  Its target is relative,
    # so compute it from the *final* instruction address.
    packed_ldr = 0x50310070
    final_ldr = plan.move(packed_ldr)
    imm = (u16(text, packed_ldr - code) & 0xFF) * 4
    final_target = ((final_ldr + 4) & ~3) + imm
    word = u32(out, final_target - code)
    print(f"entry ldr: packed {packed_ldr:#010x} -> final {final_ldr:#010x}; "
          f"literal at {final_target:#010x}")
    print(f"  word = {word:#010x} (want 0x00046564)")
    ok = word == 0x00046564
    # Every literal pool must be 4-byte aligned in the final layout.
    bad = [(p, plan.move(p)) for p in pools if plan.move(p) % 4]
    for p, fin in bad[:8]:
        print(f"  ! pool {p:#010x} -> {fin:#010x} misaligned")
    print(f"pools: {len(pools) - len(bad)}/{len(pools)} aligned after relayout")
    if bad:
        ok = False
    print("relayout verify OK" if ok else "relayout verify FAILED")
    return 0 if ok else 1


def cmd_image(a):
    """Experimental: kernel text relaid into the faithful flat runtime image.

    The kernel text grows into the old .data area, so .data is copied to a
    free slot before the first ROMFS file and the header's data/size fields
    are updated.  Everything after the kernel (DLLs, ROMFS) stays put; the
    `--rom-image` loader uses the header, not the packed records.
    """
    rom = open(a.rom, "rb").read()
    base = bytearray(open(a.base, "rb").read())
    im, text, funcs, groups, pools, plan, _, _ = build_plan(rom, a.uid3)
    code = im.text.va
    relaid = apply_plan(text, code, plan)

    # The kernel text is the only image that moves; keep the DLLs at their
    # stored addresses.  Place the ROM copy of .data in the free gap between
    # the last reachable image and the first ROMFS file.
    hdr_va = code - 0x64
    old_data = im.data_addr
    data_size = im.data_size
    new_data = a.data_addr
    if new_data + data_size > 0x51600000:
        raise SystemExit("new .data address is outside the ROM")

    def put(va, data):
        off = va - romimage.ROM_BASE
        if off < 0 or off + len(data) > len(base):
            raise SystemExit(f"{va:#x}+{len(data):#x} outside the flat image")
        base[off:off + len(data)] = data

    # Take .data from the packed record: the grown text may overwrite the
    # start of the old copy in the flat image.
    s = im.section("data")
    data_bytes = rom[s.file_off:s.file_end] if s is not None else b""
    put(new_data, data_bytes)
    put(code, relaid)
    # Patch the header in place (it sits at code-0x64).
    hoff = hdr_va - romimage.ROM_BASE
    struct.pack_into("<I", base, hoff + 0x18, new_data)
    struct.pack_into("<I", base, hoff + 0x1C,
                     len(relaid) + im.export_count * 4)
    struct.pack_into("<I", base, hoff + 0x20, len(relaid))
    open(a.output, "wb").write(base)
    print(f"wrote {a.output}")
    print(f"  kernel text {len(text):#x} -> {len(relaid):#x} at {code:#x}")
    print(f"  .data {old_data:#x} -> {new_data:#x} ({data_size:#x} bytes)")
    print(f"  header {hdr_va:#x}: text_size {len(relaid):#x}, "
          f"code_size {len(relaid) + im.export_count * 4:#x}, "
          f"data {new_data:#x}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("analyze")
    a.add_argument("rom")
    a.add_argument("--uid3", type=lambda s: int(s, 0), default=KERNEL_UID3)
    a.add_argument("--json")
    a.set_defaults(func=cmd_analyze)

    b = sub.add_parser("build")
    b.add_argument("rom")
    b.add_argument("output")
    b.add_argument("--uid3", type=lambda s: int(s, 0), default=KERNEL_UID3)
    b.add_argument("--json")
    b.set_defaults(func=cmd_build)

    v = sub.add_parser("verify")
    v.add_argument("rom")
    v.add_argument("output")
    v.add_argument("--uid3", type=lambda s: int(s, 0), default=KERNEL_UID3)
    v.set_defaults(func=cmd_verify)

    i = sub.add_parser("image")
    i.add_argument("rom")
    i.add_argument("base", help="faithful flat image (out/6600_runtime.bin)")
    i.add_argument("output")
    i.add_argument("--uid3", type=lambda s: int(s, 0), default=KERNEL_UID3)
    i.add_argument("--data-addr", type=lambda s: int(s, 0), default=0x50400000,
                   help="new ROM address for the kernel .data copy")
    i.set_defaults(func=cmd_image)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
