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
| CPU | ARM920T, **ARMv4T** (Thumb + ARM), inside the UPP_WD2 ASIC | Clean, fully-documented ISA. No GPU, no microcode. The easy part — and the exact ISA ngagerecomp already lifts. |
| Firmware | **WD2 BT2 / WD2 ALGORITHM** container (`NHL105530.C1`) | A public, reversible flash format; `recompiler/wd2.py` extracts the 22 MiB EKA1 ROM. |
| Software | Symbian OS 7.0s / Nokia **S60 2nd Edition** | The classic menu UI, Snake, the app suite — the thing worth reviving. |
| Display | 176 x 208 16-bit TFT | No GPU. Pixels are just memory — the display HLE is a framebuffer → a window. |
| Radio | GSM baseband / DSP | **Stubbable.** A UI-only "phone simulator" is a legitimate first finish line. |

The work isn't the CPU — it's that a phone image expects **specific hardware at
specific addresses**, so the runtime has to answer for the display controller, the
keypad, timers, and the DSP/radio block. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## How it works

```
   NHL105530.C1  (WD2 BT2 / WD2 ALGORITHM)      native executable
        │                                             ▲
        ▼ wd2.py (container + EKA1 headers)           │
   6600_mcu.bin  (22 MiB EKA1 ROM @ 0x50000000)       │
        │                                             │
        ▼                                             │
   ┌──────────────────┐              ┌──────────────────────┐
   │  recompiler/     │  generated   │  runtime/            │
   │  static ARM → C  │─────C───────▶│  ARM CPU + sparse    │
   └──────────────────┘              │  memory + S60 HLE    │
                                     │  (LCD, keypad,       │
                                     │  timers, radio stub)  │
                                     └──────────────────────┘
```

- **`recompiler/`** — offline tools. `wd2.py` extracts the EKA1 ROM, the
  E32Image kernel and the ROMFS; `extract.py`/`lift.py` turn thumb/ARM code into
  C (ported from ngagerecomp). `dct4decrypt.py` remains for the older 6100
  `DCT4` chunk format.
- **`runtime/`** — ships with the recompiled phone: ARM CPU model, sparse guest
  memory + MMIO bus, and the S60 HLE layer (display / input / timers, radio
  stubbed).
- **`config/`** — per-target config ([`config/6600.toml`](config/6600.toml)).

## Status

**We have the real 6600 firmware, the EKA1 ROM, the kernel E32Image and the
ROMFS.** Honest checkboxes, no vapor. The detailed progress log, acceptance
criteria and phased roadmap live in
[`docs/PROGRESS.md`](docs/PROGRESS.md).

- [x] **Firmware extracted** — `NHL105530.C1` is a **WD2 BT2 / WD2 ALGORITHM**
  flash container. [`recompiler/wd2.py`](recompiler/wd2.py) strips the container
  and writes the **22 MiB EKA1 ROM** to `6600_mcu.bin` (linked at
  `0x50000000`); it also parses the ROM header, the E32Image headers and the
  ROMFS. No key, no password.
- [x] **Platform confirmed** — DCT4 / **UPP_WD2 / ARM920T (ARMv4T)**, Symbian OS
  7.0s / S60 2nd Edition. ROM 22 MiB at `0x50000000`, kernel data at
  `0x80000000`, ROMFS plaintext and browsable (`wd2.py list`).
- [x] **Kernel located** — the EKA1 kernel E32Image (`uid3 0x100058e8`) is at ROM
  `0x3268c0`; its code is stored at `0x32692c` and links at `0x50310000`, with
  entry `0x50310054`. `wd2.py kernel` carves it to `fw/6600_kernel.bin`.
- [x] **Kernel entry runs** — [`recompiler/trace_boot.py`](recompiler/trace_boot.py)
  loads the carved kernel at `0x50310000` and executes the entry under the
  research tracer: **423 Thumb instructions**, real stack/vector/pointer setup,
  before the ARM/Thumb interworking boundary. This is the first execution of
  actual 6600 kernel code.
- [x] **Lifter runs end-to-end on the 6600 kernel** — `recursive.py` (mode-aware
  Thumb/ARM discovery) + `lift.py` produce **122 mixed-mode functions** from the
  kernel (1,785 instructions, 99% lifted). `tools/build_kernel_smoke.sh` compiles
  them against the **sparse-memory runtime** and calls a real ARM kernel helper
  (`func_50313084`): its write to `0x58000000` is logged by the new MMIO bus.
