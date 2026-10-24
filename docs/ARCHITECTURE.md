# Architecture

nokia-recomp follows the proven **static recompilation** shape: do the hard
analysis *offline*, emit plain C, and link it against a small native runtime.
Nothing is interpreted at runtime — the phone's ARM code becomes the program.

This is the same pattern as N64Recomp and our sibling project
[ngagerecomp](https://github.com/sp00nznet/ngagerecomp). The difference is the
target: not a game on an OS, but the **whole phone firmware** — a bare-metal
Nokia EKA1 ROM with no host OS underneath it.

## The pipeline

```
   NHL105530.C1 (WD2 BT2 / WD2 ALGORITHM container)
            │  wd2.py extract
            ▼
   6600_mcu.bin   (raw EKA1 ROM, linked at 0x50000000)
            │
            ▼
   ┌──────────────────┐   ROM header + E32Image headers + ROMFS,
   │  recompiler/     │   recover function boundaries, lift each
   │  (static ARM→C)  │──▶ ARMv4(T) instruction to portable C
   └──────────────────┘
            │  generated C
            ▼
   ┌──────────────────┐   ARM register/flag/memory model +
   │  runtime/        │   HLE for the Nokia OS: display, keypad,
   │  (nokia runtime)  │   timers, the GSM/RF stubs, flash/EEPROM
   └──────────────────┘
            │
            ▼
     native executable  (Windows / Linux / macOS)  — a runnable 6600
```

## The 6600 memory map

The 6600 is a **DCT4 / UPP_WD2 (ARM920T)** phone, not a flat 5.4 MB MCU.
The image recovered from `NHL105530.C1` tells us the important addresses:

| region | address | notes |
|---|---|---|
| ROM code | `0x50000000` | 22 MiB, execute-in-place, EKA1 vector table |
| ROM export/data | inside the same ROM | `0x5030xxxx` headers, `0x51xxxxxx` files |
| kernel data / RAM | `0x80000000` .. `0x80300000` | 3 MiB, from the ROM header |
| high vectors | `0xffff0000` | ARM exception vectors after MMU setup |
| mask ROM | `0x00e00000` | **not in the flash dump**; entry `0x00e0ca39` |
| UPP MMIO | outside the above | display/keypad/timers/DSP, stubbed first |

`runtime/include/nokia_cpu.h` models this as a **sparse 64 KiB page map**, not
a single `mem + address` blob.  `nk_r32`/`nk_w32` take a one-page fast path;
anything else (cross-page or unmapped) goes through `nokia_rt.c`, which is
where the MMIO device shims live.

## The kernel

The EKA1 kernel is an E32Image with UID3 **`0x100058e8`**.  Its header lives at
ROM `0x3268c0` and describes the code at link address **`0x50310000`**, entry
**`0x50310054`**.  `wd2.py kernel` carves the 168 KiB code image; the EKA1
loader normally relocates/copies it to the link address before the first
instruction.  A byte-exact memcpy reaches the entry and runs the first 423
Thumb instructions under the research tracer; the remaining work is the
loader's relocation/compression step (the `KaeP`/packed region) and the ARM ↔
Thumb interworking at function boundaries.

## The HLE boundary

A DCT4 phone has no Symbian DLL import table to lean on: the firmware talks
straight to the UPP.  The runtime therefore grows one device at a time:

- **Display** — 176x208 16-bit TFT; the framebuffer is memory, so the first
  visible milestone is a host window.
- **Keypad / timers / RTC** — host input and monotonic time.
- **Flash/EEPROM** — the ROM image plus a writable backing file.
- **GSM / DSP / CDMA** — stubbed.  The first finish line is a UI-only phone
  that boots to "no network" and runs.

## Stages

1. **Front end** — `wd2.py` extracts the EKA1 ROM; `extract.py`/`extract_ida.py`
   recover functions; the ROMFS is browsable via `wd2.py list`.
2. **Lifter** — ARMv4T + Thumb → C, against the sparse-memory `nk_cpu_t`.
3. **Runtime** — sparse memory + MMIO bus (`nokia_rt.c`), then display, input,
   timers, and the radio stubs.
4. **Boot** — the EKA1 kernel entry at `0x50310054` after the loader's
   relocation step; the mask ROM at `0x00e00000` is not part of the image.

The first target milestone remains the **Nokia startup screen and idle UI** on
a host window.  Calls, signal, and the cellular stack come later (or never — a
UI simulator is a legitimate finish line).

Current progress, the exact boot frontier and the phased plan are in
[`PROGRESS.md`](PROGRESS.md) and [`BOOT.md`](BOOT.md).
