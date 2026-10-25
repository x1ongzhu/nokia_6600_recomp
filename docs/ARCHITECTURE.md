# Architecture

nokia-recomp follows the proven **static recompilation** shape: do the hard
analysis *offline*, emit plain C, and link it against a small native runtime.
The phone's ARM code becomes the program; a small interpreter is kept for
bring-up and for callees that have not been lifted yet, not as the shipping
execution model.

This is the same pattern as N64Recomp and our sibling project
[ngagerecomp](https://github.com/sp00nznet/ngagerecomp). The difference is the
target: not a game on an OS, but the **whole phone firmware** — a bare-metal
Nokia EKA1 ROM with no host OS underneath it.

## The pipeline

```
   NHL105530.C1 (WD2 BT2 / WD2 ALGORITHM container)
            │  wd2.py extract
            ▼
   6600_mcu.bin   (packed flash: image records + ROMFS)
            │  romimage.py build
            ▼
   out/6600_runtime.bin  (flat 22 MiB runtime ROM)
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
   │                  │   + native ARMv4T interpreter (bring-up/fallback)
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
| ROM code | `0x50000000` | 23.3 MB flash image (declared `rom_size` 22 MiB), EKA1 vector table |
| ROM export/data | inside the same ROM | `0x5030xxxx` headers, `0x51xxxxxx` files |
| kernel data / RAM | `0x80000000` .. `0x80300000` | 3 MiB, from the ROM header |
| pre-MMU physical RAM | `0x00000000` .. `0x00300000` | bring-up alias: the early entry's literal pools contain physical data offsets (`0x0004_6564`) before the MMU remaps RAM to `0x80000000`; `NK_NO_LOW_RAM=1` disables it |
| high vectors | `0xffff0000` | ARM exception vectors after MMU setup |
| mask ROM | `0x00e00000` | **not in the flash dump**; entry `0x00e0ca39` |
| UPP MMIO | outside the above | display/keypad/timers/DSP, stubbed first |

`runtime/include/nokia_cpu.h` models this as a **sparse 64 KiB page map**, not
a single `mem + address` blob.  `nk_r32`/`nk_w32` take a one-page fast path;
anything else (cross-page or unmapped) goes through `nokia_rt.c`, which is
where the MMIO device shims live.  Round 15 adds the first three boot-time
stubs: UPP `0x58150422` returns bit `0x400`, `0x58120a08` returns non-zero, and
the RAM probe `0x41001400` returns bit 0.  They are enough for the secondary
loader to finish its UPP handshake; they are not a display/timer/keypad model.

`runtime/src/nokia_interp.c` adds a native **ARMv4T interpreter** (ARM + Thumb)
on top of the same bus.  It is the bring-up engine (P0) and the hybrid fallback:
`nk_call` can hand an unlifted callee to it with `NK_INTERP_FALLBACK=1`.  It
carries the CPSR T bit, a shadow call stack for mode restore, and an optional
`NK_INFER` mode that reports (or, at level 2, steps over) an unlinked
Thumb/ARM boundary.  The generator stays simple: lifted C calls `nk_call`,
which either dispatches to generated C or enters the interpreter.

Round 18 adds an explicit EKA1 **executive call gate**: EUser.dll implements
the user-side kernel API as single-instruction `svc #N` stubs, and
`NK_SWI_DIRECT=1` dispatches them through the kernel service table at
`0x50314aec` with the caller's LR still live.  `recompiler/executive.py`
decodes and verifies that 273-entry table (270 code targets, four zero slots).
The mode is a bring-up model, not the real SVC exception: the interpreter
still lacks banked registers, SPSR and a faithful exception return, which is
the next CPU-model task.  The run also exposed two loader gaps: the initial
scheduler/current-thread object (`[0x800017d4]`) and flat-image import binding
(IAT slot `0x5037d0e8` is `0xffffffff`).

The flash is **paged** as `0x20ec`-byte records: a **`0xec`-byte page header**
(first six bytes `20 00 00 00 dc 23`) followed by a **`0x2000`-byte payload**.
`recompiler/pagestream.py` removes the headers and makes the packed records
contiguous; round 16 showed that the kernel text/export layout only matches
the linked image after this step (469/478 exports, 98.1%).  The `KaeP`/PeaK
container at `0x124` is now unpacked by `kaep.py` (record `0x20` at `0x12e`,
image `0x1423dc` at `0x14e`); the 0x20-byte record's own codec is still
undocumented.  The boot-region table is modelled with explicit type/flag bits:
`0x1a1c` needs type 5..8 plus attr `0x04000000`, while `0x1b34` needs type 2.
`bootbank.py --stream` takes the stream slice `[0xb0, 0x100b0)` as the linked
boot bank (all switch tables bias 0); `bootregions.py --profile staging` uses
the `0xffffffff` no-expand sentinel for the type-2 RAM bank plus type-5 kernel
code/data section banks.  `bootbringup.py` combines that with the
`kaep.install` descriptor/boot-image node list and an executable
`ldr pc,[pc,#-4]; .word 0x50310054` handoff at linked `0x80`; the real loader
programs UPP, builds page tables and executes the handoff into the kernel
after 36,732 instructions.  The correct stream view instead stops in a
board/CPU detection panic at `0x624c`; the PeaK record codec remains open.

For the packed-image bring-up it also has:

- **call-target repair** (`NK_CALL_INFER`, `NK_SNAP_WINDOW_ARM/THUMB`) — the
  packed BL targets are stale *per call site*, so a target is snapped to the
  nearest real prologue; the shared basic blocks that must stay exact are why
  the window is bounded;
- **call-site fixups** (`NK_CALLMAP`) — a text file pinning one call site to
  its real callee, plus host-side HLE helpers (division, remainder, memzero,
  bump allocation) for compiler-runtime routines whose packed bytes are gone;
- **crash recovery** (`NK_RECOVER`) — every BL/BLX snapshots the caller state;
  if the callee faults (undefined instruction, PC escape), the call is treated
  as "returned 0", logged, and the caller resumes.  This is how a boot trace
  walks past stale calls instead of stopping at the first one.  It is a
  bring-up aid and is off by default;
- **spin watchdog** (`NK_SPIN`, `NK_SPIN_MAX`) — a tiny loop that revisits one
  PC thousands of times (usually a descriptor/string scan with a bogus
  argument) is rolled back through the same recovery frame instead of burning
  the instruction budget;
- **call ring / PC watch** (`NK_WATCH`, `NK_WATCH_LOG`) — a 64-entry ring of
  recent BL/BLX sites records the raw and resolved targets, modes and r0-r3/sp;
  reaching the watched PC prints the ring, which answers "how did we get here"
  without a full trace;
- **PC-space guard** (`NK_CODE_ONLY`) — a PC in RAM (or outside ROM, the low
  pre-MMU alias and high vectors) is a corrupted return, not code; the boot
  harness enables this by default;
- **text patches** (`config/patches-6600.txt`, applied by
  `romimage.py build --patch`) — restore bytes the packed flash does not
  contain (the first case is a Thumb function whose `pop` was overwritten by
  the following packed table).

## The kernel

The EKA1 kernel is an E32Image with UID3 **`0x100058e8`**.  Its header lives at
ROM `0x3268c0` (the normal **0x64-byte** EKA1 `TRomImageHeader`) and describes
the code at link address **`0x50310000`**, entry **`0x50310054`**.  `wd2.py
kernel` carves the 0x28ac0-byte text (iTextSize).

The image is a packed ROM record, not a linear copy: text, `.rdata`, `.data`,
`.edata` and the `TDllRefTable` are packed together and their runtime addresses
are independent of their file offsets.  The runtime loader (`boot_kernel.c`)
locates the sections backwards from the next header, loads the referenced DLLs
(UID3 `0x100065a5` and `0x100039e5`), and resolves import stubs through their
export directories.  `recompiler/romimage.py build` now reconstructs the
runtime ROM layout (all 725 packed images at their header addresses plus the
ROMFS tree); 1,580 sections are placed without overlaps in
`out/6600_runtime.bin`.

What remains is the ROM build's **interworking veneer insertion**: Thumb→ARM
calls and export targets are biased into the callee.  A census of the kernel's
3854 direct ARM `BL`s finds 478 exact entries, 3222 biased by 4..0x308 bytes,
and 154 with no nearby entry; some targets are legitimate shared basic
blocks, so a fixed snap radius is not a substitute for the linker.  The
interpreter exposes `NK_SNAP_WINDOW` and `NK_CALL_POLICY` to compare repair
strategies and reports the exact frontier.

The later bootstrap round showed that the stale offset is **per call site**,
not per function: two callers of the same routine can encode targets 0x18 and
0x78 bytes into it, and a target can land on a *valid* shared entry of an
unrelated neighbour.  This is why a single radius cannot resolve every site.
The bring-up stack now combines a bounded snap, an explicit per-site callmap,
host-side HLE for a few compiler helpers, and crash recovery.

**Round 16 correction.**  The apparent "function layout" problem was the
`0xec`-byte page headers: rounds 7-15 kept them inline, inserting `0xec` bytes
every `0x2000` bytes of every packed record.  `recompiler/pagestream.py`
removes them; on the resulting stream the kernel's 478 export entries (genuine
fixed-up addresses, small Thumb DLL 5/5) land on function starts **469 times
(98.1%)** and DLL `0x100039e5` **1757/1788 (98.3%)** at shift 0.  The real
ARM kernel entry runs **924,964 instructions** in the flat image (0 undefined,
0 call fixups, 0 recoveries) and stops at a stack/exception underrun at
`0x5039b2b8`.  The earlier "197-instruction entry", callmap, missing Thumb
`pop` and drift-null results are history.

