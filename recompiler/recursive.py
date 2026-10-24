#!/usr/bin/env python3
"""recursive.py — mode-aware recursive function discovery for ARMv4T images.

The 6600 kernel is not uniformly Thumb: ARMv4T has no immediate BLX, so the
compiler emits small interworking veneers

    mov lr, pc
    bx  lr          ; lr is even -> switch to ARM at the next instruction

and the reverse in ARM.  A linear Thumb sweep decodes the ARM functions as
garbage, which is exactly where the first kernel trace stops.

This scanner starts at a known entry, follows BL/BLX and `ldr pc, [pc, #imm]`
veneers, and treats the instruction after a Thumb `mov lr,pc; bx lr` as an ARM
function.  It writes the same functions.json shape as extract.py, so lift.py and
gen_register.py work unchanged.

    py recursive.py fw/6600_kernel.bin functions.json \
        --base 0x50310000 --entry 0x50310054 --thumb

It is intentionally conservative: unresolved indirect branches end a function,
and a function is capped at --max-bytes.  The result is a bring-up worklist, not
a proof of complete coverage.
"""
import argparse
import json
import struct
import sys
from capstone import (Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB,
                      CS_MODE_LITTLE_ENDIAN, CS_GRP_CALL)
from capstone.arm import ARM_OP_IMM, ARM_OP_REG, ARM_OP_MEM, ARM_REG_PC, ARM_REG_LR


def is_return(ins, thumb):
    m = ins.mnemonic.split('.')[0]
    if m == 'pop' and any(op.type == ARM_OP_REG and op.reg == ARM_REG_PC for op in ins.operands):
        return True
    if m == 'bx' and ins.operands and ins.operands[0].type == ARM_OP_REG \
            and ins.operands[0].reg == ARM_REG_LR:
        return True
    if m == 'mov' and len(ins.operands) == 2 and ins.operands[0].type == ARM_OP_REG \
            and ins.operands[0].reg == ARM_REG_PC:
        return True
    if m == 'ldr' and ins.operands and ins.operands[0].type == ARM_OP_REG \
            and ins.operands[0].reg == ARM_REG_PC:
        return True
    return False


def is_mov_lr_pc(ins):
    return (ins.mnemonic.split('.')[0] == 'mov' and len(ins.operands) == 2
            and ins.operands[0].type == ARM_OP_REG and ins.operands[0].reg == ARM_REG_LR
            and ins.operands[1].type == ARM_OP_REG and ins.operands[1].reg == ARM_REG_PC)


def ldr_pc_literal(ins):
    """Return the literal address for `ldr pc, [pc, #imm]`, else None."""
    if ins.mnemonic.split('.')[0] != 'ldr' or not ins.operands:
        return None
    if ins.operands[0].type != ARM_OP_REG or ins.operands[0].reg != ARM_REG_PC:
        return None
    if len(ins.operands) < 2 or ins.operands[1].type != ARM_OP_MEM:
        return None
    mem = ins.operands[1]
    if mem.mem.base != ARM_REG_PC:
        return None
    # PC in ARMv4T is address+8 for ARM, address+4 for Thumb.
    pc = ins.address + (4 if ins.size == 2 else 8)
    return (pc + mem.disp) & 0xffffffff


def seed_veneers(data, base):
    """Find ARMv4T interworking stubs and return their target starts.

    Thumb -> ARM:  mov lr, pc ; bx lr   (fe 46 70 47); ARM begins after the bx
    ARM -> Thumb:  add lr, pc, #1 ; bx lr
                   (01 e0 8f e2 1e ff 2f e1); Thumb begins after the bx
    """
    out = []
    i = 0
    while True:
        i = data.find(b'\xfe\x46\x70\x47', i)
        if i < 0:
            break
        if i % 2 == 0:
            out.append((i + 4, False))
        i += 1
    i = 0
    pat = b'\x01\xe0\x8f\xe2\x1e\xff\x2f\xe1'
    while True:
        i = data.find(pat, i)
        if i < 0:
            break
        if i % 4 == 0:
            out.append((i + 8, True))
        i += 1
    return [(base + off, th) for off, th in out]


