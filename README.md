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

## Status (2026-10-26, round 36)

The **real kernel boots from the flat image to its idle loop**, the **first
hardware interrupt wakes it**, the **timer-queue singleton is created with the
kernel's own constructor**, the **first blocking executive call switches to the
kernel's NULL thread and returns**, and the **kernel's own `DThread` /
`DProcess` / request-semaphore / `CObjectIx` objects now survive the
thread-start and close paths**. The boot then runs **6,000,000 instructions
with 14 timer IRQs and no faults**, through `Kern::Init3` and into the first
stable executive loop. What works:

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
- [x] **Timer-queue singleton `[0x80001c34]`**: kernel export 451
  (`0x5032aff8`) builds the abstract base object and installs vtable
  `0x503383bc`; its `+0x1c` slot is the pure-virtual `User::Panic` (K=1610),
  which the mask-ROM/HAL concrete subclass overrides with the hardware tick
  getter. The harness calls the kernel constructor at `0x5031ef40`, copies the
  base vtable and substitutes a zero-return tick getter, so the kernel's own
  `0x5032b024` runs.
- [x] **First scheduler switch** (round 33): EUser K=1208 is `svc #0x4d`;
  kernel table entry `0x503244e4` calls
  `current_thread->[0x5c]->vtable[0x20]`, i.e. Wait() on the request
  semaphore that `0x503311c8` installs at `DThread+0x5c`. `Kern::Init2`
  (`0x503309e4`) created the NULL thread at `0x5032fa10` (object
  `0x80601830`, entry `0x5031f144`, 0x2000-byte stack). `NK_SCHED=1` blocks
  the supervisor at the Init2 wait, starts that thread at its real entry,
  lets the guest's own start hand-off (`0x50321088` -> `0x50318398`)
  complete the pending `TRequestStatus`, and preempts back to the supervisor
  at `0x50330a98`. **KERN 6 no longer fires**; boot advances to
  **440,623 instructions**.
- [x] **Live kernel object graph** (round 34): the round-33 stop was the B7e
  stand-in overwriting the kernel's real `DThread+0x18` (`DProcess`), `+0x5c`
  (request semaphore) and `+0x64` (`CObjectIx`) on every publish; the kernel's
  own `CObjectIx::Remove` then called a null vtable from our fake index.
  `NK_B7E_LIVE=1` keeps every live object and fills only missing fields:
  `0x80600d48` / `0x806019e0` / `0x806019c0` survive, the close path runs
  vtable `0x503b36f8`, and the frontier moves past `0x503360d4`.
- [x] **Status-completion scheduler wake** (round 34): a blocked thread becomes
  runnable when its `TRequestStatus` leaves `KRequestPending`. The NULL
  thread's second `Kern::StartThread` hand-off completes the supervisor's
  status directly; the old dummy-page-only wake missed it, so a third hand-off
  found no request and panicked `PLAT 0x73`. The harness now polls the saved
  status at each instruction boundary and preempts back.
- [x] **`Kern::Init3` HAL gate** (round 34): Init3 asks HAL object 3 for
  `Request(0xd)` and polls `[0x800004cc]`. The stand-in device completes that
  request explicitly (the real driver is mask-ROM code), so boot passes the
  gate instead of spinning forever.
- [x] **Banked exception stacks** (round 34): the supervisor's SVC stack grows
  past 0x30 KiB. With the historical layout the IRQ stack sat underneath it,
  so an IRQ frame overwrote the interrupted function's saved `LR` and the
  return popped `PC=6`. Live mode places the exception stacks low in RAM and
  treats a preset bank stack as authoritative; the SVC stack keeps its own
  region.
- [x] **Live thread identity / TTrap** (round 32): `TTrap` is 0x4c bytes
  (`iState[0x10]` +0x00, `iNext` +0x40, `iResult` +0x44, `iHandler` +0x48).
  The kernel's bootstrap `SThread` at `0x802ffd00` lives inside the boot
  stack; the init call at `0x5031e594` returns the real heap `DThread` at
  `0x80601078`, but B7e's live-pointer bound (`0x80400000`) rejected it and
  kept the stack object. A later EUser `TFullName` buffer at `0x802ffcec` then overwrote the
  published SThread's `+0x38`/`+0x3c`. Following the mapped heap bound
  (`0x80a00000`) keeps `0x80601078` live, `TTrap::UnTrap` pops a real stack
  frame, and the boot advances to **439,534 instructions** (1 IRQ, 0
  undefined/unbound/recoveries).