The old text below is kept as a record of the wrong model:

The kernel's 478 export entries are genuine fixed-up function addresses (a
small Thumb DLL is 5/5), but only 82 (17.2%) land on a stored function start
versus a 13.1% random baseline; the big DLL is 14.4% versus 5.9%.  The stored
text already keeps 1,420/1,430 ARM starts and 759/787 pools 4-byte aligned, so
removed 2-byte padding (`0x58` in the plan) cannot explain it.  The next step
is layout-level recovery from the exports, call graph and literal code
pointers (`recompiler/layout.py` measures this; B1g2 in `PROGRESS.md`), not a
larger snap radius.  See [`BOOT.md`](BOOT.md).

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

1. **Front end** — `wd2.py` extracts the EKA1 ROM; `romimage.py` reconstructs
   the flat runtime ROM and the call-site census; `layout.py` audits the
   packed-vs-linked layout using the export tables; `extract.py`/`extract_ida.py`
   recover functions; the ROMFS is browsable via `wd2.py list`.
2. **Lifter** — ARMv4T + Thumb → C, against the sparse-memory `nk_cpu_t`.
3. **Runtime** — sparse memory + MMIO bus (`nokia_rt.c`), the ARMv4T
   interpreter (`nokia_interp.c`) for bring-up/fallback, then display, input,
   timers, and the radio stubs.
4. **Boot** — the EKA1 kernel entry at `0x50310054` after the ROM link/unpack
   step; the mask ROM at `0x00e00000` is not part of the image.

The first target milestone remains the **Nokia startup screen and idle UI** on
a host window.  Calls, signal, and the cellular stack come later (or never — a
UI simulator is a legitimate finish line).

Current progress, the exact boot frontier and the phased plan are in
[`PROGRESS.md`](PROGRESS.md) and [`BOOT.md`](BOOT.md).