def scan(data, base, entry, thumb, max_bytes):
    md_a = Cs(CS_ARCH_ARM, CS_MODE_ARM + CS_MODE_LITTLE_ENDIAN); md_a.detail = True
    md_t = Cs(CS_ARCH_ARM, CS_MODE_THUMB + CS_MODE_LITTLE_ENDIAN); md_t.detail = True
    work = [(entry & ~1, bool(thumb))] + seed_veneers(data, base)
    seen = set()
    funcs = []
    while work:
        addr, th = work.pop()
        if (addr, th) in seen:
            continue
        seen.add((addr, th))
        off = addr - base
        if off < 0 or off + 2 > len(data):
            continue
        md = md_t if th else md_a
        window = data[off:off + max_bytes]
        decoded = []
        end = addr
        for ins in md.disasm(window, addr):
            decoded.append(ins)
            end = ins.address + ins.size
            nxt = end
            m = ins.mnemonic.split('.')[0]

            # Thumb -> ARM interworking veneer: mov lr,pc; bx lr.
            if th and m == 'bx' and decoded[-2:-1] and is_mov_lr_pc(decoded[-2]):
                work.append((nxt & ~1, False))
                break

            if ins.group(CS_GRP_CALL) and ins.operands:
                op = ins.operands[0]
                if op.type == ARM_OP_IMM:
                    t = op.imm & 0xffffffff
                    if th:
                        work.append((t & ~1, True))
                    else:
                        work.append((t & ~1, False))
                else:
                    break

            if m == 'ldr' and ins.operands and ins.operands[0].type == ARM_OP_REG \
                    and ins.operands[0].reg == ARM_REG_PC:
                la = ldr_pc_literal(ins)
                if la is not None:
                    lo = la - base
                    if 0 <= lo + 4 <= len(data):
                        t = struct.unpack_from('<I', data, lo)[0]
                        work.append((t & ~1, bool(t & 1)))
                break

            if m == 'bx' and ins.operands and ins.operands[0].type == ARM_OP_REG \
                    and ins.operands[0].reg != ARM_REG_LR:
                break   # unresolved indirect branch

            if is_return(ins, th):
                break

            if m == 'b' and not ins.group(CS_GRP_CALL) and ins.operands \
                    and ins.operands[0].type == ARM_OP_IMM:
                t = ins.operands[0].imm & 0xffffffff
                # A forward branch out of the current window is a tail call;
                # a backward branch is a loop and stays in this function.
                if t > nxt and t not in {i.address for i in decoded}:
                    work.append((t & ~1, th))
                    break
            if end - addr >= max_bytes:
                break

        if decoded:
            funcs.append({
                'name': 'func_%08x' % addr,
                'start': addr,
                'end': end,
                'size': end - addr,
                'thumb': th,
                'bytes': data[off:off + (end - addr)].hex(),
            })
    return funcs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('out')
    ap.add_argument('--base', default='0x50310000')
    ap.add_argument('--entry', required=True)
    ap.add_argument('--thumb', action='store_true')
    ap.add_argument('--extra-entry', action='append', default=[],
                    help='additional ARM entry point (repeatable)')
    ap.add_argument('--max-bytes', type=int, default=0x400)
    a = ap.parse_args()
    base = int(a.base, 0)
    entry = int(a.entry, 0)
    data = open(a.image, 'rb').read()
    funcs = scan(data, base, entry, a.thumb, a.max_bytes)
    for e in a.extra_entry:
        funcs += scan(data, base, int(e, 0) & ~1, False, a.max_bytes)
    # de-duplicate by start + mode
    seen = set(); merged = []
    for f in sorted(funcs, key=lambda f: (f['start'], f['thumb'])):
        k = (f['start'], f['thumb'])
        if k not in seen:
            seen.add(k); merged.append(f)
    funcs = merged
    funcs.sort(key=lambda f: (f['start'], f['thumb']))
    out = {'functions': funcs,
           'segments': [{'start': base, 'end': base + len(data), 'bytes': data.hex()}]}
    json.dump(out, open(a.out, 'w'))
    thumb = sum(1 for f in funcs if f['thumb'])
    print(f'{len(funcs)} functions ({thumb} Thumb, {len(funcs)-thumb} ARM), '
          f'{sum(f["size"] for f in funcs)} bytes -> {a.out}')


if __name__ == '__main__':
    main()