- [x] **Hand-off completion + deadlock isolation** (round 35): the round-34
  6M run was not idle, it was a deadlock.  The scheduler preempted the NULL
  thread at `0x503183bc`, *inside* the start hand-off, so the supervisor's
  next request was never consumed.  `NK_SCHED_DEFER=1` holds the preemption
  until the hand-off returns at `0x5033130c`; the supervisor then runs ~20k
  instructions further (460,289 vs 441,434) before its next wait.  The
  remaining blocker is precise: the final wait at 464,336 is still
  `KRequestPending`, the NULL thread is in the `Kern::Init3` timing loop, and
  only two `DThread` objects exist.  The missing piece is the handle-`0x32`
  thread-start completion / DFC thread, not a CPU fault.

- [x] **MMIO provenance** (round 36): MMIO write logs now include PC/LR
  (the 16-bit stores were invisible to the word write-watch). The large
  `0xffff` fill at `0x41080000` is the kernel's boot-region descriptor table,
  written at `0x503164cc` from `0x503163f4` (`0x41000000` source,
  `0x41080000` copied entries), not an LCD framebuffer. This rules out that
  lead and keeps the display hunt on the real UI path.

Not implemented yet:

- [ ] **handle `0x32` / DFC thread** — `RThread::Resume(0x32)` looks up the
  process `CObjectIx` (`0x80601210`) and gets 0, so it falls back to waiting
  for the current thread's start hand-off; no third thread ever completes it.
  The next step is a real `CObjectIx::AddL` registration or a kernel-created
  DFC thread, not a fake index.
- [ ] **DFC / WSERV thread startup** — the display/UI server thread has not
  been created or scheduled. Round 34/35 only model the first two threads
  (supervisor + NULL).
- [ ] Real ready-queue priorities, DFC thread, timer unit 1 / IRQ 2.
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

# 6. round 31: inject the timer-queue singleton and cross that null call
#    NK_TIMERQ=1 ... (same command plus the timer/IRQ hand-off)
# ... 439,177 insns, ctor 0x5032aff8, vtable 0x503383bc, HAL +0x1c override,
# ... null call at 0x503a6148 (with the old thread bound; see step 7)

# 7. round 32: follow the real heap DThread instead of the boot-stack SThread
#    NK_B7E_VALID_HI=0x80a00000 ... (same command)
# ... 439,534 insns, [0x800017d4]=0x80601078, TTrap::UnTrap succeeds,
# ... KERN 6 panic at 0x50330aa8 while waiting on [0x80001784]

# 8. round 33: let svc #0x4d block and switch to the NULL thread
#    NK_SCHED=1 ... (same command)
# ... svc #0x4d -> Wait on thread+0x5c; first switch starts 0x80601830 at
# ... 0x5031f144; 0x50318398 completes the start request; supervisor resumes
# ... at 0x50330a98, KERN 6 gone, 440,623 insns, next null call 0x503360d4

# 9. round 34: keep the kernel's live objects, wake on status completion, and
#    pass the Init3 HAL gate
#    NK_B7E_LIVE=1 NK_SCHED=1 NK_BUDGET=6000000 ... (same command)
# ... keeps DProcess 0x80600d48 / semaphore 0x806019e0 / CObjectIx 0x806019c0
# ... CObjectIx close runs vtable 0x503b36f8; supervisor status 0x802fff8c
# ... completion wakes it; HAL object 3 Request(0xd) sets [0x800004cc]
# ... 5,999,982 insns, 14 timer IRQs, 0 undefined/unbound/recoveries

# 10. round 35: let the hand-off return before preempting and inspect the
#     remaining deadlock
#    NK_B7E_LIVE=1 NK_SCHED=1 NK_SCHED_DEFER=1 NK_SCHED_LOG=24 ... (same)
# ... switch #3 resumes at 0x5033130c (not frozen at 0x503183bc); supervisor
# ... runs to 460,289/464,336 before its next wait; 5,999,983 insns, 14 IRQs
# ... sched slots: supervisor state=3 status 0x80000001, NULL state=2
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
| `tools/test_round30.sh` | UPP timer/ICU, IRQ entry, idle exit, round-30 null call |
| `tools/test_round31.sh` | historical control: timer-queue ctor, HAL vtable override, round-31 thread model |
| `tools/test_round32.sh` | live heap DThread, TTrap/UnTrap, first blocking executive call (historical control) |
| `tools/test_round33.sh` | WaitForAnyRequest block, first switch to the NULL thread, start hand-off, KERN 6 closed (historical control) |
| `tools/test_round34.sh` | live DThread/CObjectIx graph, status-completion wake, Init3 HAL gate, banked stacks, 6M-instruction run (historical control) |
| `tools/test_round35.sh` | hand-off returns before preemption, supervisor runs to 464k, Init3 deadlock pinned to the handle-`0x32`/DFC path |
| `tools/test_round36.sh` | **current acceptance**: MMIO write PC/LR provenance; `0x41000000`/`0x41080000` is the boot-region table, not the LCD framebuffer |
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

