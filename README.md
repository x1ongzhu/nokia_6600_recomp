# nokia-recomp

**A static recompiler for classic Nokia phone firmware — turn an early-2000s
ARM920T image into a native, runnable executable. First target: the Nokia 6600
(NHL-10, DCT4 / UPP_WD2, Symbian OS 7.0s / S60 2nd Edition).**

> Before smartphones, the Nokia you actually remember: a colour candybar with a
> spring-loaded menu, Snake, a ringtone composer, and a handful of tiny Java games.
> No OS you'd recognise — just Nokia's own **S60** firmware fused to an ARM920T
> core. This project takes that firmware and, instead of emulating it,
> **statically recompiles it** — lifting the phone's own Thumb/ARM code to C so it
> becomes a program that runs natively. A phone, as an app.

---

## Why do this to a phone

Static recompilation (lift the original machine code to C, compile it natively,
link it against a hand-written runtime) has had a renaissance on game consoles —
N64, PS1, and our own sibling project [ngagerecomp](https://github.com/sp00nznet/ngagerecomp)
for the N-Gage. A DCT4 phone is a **great** target for it:

| Property | Nokia 6600 (DCT4 / UPP_WD2) | Why it matters |
|---|---|---|
| CPU | ARM920T, **ARMv4T** (Thumb + ARM), inside the UPP_WD2 ASIC | Clean, fully-documented ISA. No GPU, no microcode. |
| Firmware | **WD2 BT2 / WD2 ALGORITHM** container (`NHL105530.C1`) | Reversible flash format; `wd2.py` extracts the 23.3 MB image. |
| Software | Symbian OS 7.0s / Nokia **S60 2nd Edition** | The classic menu, Snake, the app suite. |
| Display | 176 x 208 16-bit TFT | No GPU. Pixels are memory — the display HLE is framebuffer → window. |
| Radio | GSM baseband / DSP | **Stubbable.** A UI-only phone is a legitimate first finish line. |

The work is not the CPU — it is that a phone image expects **specific hardware
at specific addresses**: display controller, keypad, timers, DSP/radio. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## How it works

```
   NHL105530.C1  (WD2 BT2 / WD2 ALGORITHM)      native executable
        │                                             ▲
        ▼ wd2.py (container + EKA1 headers)           │
   6600_mcu.bin  (23.3 MB flash image @ 0x50000000)   │
        │                                             │
        ▼                                             │
   ┌──────────────────┐              ┌──────────────────────┐
   │  recompiler/     │  generated   │  runtime/            │
   │  static ARM → C  │─────C───────▶│  ARMv4T interpreter  │
   └──────────────────┘              │  + sparse memory     │
                                     │  + MMIO bus          │
                                     └──────────────────────┘
```

- **`recompiler/`** — offline tools. `wd2.py` extracts the EKA1 ROM, the kernel
  E32Image and the ROMFS; `pagestream.py` removes the flash page headers;
  `romimage.py` assembles the flat runtime image; `recursive.py`/`lift.py` turn
  Thumb/ARM functions into C; `layout.py` audits the export layout;
  `imports.py` and `euser_reloc.py` recover the EKA1 import/IAT map.
- **`runtime/`** — the native ARMv4T interpreter (`src/nokia_interp.c`), sparse
  guest memory + MMIO bus, and the boot harness (`test/boot_kernel.c`) used for
  bring-up and acceptance.
- **`config/`** — per-target config and import/call maps
  ([`config/6600.toml`](config/6600.toml),
  [`config/imports-r29-6600.txt`](config/imports-r29-6600.txt)).

## Status (2026-10-26, round 30)

The **real kernel boots from the flat image to its idle loop** under the native
interpreter, and the **first hardware interrupt now wakes it**. What works:

- [x] Firmware extraction, EKA1 headers, kernel E32Image and ROMFS.
- [x] Page-header-free packed stream; kernel exports land on function starts
  469/478 (98.1%), EUser DLL 1757/1788 (98.3%).
- [x] Flat runtime image: 725 images / 1,847 sections, no overlaps; ROMFS
  directories and app binaries placed.
- [x] ARMv4T interpreter: ARM + Thumb, flags, LDM/STM, MUL/MLA **and
  UMULL/UMLAL/SMULL/SMLAL**, SWI call gate, banked modes, crash recovery,
  call-site repair, watch/spin/PC guards.
- [x] EUser import relocation: kernel ordinal `K` → ROM export `K-3` for
  `K>=6`, plus documented low ordinals and one local exception (`K=1361`).
- [x] Kernel boot state: super-page hand-off, initial TStack, initial TTime,
  `CTrapCleanup`, thread/process/object-index stand-ins.
- [x] **Faithful boot to the kernel idle loop**: 3,000,000 instructions,
  0 undefined, 0 unbound IAT, 0 recoveries.
- [x] **ARM IRQ exception + UPP timer**: SPSR_irq / banked r13-r14, high
  vectors from CP15.V, and an instruction-driven timer/ICU model. The kernel's
  own `Kern::Init1` arms timer unit 0 (reload `0x632ea`); the expiry raises
  IRQ 1, the vector at `0xffff0018` dispatches `0x50310ee0`, that handler sets
  `[0x8000000c]`, and the idle loop at `0x50310f84` exits after **430,557
  instructions** with **1 IRQ** and **0 faults**.

Not implemented yet:

- [ ] **Scheduler/timer boot-state object** — after idle, `Kern::Init1`
  continues at `0x5031ef40` and calls `[0x80001c34]->vtable+0xc`; that object
  is still null, so the boot stops at a **null call at `0x5031ef50`**. This is
  the next frontier (the object is normally created by the mask-ROM/HAL boot
  state, not by the E32 entry).
- [ ] UI/display, keypad, audio, file server, app launching (P3).
- [ ] Mask-ROM PeaK record codec (the hand-off is an explicit stand-in).
- [ ] Real hardware HLE (display controller, DSP/radio, RTC).

Current frontier and the full address/ABI map:
[`docs/PROGRESS.md`](docs/PROGRESS.md) and [`docs/BOOT.md`](docs/BOOT.md).

## Quick start

Requirements: Python 3.12+ with Capstone (`.venv` is already set up here),
`clang`, and a firmware dump you own (`fw/NHL105530.C1`).

```sh
# 1. firmware -> flash image + carved kernel
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin

# 2. verify the page-header-free stream and the export layout
.venv/bin/python recompiler/pagestream.py verify 6600_mcu.bin
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin

# 3. build the flat runtime image and the boot harness
tools/build_rom_image.sh
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
  runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
  -o out/boot_kernel

# 4. boot the real kernel to the idle loop
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r29-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
  NK_CALLMAP=config/callmap-rtc-6600.txt NK_BOOT_HANDOFF=1 \
  NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 NK_SYSTEM_TIME=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
# ... 3,000,000 insns, 0 undefined/unbound/recoveries, idle loop 0x50310f84

# 5. round 30: re-run step 4 with the timer/IRQ hand-off
#    NK_TIMER=1 NK_CPSR=0x40000053 NK_IRQ_LOG=4
# ... 430,557 insns, irqs=1, timer expiry at the guest reload, [0x8000000c]=1,
# ... idle exits, then a null call at 0x5031ef50 ([0x80001c34] object)
```

Without `NK_SYSTEM_TIME=1` the same boot stops at 133,950 instructions with
the MKERN-WD2 24 panic (`0x50310b30`) — that is the control for the initial
TTime hand-off.  With `NK_TIMER=1` but the reset CPSR left at `I=1`
(`NK_CPSR=0x400000d3`) the timer still expires, but no IRQ is taken: that is
the round-30 control for the exception entry.

## Tests

All scripts are self-contained and rebuild what they need (output goes to
`out/`, which is gitignored):

| Script | What it pins |
|---|---|
| `tools/test_interp.sh` | ARM/Thumb decode, flags, long multiply, 64-bit division, recovery |
| `tools/test_pagestream.sh` | page-header removal, boot bank, export census, 924k-instruction kernel run |
| `tools/test_layout.sh` | export-table layout / drift and relocation audit |
| `tools/test_romimage.sh` | flat image assembly, image map, ROMFS placement |
| `tools/test_imports.sh` | IAT/stub scan and ELocl hole binding |
| `tools/test_loader.sh` | EKA1 packed-record loader and first import binding |
| `tools/test_round29.sh` | previous acceptance: interpreter fixes, r29 map, idle loop |
| `tools/test_round30.sh` | **current acceptance**: UPP timer/ICU, IRQ entry, idle exit, null-call frontier |
| `tools/build_kernel_smoke.sh` | lifted C function linked against the runtime |
| `tools/build_rom_image.sh` | rebuild `out/6600_runtime.bin` |

Run everything:

```sh
for t in tools/test_*.sh; do sh "$t" || exit 1; done
```

## Repository layout

```
config/        target config, import maps, call maps
docs/          architecture, boot model, firmware format, progress
recompiler/    offline extraction / layout / lifting / relocation tools
runtime/       ARMv4T interpreter, sparse memory, boot harness
tools/         build and acceptance scripts
references/    offline third-party research material (gitignored)
fw/            local firmware dump (gitignored, never committed)
out/           generated images, binaries and logs (gitignored)
```

## Current frontier

The kernel reaches its idle wait loop:

```
0x50310f84  bl  0x5031252c      ; no-op
0x50310f88  ldr r3, [r4]        ; r4 = 0x8000000c
0x50310f8c  cmp r3, #0
0x50310f90  beq 0x50310f84
```

Round 30 closes the loop around that flag.  `Kern::Init1` arms UPP timer 0
(`0x58120a04` control=2, `0x58120a18` reload=`0x632ea`); when it expires the
model raises **IRQ 1** and reports it in the ICU current-IRQ register at
`0x58120114`.  The CPU enters the high vector (`CP15.V=1`) at `0xffff0018`,
`Kern::Irq` dispatches table entry `0x5d` (the handler object at `0x80000b5c`),
and its vtable method `0x50310ee0` sets `[0x8000000c] = 1`.  The idle loop
exits at instruction **430,557**.

The next gap is the boot-state object `[0x80001c34]`.  After idle,
`Kern::Init1` continues:

```
0x5031ef40  ldr r3, [0x80001c34]   ; object (currently null)
0x5031ef44  ldr r0, [r3]           ; vtable
0x5031ef48  ldr r3, [r0]
0x5031ef4c  mov lr, pc
0x5031ef50  ldr pc, [r3, #0xc]     ; -> null call at 0x5031ef50
```

That object is the kernel's timer-queue global: kernel export 344
(`0x5032b33c`) is its setter, and no image in this ROM imports that export, so
the mask-ROM/ASSP boot state must install it.  The frontier is therefore a
**null call at `0x5031ef50`**, not a CPU fault.  See `docs/BOOT.md` for the boot state and `docs/PROGRESS.md` for
the roadmap.

## Legal

This is a recompilation tool, not a firmware distribution. Bring your own
legally obtained firmware. Firmware, extracted images, keys and generated
builds are gitignored and must not be committed. Original Nokia/Symbian
copyrights remain with their owners; see [`LICENSE`](LICENSE).