- [x] **ROMFS extraction** — `System\Libs`, the app suite, sounds, skins and the
  E32Image headers are all reachable from the plaintext ROM.

**← current frontier →**

- [ ] **E32Image loader** — the kernel is stored at a different offset than its
  link address and contains a packed/relocated region around `0x310000`; the
  entry runs, then hits ARM code as Thumb at a function boundary. Implement the
  EKA1 relocation/`KaeP` step, then the rest of the kernel entry runs natively.
- [ ] **Mask ROM** — the reset path at `0x00e00000` (entry `0x00e0ca39`) is in
  the UPP's internal boot ROM and is not in the flash dump; the runtime has to
  supply the initial MMU/vector state before the kernel entry.
- [ ] **MMIO + display** — the sparse bus is in place; next are the UPP display,
  keypad and timer shims.
- [ ] **First light** — the Nokia boot logo on a host window.
- [ ] Keypad + timers → navigable idle menu (Snake, the app list)
- [ ] Stub the radio → the phone boots to "no network" and just *runs*


## Try it

```sh
# firmware you own; generated files are gitignored
mkdir -p fw
cp "/path/to/NHL-10 v5.53.0/NHL105530.C1" fw/
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py list 6600_mcu.bin

# extract the kernel, lift mixed Thumb/ARM code, run a real kernel function
tools/build_kernel_smoke.sh
```

`6600_mcu.bin` is now the **22 MiB raw EKA1 ROM** extracted from
`NHL105530.C1` (the original WD2 container lives in `fw/`).  The old 103 MB
`6600_mcu.bin` was not a 6600 ROM and has been replaced.

The last command prints the MMIO write made by the lifted ARM helper
(`0x58000000 = 0x1234`) and `native 6600 kernel function returned`.
It is a pipeline check, not a booted phone yet.  The full entry trace, the
ARM/Thumb interworking frontier and the next loader tasks are in
[`docs/BOOT.md`](docs/BOOT.md).

## Toolchain

- **Python 3 + Capstone** — the recompiler (`wd2.py`, `extract.py`, `lift.py`,
  `gen_register.py`); `dct4decrypt.py` remains for the older 6100 DCT4 chunks.
- **IDA Pro 9.1 (headless)** — exact function boundaries on the EKA1 image
  (`extract_ida.py`).
- **clang** — compiles the generated C + runtime.
- **Unicorn** — only in `trace_boot.py`, as a research CPU while the E32Image
  loader is brought up; the shipped runtime does not depend on it.
- **ngagerecomp** — the ARMv4T lifter and CPU model this project reuses.

## Legal

nokia-recomp ships **no copyrighted firmware or assets**. It is a tool. You supply
your own legally-obtained Nokia firmware. Recompiled output is a derivative of *your*
copy and is yours to run. Everything firmware-shaped is `.gitignore`d.

**Purpose.** This project exists for **interoperability**: to let firmware you already
own keep running on hardware you can actually buy, after the original hardware has
become unobtainable. Everything here is aimed at that -- reading the image, recovering
function boundaries, translating ARM to C, and supplying a runtime that answers what
the firmware asks for. It is also a preservation and research exercise: a DCT4 phone is
a complete, documented, self-contained computer small enough to understand end to end.

**On the firmware format.** The 6600's `NHL105530.C1` is a Nokia **WD2 BT2 / WD2
ALGORITHM** flash container. `recompiler/wd2.py` only parses that container and the
EKA1 headers inside it; it does **not** unlock a device, defeat a password, or bypass
a licence check. The older [`recompiler/dct4decrypt.py`](recompiler/dct4decrypt.py)
does the same for the GSM DCT4 `DCT4` chunk format (6100 class): a fixed,
publicly documented, keyless transform, ported from [g3gg0's DCT4Crypt](https://github.com/g3gg0/DCT4Crypt)
and credited in full below. Both tools operate on an image you supply.


## Prior art & thanks

- [N64: Recompiled](https://github.com/N64Recomp/N64Recomp) — the static-recomp pattern this follows
- [ngagerecomp](https://github.com/sp00nznet/ngagerecomp) — sibling project; the ARMv4T lifter + runtime model
- [DCT4Crypt](https://github.com/g3gg0/DCT4Crypt) by g3gg0 + [retro-phone-tools](https://github.com/RobyRew/retro-phone-tools) — the DCT4 decryption algorithm
- Everyone still holding a phone that survived the 2000s. 📞