Round 31 closed the next gap: the boot-state object `[0x80001c34]` is the
kernel timer-queue singleton.  Kernel export 451 (`0x5032aff8`) is its
abstract base constructor and installs vtable `0x503383bc`; `+0x1c` is the
pure-virtual `User::Panic` slot, which the mask-ROM/HAL concrete subclass
overrides with the hardware tick getter.  The harness calls the kernel's own
constructor at `0x5031ef40`, copies the base vtable and substitutes a
zero-return tick getter:

```
0x5031ef40  ldr r3, [0x80001c34]   ; harness-created object @ 0x80500000
0x5031ef44  ldr r0, [r3]           ; vtable 0x503383bc
0x5031ef48  ldr r3, [r0]
0x5031ef50  ldr pc, [r3, #0xc]     ; 0x5032b024 (kernel timer code)
0x5032b034  ldr pc, [vtable, #0x1c]; HAL tick getter override
```

The round-31 frontier looked like a missing `TTrap` field: `SVC 0x73`
(`0x503187e8`) popped `[thread+0x38]` = `0x503a43c4` (ROM text) and
`TTrap::UnTrap` (`0x503a6120`) called `[frame+0x48]->vtable+0xc`.  Round 32
showed the layout was fine (`iNext` +0x40, `iResult` +0x44, `iHandler` +0x48);
the pointer in `[thread+0x38]` was the **wrong thread**.  The init call at
`0x5031e594` returns the real heap `DThread` at `0x80601078`, but B7e's
live-pointer bound ended at `0x80400000`, so it re-published the bootstrap
`SThread` at `0x802ffd00` - an object inside the boot stack.  An EUser `TFullName`
("Supervisor", 0x108 bytes) at `0x802ffcec` then overwrote that object,
including `+0x38`/`+0x3c`.

With the bound following the mapped heap to `0x80a00000`,
`[0x800017d4] = 0x80601078`, the trap handler is `0x80004200`, and
`TTrap::UnTrap` pops a real stack frame (stack `0x802fff94`).  The kernel-start
path then reaches the first blocking executive call:

```
0x50330a8c  TRequestStatus at sp -> KRequestPending (0x80000001)
0x50330a90  [0x80001784] = &status
0x50330a94  EUser K=1208 -> svc #0x4d      ; wait for any request
0x50330a9c  [sp] == KRequestPending?
0x50330aa8  yes -> Kern::Panic("KERN", 6)  ; no scheduler completed it
0x50312b88  panic halt
```

Round 33 re-read that call.  Kernel service table entry `0x4d`
(`0x503244e4`) is not a "complete the request" stub:

```
0x503244e4  bl CurrentThread          ; [0x800017d4]
0x503244ec  ldr r0, [r0, #0x5c]       ; DThread::iRequestSemaphore
0x503244f0  ldr r3, [r0]
0x503244f4  ldr pc, [r3, #0x20]       ; semaphore Wait()
```

`0x503311c8` creates that semaphore with `0x50320ac0` and stores it at
`DThread+0x5c`, so `svc #0x4d` really is `WaitForAnyRequest`.  `Kern::Init2`
(`0x503309e4`) had already created the NULL thread at `0x5032fa10`: object
`0x80601830`, entry `0x5031f144` (literal `0x5032faf4`), 0x2000-byte stack.
DThread vtable `+0x20` (`0x50321088`) -> `0x50318398` completes the pending
start request and publishes the new thread; the NULL thread runs that path
itself.

`NK_SCHED=1` models the missing scheduler: it saves the supervisor's context
at the wait, starts the NULL thread on a 0x2000-byte kernel stack at
`0x5031f144`, keeps `[0x80001784]` armed so every `Kern::StartThread`
(`svc #0x76` -> `0x503312d4`) hand-off succeeds, and preempts back to the
supervisor as soon as the hand-off completes its request.  The supervisor
returns at `0x50330a98` with `[sp] == 0`:

