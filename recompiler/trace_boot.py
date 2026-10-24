#!/usr/bin/env python3
"""Boot tracer for the Nokia 6600 (NHL-10) EKA1 firmware.

Two entry points are useful while bringing the image up:

  * `--rom`    start at the ROM vector table (0x5000_0000).  This is the
               image's own exception-vector table; the real mask ROM normally
               sets up the MMU and jumps into the kernel.
  * `--kernel` copy the kernel E32Image code to its link address (0x5031_0000)
               and start at the Thumb entry 0x5031_0054.  This is the useful
               one: it skips the missing mask ROM.

Unicorn is used as a *research* CPU here, not as the project's execution
engine.  CP15 (MMU/cache) writes are patched out so the image runs against a
flat memory map; the page map in the runtime is the eventual replacement.

    py trace_boot.py --kernel 6600_mcu.bin fw/6600_kernel.bin
    py trace_boot.py --rom    6600_mcu.bin
"""
import argparse
import struct
import sys
from unicorn import (Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_MODE_LITTLE_ENDIAN,
                     UC_HOOK_CODE, UC_HOOK_MEM_WRITE, UC_HOOK_MEM_UNMAPPED,
                     UcError)
from unicorn.arm_const import (UC_ARM_REG_PC, UC_ARM_REG_CPSR, UC_ARM_REG_LR,
                               UC_ARM_REG_SP, UC_ARM_REG_R0, UC_ARM_REG_R1,
                               UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_R4,
                               UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
                               UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10,
                               UC_ARM_REG_R11, UC_ARM_REG_R12)

BASE = 0x50000000
KERNEL_CODE = 0x50310000
KERNEL_ENTRY = 0x50310054
RAM_BASE = 0x80000000


def load_rom(path):
    raw = open(path, 'rb').read()
    if b'WD2 BT2' in raw[:0x20] and b'WD2 ALGORITHM' in raw[:0x40]:
        needle = bytes.fromhex('750100ea780100ea7b0100ea')
        off = raw.find(needle)
        if off < 0:
            raise SystemExit('WD2 container has no ROM vector table')
        print(f'WD2 container: ROM image at +{off:#x}, {len(raw)-off:#x} bytes')
        return raw[off:]
    return raw


def patch_cp15(uc, addr, data):
    """Turn CP15 MRC/MCR words into MOV/NOP.  Only call on ARM-aligned code."""
    n = 0
    for off in range(0, len(data) - 3, 4):
        w = struct.unpack_from('<I', data, off)[0]
        if (w & 0x0F000010) == 0x0E000010 and ((w >> 8) & 0xF) == 0xF:
            val = (0xE3A00000 | (((w >> 12) & 0xF) << 12)) if (w & (1 << 20)) else 0xE1A00000
            uc.mem_write(addr + off, struct.pack('<I', val))
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom')
    ap.add_argument('--kernel', metavar='KERNEL_BIN')
    ap.add_argument('--rom-entry', action='store_true')
    ap.add_argument('--patch-cp15', action='store_true')
    ap.add_argument('--count', type=int, default=200000)
    a = ap.parse_args()

    rom = load_rom(a.rom)
    uc = Uc(UC_ARCH_ARM, UC_MODE_ARM | UC_MODE_LITTLE_ENDIAN)
    # The ROM image is mapped at its link address.  Keep the whole 22 MiB area
    # reachable; the kernel and its data live inside it.
    uc.mem_map(BASE, 0x1800000)
    uc.mem_write(BASE, rom[:0x1800000])
    uc.mem_map(RAM_BASE, 0x8000000)          # generous SDRAM window
    uc.mem_map(0x0, 0x100000)                # low vectors / boot scratch
    uc.mem_map(0xFFFF0000, 0x10000)          # high vectors

    entry = BASE
    thumb = False
    if a.kernel:
        k = open(a.kernel, 'rb').read()
        print(f'rom {len(rom):#x}, kernel {len(k):#x}, code {KERNEL_CODE:#x}')
        uc.mem_write(KERNEL_CODE, k)
        entry = KERNEL_ENTRY
        thumb = True
        print(f'kernel: {len(k):#x} bytes at {KERNEL_CODE:#x}, entry {entry:#x} (Thumb)')
    elif a.rom_entry:
        entry = BASE
    else:
        # Default: the kernel path is what we want; fall back to the ROM reset
        # vector when no kernel was supplied.
        pass

    if a.patch_cp15:
        n = patch_cp15(uc, BASE, rom)
        if a.kernel:
            n += patch_cp15(uc, KERNEL_CODE, open(a.kernel, 'rb').read())
        print(f'patched {n} CP15 words')

    trace = []
    def hook_code(uc, address, size, user):
        if len(trace) < 4000:
            trace.append(address)
    def hook_mem(uc, access, address, size, value, user):
        if len(trace) < 4000:
            print(f'  mem {access} {address:#010x} size={size} val={value:#x} '
                  f'pc={uc.reg_read(UC_ARM_REG_PC):#x}')
    def hook_unmapped(uc, access, address, size, value, user):
        print(f'UNMAPPED {access} addr={address:#x} size={size} '
              f'pc={uc.reg_read(UC_ARM_REG_PC):#x}')
        return False
    uc.hook_add(UC_HOOK_CODE, hook_code)
    uc.hook_add(UC_HOOK_MEM_WRITE, hook_mem)
    uc.hook_add(UC_HOOK_MEM_UNMAPPED, hook_unmapped)

    for reg in range(UC_ARM_REG_R0, UC_ARM_REG_R12 + 1):
        uc.reg_write(reg, 0)
    uc.reg_write(UC_ARM_REG_SP, 0x80300000)
    uc.reg_write(UC_ARM_REG_LR, 0)
    # SVC mode, IRQ/FIQ masked, Z set (cold boot) and T when starting in Thumb.
    cpsr = 0x400000D3
    start = entry
    if thumb:
        cpsr |= 0x20
        start = entry | 1
    uc.reg_write(UC_ARM_REG_CPSR, cpsr)
    try:
        uc.emu_start(start, 0, count=a.count)
    except UcError as e:
        print('UcError', e, 'pc', hex(uc.reg_read(UC_ARM_REG_PC)))
    print('final pc', hex(uc.reg_read(UC_ARM_REG_PC)))
    print('first pcs', [hex(x) for x in trace[:40]])
    print('unique pcs', len(set(trace)))


if __name__ == '__main__':
    main()
