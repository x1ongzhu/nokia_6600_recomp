# Architecture

nokia-recomp follows the static-recompilation shape: do the hard analysis
offline, emit plain C, and link it against a small native runtime. The phone's
ARM code becomes the program; a native ARMv4T interpreter is used for bring-up
and for callees that have not been lifted yet.

The difference from a game recomp is the target: not a game on an OS, but the
**whole phone firmware** — a bare-metal Nokia EKA1 ROM with no host OS
underneath it.

## Pipeline

```
   NHL105530.C1 (WD2 BT2 / WD2 ALGORITHM container)
            │  wd2.py extract
            ▼
   6600_mcu.bin   (flash: 852 × [0xec header + 0x2000 payload] + boot area)
            │  pagestream.py build  (drop page headers)
            ▼
   packed stream  (0x1605ed8 B)
            │  romimage.py build   (place every image/section at its VA)
            ▼
   out/6600_runtime.bin  (flat 22 MiB runtime image)
            │
            ├── runtime/test/boot_kernel.c --rom-image   (interpreter boot)
            └── recursive.py + lift.py                   (static ARM/Thumb → C)
```

Module split:

| Layer | Location | Responsibility |
|---|---|---|
| input | `recompiler/wd2.py` | WD2 container, EKA1 ROM header, kernel E32Image, ROMFS |
| normalise | `recompiler/pagestream.py` | remove the 0xec page headers; page grid invariants |
| layout | `recompiler/romimage.py`, `layout.py`, `imports.py`, `euser_reloc.py` | flat image, export/IAT map, kernel→EUser relocation |
| lift | `recompiler/recursive.py`, `lift.py` | mixed ARM/Thumb discovery → C |
| runtime | `runtime/src/nokia_interp.c`, `nokia_rt.c` | ARMv4T core, sparse memory, MMIO |
| boot harness | `runtime/test/boot_kernel.c` | load flat image, install hand-offs, run/stop |

## Memory map

The 6600 is a **DCT4 / UPP_WD2 (ARM920T)** phone. The relevant regions:

| Region | Address | Notes |
|---|---|---|
| ROM | `0x50000000..0x51600000` | code, ROM header, ROMFS directories/data |
| RAM | `0x80000000` + | kernel data/bss; 3 MiB default, `NK_RAM_EXTRA` extends to 6 MiB |
| pre-MMU physical RAM | `0x00000000..` | bring-up alias; the early literal pools use physical offsets |
| super page | `0x40000000..0x40010000` | mask-ROM hand-off page; `TMachineConfig` at `+0x800` |
| low vectors | `0x00000000` | kernel text head (`NK_KERNEL_VECTORS`) |
| high vectors | `0xffff0000` | same |
| MMIO | outside the above | display/keypad/timer/UPP stubs |

`runtime/include/nokia_cpu.h` models this as a **sparse 64 KiB page map**, not a
single `mem + address` blob. `nk_r32`/`nk_w32` take a one-page fast path;
cross-page or unmapped accesses go through `nokia_rt.c`, where MMIO shims live.

## Runtime

`runtime/src/nokia_interp.c` implements ARMv4T (ARM + Thumb):

- data processing, shifts, loads/stores, LDM/STM, MUL/MLA,
  **UMULL/UMLAL/SMULL/SMLAL**, MRS/MSR, BX/BLX, SWI, CP15;
- CPSR flags and banked modes (`NK_BANKED`), SPSR exception return;
- crash recovery, per-call-site repair (`NK_CALLMAP`), code-range guard,
  spin watchdog, PC watch, `b .` panic halt;
- EKA1 executive call gate (`NK_SWI_DIRECT`): `svc #N` → kernel service table
  `0x50314aec` with the caller's LR live.

`nk_call` can hand an unlifted callee to the interpreter
(`NK_INTERP_FALLBACK=1`); lifted C and the interpreter share the same bus.

## Imports and EUser ABI

EKA1 import stubs are:

```
ldr ip,[pc]      ; e59fc000
ldr pc,[ip]      ; e59cf000
.word <slot>     ; address of the exporter's .edata entry
```

The kernel was linked against an EUser `.def` one export shorter than the
generic 7.0 list, while the ROM's EUser is four shorter. For `K>=6`,
`kernel ordinal K → ROM export K-3`; K=0/1/2 are memset/`Mem::Copy`/
`User::Alloc`; K=1361 is the only remaining local exception (TStack/TBuf
constructor `0x503a023c`). The boot profile
[`config/imports-r29-6600.txt`](../config/imports-r29-6600.txt) encodes this.
ELocl's single hole (ordinal 20) is bound by
[`config/imports-6600.txt`](../config/imports-6600.txt).

## Boot state

Booting the E32 entry directly skips the mask ROM, which normally supplies:

- `[0x400000d0]` = the `ekern.exe` TRomEntry (`0x50301ec4`);
- a writable copy of the 64 KiB ROMFS directory (`NK_PRIMARY_RAM`);
- the initial TTime at `0x50000084` (`NK_SYSTEM_TIME`);
- the current-thread/process/object-index graph (`NK_B7E`);
- per-thread `CTrapCleanup` (`NK_TRAPCLEAN`);
- an extension export stub for nested images without exports (`NK_EXT_STUB`).

These are explicit models, not mask-ROM decryption. Details and the exact
instruction sequences are in [`BOOT.md`](BOOT.md).

## HLE boundary

The runtime answers hardware the phone expects:

- sparse ROM/RAM plus MMIO bus; UPP boot handshake stubs;
- HAL timer frequency (`NK_HAL_TIMER_HZ`), RTC/allocator stand-ins;
- framebuffer/keypad/audio are **not implemented yet**.

The rule is: keep the guest's own logic; only replace hardware and OS services
that cannot exist on the host. Unknown services should fail loudly, not return
success.

## Status

| Stage | State |
|---|---|
| extraction / stream / layout / imports | done, pinned by tests |
| interpreter + EUser relocation | done (round 29 fixed long multiply and non-S flags) |
| faithful kernel boot | reaches idle loop `0x50310f84` (3,000,000 insns, 0 faults) |
| timer/DFC IRQ | **next** |
| display/keypad/audio/file server/apps | not started |

Acceptance tests and the current frontier:
[`PROGRESS.md`](PROGRESS.md), [`tools/test_round29.sh`](../tools/test_round29.sh).