```
sched: thread 0x80601078 blocks on svc #0x4d (status 0x802fff8c)
sched: first switch -> NULL thread 0x80601830, entry 0x5031f144
sched: startup request 0x802fff8c completed, supervisor 0x80601078 ready
sched: preempt 0x80601830 -> supervisor 0x80601078 at pc 0x50330a98
```

**KERN 6 is gone.**  That is where round 33 stopped: **440,623 instructions**,
at a null call from `0x503360d4` while `Kern::Init2` creates further threads
through EUser `RThread::Create` (`0x5032e300`).

Round 34 showed that stop was self-inflicted.  The B7e hook rewrote three
fields on every current-thread publish:

```
DThread+0x18  DProcess*           -> harness B7E_PROCESS
DThread+0x5c  request semaphore   -> harness TLS object
DThread+0x64  CObjectIx*          -> harness B7E_OBJIDX (no vtable)
```

The kernel had already created real objects for all three.  Its
`CObjectIx::~CObjectIx` / `Remove` path (`0x5033606c`) calls
`[index]->vtable+8`; our fake index had `[0] = 0`, hence the null call.
`NK_B7E_LIVE=1` preserves live objects and fills only missing fields:

```
keeps live process 0x80600d48
keeps request semaphore 0x806019e0
keeps object index 0x806019c0        ; vtable 0x503b36f8
```

Two further gaps surfaced once the real objects were in use:

1. The NULL thread's second `Kern::StartThread` hand-off completes the
   supervisor's `TRequestStatus` directly (`0x503183b4`), without touching the
   harness dummy page.  The old dummy-only wake missed it, so the NULL thread
   ran a third hand-off with no pending request and panicked `PLAT 0x73`
   (`0x50321a74`).  The scheduler now polls the saved status and wakes the
   supervisor (`supervisor status 0x802fff8c completed`).
2. The supervisor's SVC stack grows past 0x30 KiB.  The historical bank layout
   put the IRQ stack underneath it, so an IRQ frame overwrote the interrupted
   function's saved `LR` and the return popped `PC=6`.  Live mode places the
   exception stacks low in RAM (`irq=0x801c0000`) and a preset bank stack is
   authoritative.

`Kern::Init3` then asks the HAL for object 3 and issues `Request(0xd)`, polling
`[0x800004cc]`.  The stand-in device completes that request explicitly (the
real driver is mask-ROM code), and boot passes the gate.  The result is a
stable **5,999,982-instruction run with 14 timer IRQs, 0 undefined
instructions, 0 unbound IAT and 0 recoveries**, ending in the executive timing
loop at `0x5032211c`.

Round 35 showed that this 6M run was a deadlock, not idle.  The scheduler
preempted the NULL thread at `0x503183bc`, inside the start hand-off, so the
supervisor's next `TRequestStatus` was never consumed.  With
`NK_SCHED_DEFER=1` the preemption waits until the hand-off returns at
`0x5033130c`; the supervisor runs to `460,289`/`463,666`/`464,336` between
waits, but its final status is still `KRequestPending` and the NULL thread
falls into the `Kern::Init3` timing loop.  The sched-slot dump at 6M is:

```
pending-slot=0x802fff8c
[0x80601078 state=3 status=0x802fff8c val=0x80000001]
[0x80601830 state=2 pc=0x5033130c]
```

Only two `DThread` objects exist (`0x80601078`, `0x80601830`) and the timer
queue `[0x80001c34]` is empty.  The next blocker is therefore the handle-`0x32`
thread-start completion / DFC thread, not the CPU or the display path.
Display-controller HLE and the first frame follow after the UI/DFC server runs.

Round 36 added PC/LR provenance to the MMIO write log.  The big `0xffff`
fill at `0x41080000..0x41083fff` is **not** the LCD buffer: it is the kernel's
boot-region descriptor table, written at `0x503164cc` from the scan at
`0x503163f4` (`0x41000000` source descriptors, `0x41080000` copied entries).
The LCD driver search therefore continues at the real display path, not this
table.

See `docs/BOOT.md` for the boot state and `docs/PROGRESS.md` for the roadmap.

## Legal

This is a recompilation tool, not a firmware distribution. Bring your own
legally obtained firmware. Firmware, extracted images, keys and generated
builds are gitignored and must not be committed. Original Nokia/Symbian
copyrights remain with their owners; see [`LICENSE`](LICENSE).
