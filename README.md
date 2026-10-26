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
  [`config/imports-r29-6600.txt`](config/imports-r29-6600.txt),
  [`config/imports-app-6600.txt`](config/imports-app-6600.txt)).

## Status (2026-10-27, round 104)

The **real kernel boots from the flat image to its idle loop**, the **first
hardware interrupt wakes it**, the **timer-queue singleton is created with the
kernel's own constructor**, the **first blocking executive call switches to the
kernel's NULL thread and returns**, and the **kernel's own `DThread` /
`DProcess` / request-semaphore / `CObjectIx` objects now survive the
thread-start and close paths**. The boot then runs **6,000,000 instructions
with 14 timer IRQs and no faults**, through `Kern::Init3` and into the first
stable executive loop. On the display side, the firmware's own
`SplashScreen.mbm` logo frame is now decoded and written through guest
`Mem::Copy` into the real LCD framebuffer (round 61). Round 62 then moved the
**real SplashScreen app** past its StartThread wait and fixed the bring-up
allocator header and the shared EUser export-table conflict. Round 63 adds the
first app-side EUser import rebind, so SplashScreen's static init now
constructs its CBase and returns cleanly instead of crashing on a zero
vtable. Round 64 rebinds the app's TTrap wrapper too, which takes the real
`0x509ef5fc` main path. Round 66 then rebinds the app's low allocator slot,
removing the null-descriptor `0xe59ff028` writes. Round 68 proves the direct
SplashScreen entry path only initializes and never draws, so the splash driver
must come from EStart or the kernel process loader. Round 69 binds EStart's
first unresolved import; round 70 adds wait completion; round 71 rebinds the
global CBase slot and advances EStart past the zero-vtable object; round 72
pins the app slot/export offset; round 73 shows the next EStart blocker is the
service-start handshake/wait; round 74 fixes the nested SVC return; round 75 shows the wait needs a real
started thread; round 76 rules out a DThread-shaped clone; round 77 rules
out the SVC model; round 78 gets a fake scheduler thread into EStart's server
entry; round 79 adds auto-complete so the server runs; round 80 clamps the
wild Mem::Copy and advances it; round 81 shows the server entry needs a
real StartThread frame; round 82 completes the server run/return cycle; round 83 shows the
supervisor's `0x00a04d08` cannot be zero-return HLE'd; round 84 rules out the
adjacent EUser slot targets; round 85 diagnoses the stack-params-as-CBase
bug; round 86 shows a vtable pointer alone still leaves; round 87 shows a real
vtable/method still fails; round 88 rules out the global CBase as `this`; round 89 traces the callback
ABI mismatch; round 90 corrects that analysis from static evidence; round 91 maps the real
ROM boot chain and the empty kernel object index; round 92 shows the kernel
cannot start the next boot stage by itself; round 93 fixes thread entry-mode
selection so a real ROM image (EFile) runs to the kernel; round 94 pushes it
through the kernel start hand-off; round 95 stops kernel-time import rebinds
from leaking into an app thread; round 96 isolates EFile's "FileServer" gate
and the HLE-heap / guest-RHeap conflict; round 97 makes the application heap
HLE-only; round 98 adds the per-thread trap frame and heap pointer that the
kernel services read; round 99 keeps one kernel-time rebind for the object
index; round 100 traces and clamps the oversized descriptor-grow request. What
works:

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

- [x] **Static display-chain inventory** (round 37): the ROMFS display
  chain is pinned: `FbServ.exe` @ `0x50689770` (uid3 `0x10003a16`),
  `FbsCli.dll` @ `0x5068c150`, `BitGdi.dll` @ `0x50698080`, and the variant
  driver `ecust.dll` @ `0x50339750` with hardware constants `0x59E00010` /
  `0x59200000`. The first frame needs a launched FbServ process plus the
  LCD HLE; see [DISPLAY.md](docs/DISPLAY.md).

- [x] **Direct FbServ startup** (round 38): `NK_ENTRY=0x506897d5
  NK_SP=0x80580000` starts the original `FbServ.exe` directly in the flat
  image, bypassing the kernel deadlock.  A Thumb `NK_ENTRY` now forces
  `CPSR.T` even when `NK_CPSR` omits it.  FbServ runs **3,612 instructions**
  and reaches its object initialization at `0x5068a572`; the next blocker is
  the uninitialized object vtable `0x50680000` (`[vtable+8]=0x068a0689`), so
  PC escapes to `0x068a0688`.  The next step is running FbServ's constructors
  / DLL imports (or the kernel process loader).

- [x] **FbServ vtable overwrite** (round 39): byte/halfword stores now hit
  the write watch. FbServ's constructor writes vtable `0x5068c0a4` at
  `0x5068a5c8`, then EUser descriptor code at `0x5038bc6c` writes a zero byte
  at `[object+1]`, leaving `0x50680000`; `[0x50680008]=0x068a0689` and the
  call escapes to `0x068a0688`. The object is being reused as a
  `TDes8`-style buffer after construction, so the direct-entry path lacks the
  C++/descriptor state a real process would have.

- [x] **Descriptor/object overlap** (round 40): the 20-byte object at
  `0x80600018` is constructed with vtable `0x5068c0a4`, then the formatting
  path `0x5068a4ee -> 0x5068b70c -> EUser 0x5038bc38` uses the same block as
  a `TDes8` buffer at `0x5038bc6c`. Clearing the user stack does not change
  it; the guest builds the descriptor header itself. The direct FbServ route
  therefore needs the user-side descriptor/thread context of a real process.

- [x] **FbServ on the real SVC path** (round 41): with
  `NK_SWI_DIRECT=0 NK_BANKED=1` the direct-SWI vtable corruption disappears.
  FbServ reaches **1,499,521 instructions** with 0 undefined/unbound, moves
  to a kernel-allocated user stack around `0x7fef....`, and enters a repeating
  EUser wait chain
  (`0x5039eddc -> 0x5039d9d0 -> 0x503998b4 -> 0x50392e00 -> 0x50392ec0`)
  before a null callback. The next blocker is the kernel executive/thread
  state the wait loop expects, not the app's C++ objects.

- [x] **Return-context corruption** (round 42): at the first watched pop
  (`0x5039ee14`) the stack still holds the correct saved `LR` `0x5039edc8`;
  the final pop returns 0 only after the executive call `0x5039b05c`. The
  failure is therefore a thread/context (stack) switch, not a push/pop or
  vtable bug. Completing the EUser wait SWIs (`0x76..0x7b`) inline does not
  fix the direct path either; it still stops at 3,360 instructions.

- [x] **Real SVC exception model** (round 43): `NK_SWI_DIRECT=0` was
  treating every `svc` as a no-op, so the round-41 1.5M FbServ run never
  entered the kernel. `NK_SWI_EXCEPTION=1` now takes a real SVC exception,
  enters the kernel vector `0xffff0008`, and dispatches through the kernel's
  own handler at `0x50314f30`. The handler needs the mask-ROM pre-handler at
  `[0x80000f34]`; a zero-return hook object in the high-vector page supplies
  it. The kernel boot with real SVCs stops at the boot sentinel
  `0xdead0000` after 11,114 instructions; direct FbServ stops at 56 because
  its user-SVC return path still needs the current-thread state.

- [x] **User/kernel SVC selector** (round 44): FbServ's first system call
  is `0x50392b88 ef00006c` (`svc #0x6c`). The kernel handler uses immediate
  bit 23 as the user/kernel selector; with it clear it takes the kernel path
  and the app stops at 56 instructions. Setting bit 23 on the EUser stub
  table (`NK_USER_SVC=1`) is not enough: the handler then loads
  `0xe59ff028` from its dispatch table and jumps to that instruction word.
  The user path expects a different table/entry format, so this is the next
  loader/ABI frontier.

- [x] **Stable real-SVC FbServ** (round 45): three boot-state fixes make
  direct FbServ + real SVCs stable for the full 2,000,000-instruction budget:
  the USR bank starts at the app's `NK_SP` and the stack predicate follows
  the mapped 6 MiB bank; the B7e current-thread hook is installed before the
  initial fake thread is published (so `+0x18/+0x5c/+0x64` exist); and the
  kernel DFC queue `0x80001c28` starts empty.  FbServ now waits in
  `WaitForAnyRequest` at `0xffff0008` / `0x5039865c` instead of faulting.
  The direct `NK_SWI_DIRECT` path also reaches the 500k budget, with a wild
  `0x600000` clear as its new frontier.

- [x] **Splash-screen route** (round 46): the first visual is the
  splash/startup screen. ROMFS has `SplashScreen.exe` (uid3 `0x100059de`,
  entry `0x509eee85` Thumb) + `SplashScreen.mbm`, `EwSrv.exe` (uid3
  `0x10003b20`, entry `0x506a8205`) and `EStart.exe` (`0x503da440`). Running
  SplashScreen in the stable app harness reaches EwSrv code and stops on the
  bad function/data pointer `0x506cbf1c` (`lr=0x509ef1ab`), not a CPU decode
  limit. The next step is EwSrv import/vtable initialisation. The direct
  path's `0x600000` copy is a multi-MB data copy with a bad length, not the
  framebuffer (`NK_MAP_APP_LOW=1` maps it but does not remove the frontier).

- [x] **Stable SplashScreen** (round 47): SplashScreen's EwSrv export slot
  `0x506ce7d0` holds `0x506cbf1d`, two bytes before the real Thumb prologue
  at `0x506cbf1e`. `NK_EWSRV_SNAP=1` applies the E32-loader-style Thumb +2
  fixup. SplashScreen then runs the full **2,000,000-instruction budget**
  with 0 undefined/unbound/recoveries, ending in the request-semaphore Wait
  service `0x503244e4..f4` — waiting for a client/message, not on a bad
  pointer. The next step is to complete that request or HLE the window-server
  draw path so the splash pixels reach a framebuffer.

- [x] **Splash wait and EwSrv blockers** (round 48): `NK_WAIT_HLE=1`
  completes the EUser `TRequestStatus` in `r5`, so SplashScreen leaves
  `WaitForAnyRequest` — but it then enters a wild descriptor copy at
  `0x5038d2d4` (8-word expansion loop, source/destination around `0x80da....`)
  and runs to the budget without a display draw. Direct `EwSrv.exe`
  (`0x506a8205`) null-calls at pc=0, lr=`0x506c0b15`, so its own
  imports/vtables are also uninitialised. Round 62 corrected the first half:
  the wild length came from the HLE allocator's `'HLEH'` cell header, not
  from a missing surface; with that header fixed the same run reaches EwSrv
  `0x506ca5e4`.

- [x] **Splash asset / EwSrv relocation facts** (round 49):
  `SplashScreen.mbm` is a 0xd54-byte MBM with UID `0x10000041`, bitmap
  offsets `0x10`/`0x8c0`, width `0xb0` (176), height `0xd0` (208) and
  mostly-white `0x7fff` pixels. After the stable 2M SplashScreen run its RAM
  contains **no MBM signature**, so the app has not loaded/decoded the
  splash. EwSrv's null call comes from the Thumb veneer at `0x506c15ee`
  loading the literal `0x4a7846c0`, which is not a valid IAT slot — a
  relocation/veneer problem, not a simple unbound import.

- [x] **EwSrv first missing-DLL call** (round 50): EwSrv's veneer
  `0x506c15ee` loads the stale pointer `0x4a7846c0` from a missing DLL.
  `NK_FIX_4A78=1` maps a full 64 KiB page at `0x4a780000` (the page size is
  64 KiB) and points `0x4a7846c0` at a zero-return stub in the high-vector
  page. EwSrv then executes `0xffff0d00 -> 0xffff0d04 -> 0x506c0b14` and
  continues to the next unresolved pointer. This is a concrete step past the
  first missing-DLL call, not a full window-server bring-up.

- [x] **EwSrv real prologue / packed veneer** (round 51): EwSrv's call at
  `0x506a821a` encodes `0x506c0b0c`, the middle of the function whose real
  prologue is `0x506c0a4a`. `config/callmap-ewsrv-6600.txt` redirects it
  (`0x506a821a 0x506c0a4a T`; callmap fixups run only with
  `NK_CALL_INFER=1`). EwSrv then enters the proper prologue and reaches the
  next veneer at `0x506c1dba`, whose literal is code/padding rather than a
  slot — a packed/relocated veneer-literal problem, not a single missing
  import. `NK_FIX_4A78` now fills the whole missing-DLL page.

- [x] **EwSrv IAT vs unrelocated literal** (round 52): the IAT at
  `0x506c9290` holds resolved Thumb addresses (`0x506980e5`, `0x506a815c`,
  `0x503c9485`, ...), but the veneer at `0x506c1dba` loads `0x40b846c0`
  (code/padding), not an IAT slot. The IAT is fine; the app code's literal
  pool is unrelocated by the flat-image loader. This is the concrete loader
  frontier for EwSrv/window-server bring-up.

- [x] **LCD/framebuffer base** (round 53): ecust.dll's display config at
  `0x5033abf4` writes the LCD controller base `0x59200000` and the
  framebuffer base `0x59800000` (base + `0x600000`). `NK_MAP_LCD=1` maps the
  controller page and a 4 MiB framebuffer and can dump it. The current stable
  SplashScreen run writes **no pixels**; the 4 MiB dump is all zero. This is
  now the capture target for the first frame.

- [x] **Kernel boot also writes no LCD** (round 54): mapping
  `0x59800000` during the normal kernel boot (`NK_MAP_LCD=1`, 6M budget)
  still gives an all-zero 4 MiB dump. The kernel boot stops at `0x50312720`
  before any display driver/UI process runs. Neither the kernel path nor the
  stable SplashScreen path writes the LCD; the window-server/app-loader
  layer is the missing piece.

- [x] **ROM image / DLL ref table** (round 55): EwSrv's header at
  `0x506a81a0` is a `TRomImageHeader` (entry `0x506a8205`, code
  `0x506a8204`, data `0x506c4c80`, `iDllRefTable` `0x506c9290`,
  `iExportDir` `0x506c928c`). The `TDllRefTable` has `iFlags=1`,
  `iNumberOfEntries=7` and seven imported-DLL entry addresses
  (`0x506980e5`, `0x506a815c`, `0x503c9485`, ...). The flat image never
  applies the ROM loader's import fixups, so the veneer literals
  (`0x4a7846c0`, `0x40b846c0`) are placeholders, not resolved IAT slots.
  This is the architectural reason the window server cannot start.

- [x] **Link-time literal relocation lead** (round 56): EwSrv's veneer
  literal `0x4a7846c0` is not a resolved IAT slot, but applying the
  `0x4a780000` link-base delta to it lands on valid Thumb prologues in
  several images (`uid 0x10003c77 -> 0x505bf774` `b510`, `uid 0x10f9a40 ->
  0x50815a74` `b570`, ...). That points at a missing ROM-loader
  relocation/import fixup rather than one bad import. The `0x40b846c0`
  literal does not match this base, so each DLL may have its own link base.

- [x] **EwSrv dllref section** (round 57): the 64-byte section at
  `0x506c9290` is `flags=1, count=7`, the seven DLL entry points, a zero,
  six more DLL entries and `0xffffffff`. The six tail entries are **not**
  per-import IAT slots: patching the second veneer to `0x506c92b8`
  (`0x50698040`, BitGdi) enters BitGdi but wild-jumps to `0x5155a0ca`; the
  other slots null-call. EwSrv needs the real ROM loader import fixup, not a
  guessed slot table.

- [x] **First guest-written LCD frame** (round 58): the harness maps the LCD
  controller/framebuffer, fills a guest source with `0xff`, and calls the
  guest EUser `Mem::Copy` at `0x5038cfe0` with
  `dst=0x59800000, src=0x80800000, len=176*208*2`. The guest copy writes
  **36,608/36,608 white pixels** to the real LCD framebuffer; the dump is
  rendered to [docs/assets/first_frame.png](docs/assets/first_frame.png).
  This is the white-source control for the framebuffer path, not the MBM's
  actual contents.

- [x] **BitGdi export symbol map** (round 59): the ROM BitGdi export
  directory has 185 addresses and no names, but the matching S60 2.0 SDK
  `bitgdi.lib` stores the mangled names in export order. The drawing entry
  points map as `Clear()` = `0x5069ec5d`, `Clear(TRect)` = `0x5069a029`,
  `DrawBitmap(TPoint, bitmap)` = `0x5069a991`. `tools/bitgdi_symbols.py`
  reproduces the mapping. The next step is constructing a `CFbsBitGc` /
  `CFbsBitmap` whose data pointer is `0x59800000` and calling `Clear`/
  `DrawBitmap` for a real guest-drawn frame.

- [x] **Bitmap constructor blocker** (round 60): calling
  `CFbsBitmap::Create` (FbsCli export 147, `0x5068cb91`) on a zeroed guest
  object reaches an unresolved veneer at `0x506dd80c`, which loads the
  placeholder `0xe59ff028` and branches there (`lr=0x506dd80d`). The
  BitGdi/FbsCli constructors need the same ROM-loader import fixup as EwSrv;
  the symbol map alone is not enough.

- [x] **Nokia logo frame** (round 61): the first bitmap in the real
  `SplashScreen.mbm` is a 176×208 8bpp EByteRLE resource, not an all-white
  frame. Its payload decodes to 1,449 non-white pixels in the lower rows —
  the embossed **NOKIA** logo. The harness now decodes that firmware bitmap
  from guest memory into a guest RGB565 buffer, then the real guest EUser
  `Mem::Copy` writes it to `0x59800000`; the captured frame is
  [docs/assets/nokia_logo_frame.png](docs/assets/nokia_logo_frame.png)
  (3× preview: [docs/assets/nokia_logo_frame_3x.png](docs/assets/nokia_logo_frame_3x.png)).
  `tools/test_round61.sh` pins the header, pixel count, logo bbox and the
  RGB565 FNV-1a hash. The decode is still a harness HLE because the
  FbsServ/`CFbsBitmap` loader remains blocked; the pixels and the framebuffer
  write come from the firmware/guest side.

  ![Nokia logo frame](docs/assets/nokia_logo_frame_3x.png)

- [x] **App-entry foundations** (round 62): three blockers around the real
  SplashScreen path are now pinned and fixed:
  - the bring-up HLE allocator stored `'HLEH'` at `[payload-4]`; guest
    `RHeap::ReAlloc` read that as the cell size and produced a
    `0x484c4544`-byte `Mem::Copy`. The header is now guest-compatible
    (`[payload-8]` = HLE size, `[payload-4]` = payload+4).
  - `NK_START_HLE=1` completes the `Kern::StartThread` `TRequestStatus` in
    `[r3]`, and `NK_USER_SVC_KERNEL=1` clears bit 23 on the EUser SVC 0x76
    stub so the kernel service table dispatches StartThread. SplashScreen
    leaves the wait-any-request spin.
  - the kernel EUser relocation map rewrites **shared** EUser export slots
    (e.g. `0x503b4f10`: kernel `0x5038918c`, app export `0x50389180`).
    Direct-app runs must omit `NK_IMPORTMAP`; this explains the old wild
    descriptor/zero-vtable app paths. The next frontier without the kernel
    map is a zero-vtable object at `0x80600008`, whose virtual dispatch
    reads `0xe59ff028` (`lr=0x509eef1f`).
  `tools/test_round62.sh` pins all three with two 0-instruction dumps.

- [x] **First app-side EUser import rebind** (round 63): SplashScreen's slot
  `0x503b4338` expects a CHeartbeat-style constructor (the app dispatches
  through the returned object's vtable+8 with `r1=3`), but the ROM slot holds
  `operator new` and returns a zeroed object. `config/imports-app-6600.txt`
  plus `NK_APP_IMPORTMAP` rebind it to ROM export index 747
  (`0x50383c84`), which allocates the 0x10-byte CBase, installs vtable
  `0x503b359c`, and allocates its 0x40-byte backing store. Static init now
  returns cleanly to `0xdead0000` in 360 instructions; `0x80600008` holds
  vtable `0x503b359c`. No framebuffer writes yet — the real splash
  main/active object is the next frontier. `tools/test_round63.sh` pins it.

- [x] **App main path and SVC-return blocker** (round 64): rebinding the
  app's TTrap wrapper slot `0x503b4980` from the ROM string helper
  `0x50396ca8` to `TTrap::Trap` (`0x5038cae8`) makes SplashScreen take the
  real `0x509ef5fc` main/constructor path. The first `User::Alloc`
  `svc #0x6c` returns correctly; later, after two MMIO writes to
  `0xe59ff028` from `0x50383c74/7c` (caller `0x50383ec0`, destination
  `r5=0xe59ff028`), a subsequent SVC falls into the `0x50314f78` `bx lr`
  self-loop with `lr=0x50314f78`. The bad pointer comes from the
  `0x509ef612 -> 0x509ef78c -> 0x50383e50 -> 0x50383e80` call chain:
  `0x50383e80` receives `r0=0`, treats it as a descriptor/TDes16Overflow,
  and reads `[0+0xc]`, which yields `0xe59ff028`. Clearing bit 23 on all
  nine EUser SVC stubs (`NK_USER_SVC_KERNEL=2`) does not fix it. The next
  task is the null descriptor/overflow ABI at `0x509ef78c`. The
  experimental map is `config/imports-app-main-6600.txt`; the default app
  map still only does the round-63 CBase rebind.
  `tools/test_round64.sh` pins the frontier; framebuffer still has no app
  pixels.

- [x] **App low allocator rebind** (round 66): the null descriptor came from
  `0x509ef5fc`'s `operator new(0x68)`, which uses EUser export index 2
  (slot `0x503b379c`). The app expects `User::Alloc`, but the unpatched ROM
  slot returns 0. `config/imports-app-main-alloc-6600.txt` rebinds it to
  `0x503988f0`; the `0xe59ff028` MMIO writes are gone and the framebuffer is
  untouched. The remaining blocker is the app main's StartThread/SVC path,
  still self-looping at `0x50314f78` with `r1=0x32`.
  `tools/test_round66.sh` pins the result, including a direct-dispatch
  control that bypasses the banked SVC loop and reaches EwSrv's
  `0xb5f00000` thunk jump.

- [x] **Direct entry is not the drawing path** (round 68): HLE-ing the
  EwSrv slot `0x506ce44c` to a zero-return stub makes the direct
  SplashScreen entry return cleanly to `0xdead0000` in 1,694 instructions,
  with no MMIO writes and no framebuffer pixels. The `0x509ef1e4` EwSrv
  call is initialization/cleanup, not the splash draw. The next route is
  EStart / the kernel process loader / an active object.
  `tools/test_round68.sh` pins the negative result and also opens the
  EStart route: `EStart.exe` (entry `0x503da4a5`) null-calls after 119
  instructions at `lr=0x503da5b9` through slot `0x503b6b38`, so its own
  imports are the next binding target.

- [x] **EStart first import bind** (round 69): `config/imports-estart-6600.txt`
  binds slot `0x503b6b38` to uid3 `0x100039e8`'s real export `0x503b53f5`.
  EStart now runs the full 200,000-instruction budget instead of
  null-calling at 119, stopping in the kernel SVC/pre-handler path at
  `0x50314f68`; no MMIO writes and no framebuffer pixels yet. The next
  target is the thread/semaphore event it waits on.
  `tools/test_round69.sh` pins the result.

- [x] **EStart wait HLE** (round 70): `NK_WAIT_HLE=1` moves EStart from the
  200k wait spin to 12,136 instructions and 1,720 MMIO reads, then it stops
  on a zero-vtable object at `0x80600000` (`vtable+8 -> 0xe59ff028`,
  `lr=0x503dac83`). The object comes from the EStart constructor path
  `0x503db640 -> slot 0x5034c638` (static `0x5034c74d`); rebinding that slot
  to the EUser CBase constructor `0x50383c84` did not change the result.
  The `r5` object is actually allocated through `0x503dac48 ->
  0x503db560 -> slot 0x503b4f14` (static `0x503a35b4`); rebinding that
  slot to `0x50383c84` also did not change it. Framebuffer remains
  untouched. `tools/test_round70.sh` pins the frontier.

- [x] **EStart global CBase rebind** (round 71): EStart's `0x503b4338` getter
  is ROM `operator new`; binding it to `0x50383c84` gives the global object
  vtable `0x503b359c` and moves EStart from 12,136 to 13,162 instructions.
  The next frontier is a bad virtual dispatch at `0x503ce69c`
  (`bx r1`, `r1=0x00a04d08`, `lr=0x503ce6a1`), so the generic CBase vtable
  is not EStart's real class vtable. `config/imports-estart-6600.txt` holds
  both rebinds; `config/imports-estart-nocbase-6600.txt` preserves the
  round-70 path. `tools/test_round71.sh` pins the new frontier.

- [x] **App import slot / EUser export offset** (round 72): slot
  `0x503b4338` holds EUser export 745 (`operator new`, `0x503963dc`), but
  the app expects export 747 (`CBase` constructor, `0x50383c84`) — a
  two-entry offset. This is why both SplashScreen and EStart need the same
  rebind. `tools/test_round72.sh` pins the mapping.

- [x] **EStart bad dispatch is a service handshake** (round 73): the
  `0x503ce69c` call comes from EStart `0x503da74a -> 0x503db3dc` through
  slot `0x503cf984` (value `0x503ce691`). EStart passes a stack descriptor,
  but the ROM function treats it as a CBase object. HLE-ing the slot makes
  EStart run the 200k budget again and fall back to the `0x50314f78` wait
  loop on handle `0x32`, with no framebuffer pixels. The next step is a
  minimal scheduler/server handshake model. `tools/test_round73.sh` pins
  the negative result.

- [x] **Nested SVC return fix** (round 74): an SVC entered from SVC mode
  overwrote the bank LR with PC+4, and the handler's `mov lr,pc` clobbered
  the register, so `movs pc,lr` self-looped at `0x50314f78`.
  `NK_NESTED_SVC=1` keeps the caller LR and returns through the bank LR.
  EStart now reaches the wait-status check at `0x50398660` instead of the
  self-loop; framebuffer remains untouched.
  `tools/test_round74.sh` pins the fix.

- [x] **Wait needs a real thread** (round 75): NOP-ing the wait-status
  loop branch `0x50398664` makes EStart leave the wait, but it immediately
  retries `RThread::Resume/StartThread` at `0x503998b0` (SVC 0x76, handle
  `0x32`). The wait is for a real started thread, so the next step is a
  DThread/server object for that handle, not another status HLE.
  `tools/test_round75.sh` pins the result.

- [x] **DThread clone is not enough** (round 76): wiring a cloned
  DThread at `0x80004600` into the object-index fetch still leaves
  EStart's wait status at KRequestPending (`0x50398660`). The missing
  piece is a real request/server completion, not another object graph.
  `tools/test_round76.sh` pins the negative result.

- [x] **Direct dispatch does not bypass the handshake** (round 77):
  `NK_SWI_DIRECT=1` still stops EStart at `0x00a04d08` after 12,305
  instructions with 1,719 MMIO reads. The blocker is the service-start
  handshake, independent of the SVC/exception model.
  `tools/test_round77.sh` pins the negative result.

- [x] **Fake scheduler thread reaches the EStart server** (round 78):
  `NK_SCHED_FAKE=1` pre-creates a slot at `0x80004600`, points
  `[0x80000400]` at it, and uses `NK_SCHED_ENTRY=0x503db158` /
  `NK_SCHED_STACK=0x80560000`. The scheduler now switches into the server
  entry instead of reporting no runnable thread. The entry then null-calls
  at `lr=0x503db18f` through slot `0x503b3d14 -> 0x503a2960`, which is the
  next import/argument frontier. Framebuffer remains untouched.
  `tools/test_round78.sh` pins the result.

- [x] **Scheduler auto-complete runs the EStart server** (round 79):
  `NK_SCHED_AUTOCOMPLETE=1` completes the blocked thread's status after a
  switch. With the server body entry `0x503da675` and
  `NK_SCHED_R0=0x8057ffc8`, the EStart server runs the full 200,000
  instructions and ends in the `0x5038d724` LDMDB/STMDB copy loop with a
  wild destination (`0x65d8b834`/`0x4b6d61f8`), doing 646,007 MMIO reads
  and 642,561 writes. Framebuffer remains untouched.
  `tools/test_round79.sh` pins the result.

- [x] **Mem::Copy clamp advances the server** (round 80):
  `NK_MEMCOPY_CLAMP=1` zeros Mem::Copy calls with length > 0x100000 or
  src/dst outside `0x50000000..0x80a00000`. The server advances from the
  200k MMIO storm to 26,652 instructions, 3,441 MMIO reads and 22,928
  writes, then stops on a new null call at `lr=0x503da6d5`
  (`r3=0xe59ff028`). Framebuffer remains untouched.
  `tools/test_round80.sh` pins the result.

- [x] **Fake stack sentinel is not enough** (round 81):
  `NK_SCHED_STACK_FILL=0xdead0000` still leaves the server's
  `0x503da6ee` epilogue with r0=0 because `sp=0x80562020` is outside the
  fake stack. The entry needs a real StartThread frame/callback.
  Framebuffer remains untouched. `tools/test_round81.sh` pins the result.

- [x] **Server run/return cycle** (round 82): `NK_SCHED_STACK_EXTRA` maps and
  fills sentinel words above the initial sp; `NK_SCHED_EXIT` retires the
  fake thread at `0xdead0000` and resumes the supervisor. The server returns
  cleanly after 26,652 instructions; the supervisor then hits the old
  `0x00a04d08` dispatch at 29,295 instructions with 3,441 MMIO reads /
  22,928 writes. Framebuffer remains untouched.
  `tools/test_round82.sh` pins the result.

- [x] **Supervisor dispatch cannot be zero-return HLE'd** (round 83):
  HLE-ing slot `0x503cf984` advances the supervisor to 30,815 instructions
  but enters the EUser TTrap/leave path, null-calling at
  `lr=0x5038cb70` (`r1=0xfffffff8`). The next blocker is the real
  object/argument that `0x00a04d08` needs. Framebuffer remains untouched.
  `tools/test_round83.sh` pins the result.

- [x] **Adjacent EUser slot targets also fail** (round 84): replacing slot
  `0x503cf984` with the neighbouring table entries `0x503ce719`,
  `0x503c9e99`, or `0x503c9c2d` still ends in a 30k–31k null call or the
  `0x00a04d08` leave, with no framebuffer pixels. The blocker is the
  supervisor object/argument, not a one-entry target mistake.
  `tools/test_round84.sh` pins the negative sweep.

- [x] **Supervisor passes stack params as a CBase** (round 85): at
  `0x503ce69c`, `this=0x8057ffd8` and `[this+0x14]=0x503da4cd`, a code
  return address rather than a vtable. EUser therefore reads
  `[this+0x14+0xc] = 0x00a04d08`. The next fix is constructing/passing a
  real CBase, not changing the slot target. Framebuffer remains untouched.
  `tools/test_round85.sh` pins the diagnosis.

- [x] **A vtable pointer alone still leaves** (round 86):
  `NK_SUPERVISOR_OBJECT_FIX=1` writes the B7e vtable into `[this+0x14]`
  at `0x503ce696`. The `0x00a04d08` dispatch disappears, but the
  zero-return `+0xc` method makes the supervisor enter EUser TTrap/leave
  at 30,988 instructions (`lr=0x5038cb70`, `r1=0xfffffff8`). The object
  needs its real class vtable/method. Framebuffer remains untouched.
  `tools/test_round86.sh` pins the result.

- [x] **A real vtable/method still fails on the stack params** (round 87):
  pointing `[this+0x14]` at `0x503b36d0` (whose `+0xc` is the real method
  `0x5038681c`) still null-calls at 30,852 instructions. Other vtable
  candidates also fail, with no framebuffer pixels. The object needs a
  real class instance (fields + vtable), not just a vtable pointer.
  `tools/test_round87.sh` pins the negative sweep.

- [x] **Global CBase as `this` also fails** (round 88):
  `NK_SUPERVISOR_THIS=0x80600008` sends the supervisor to data at
  `0x80000500`; `0x80600000` null-calls. Neither draws. The real class
  instance/server response is still missing.
  `tools/test_round88.sh` pins the result.

- [x] **Callback receives stack params, not a CBase** (round 89): watching
  `0x503da6f0` shows `0x503db2dc -> 0x503da6f0` with `r0=0x8057ffc8`
  (EStart's stack params block) and `r1=0xd`. The callback expects `this`,
  so the later EUser dispatch treats `[this+0x14]` as a vtable and lands
  on `0x00a04d08`. The callback/object ABI needs the real server/class
  instance. `tools/test_round89.sh` pins the diagnosis.

- [x] **Correction: EStart's real main and import map** (round 90):
  static analysis shows `0x503da4a4` (the static-constructor walker) calls
  the real main `0x503db29c`, which builds a **0x24-byte stack params
  block** and calls 14 sub-steps with `r0 = sp` (21 `bl` sites). Those are
  free functions taking a params struct, **not CBase methods**. The
  "stack params as a CBase" seen in rounds 85-89 is an artifact of the fake
  scheduler thread introduced in round 78, so those conclusions are
  withdrawn. EStart's 56 import thunks split into 30 EUser slots, **12
  EFSrv.dll slots** (`0x503cf918..0x503cfcdc`; uid3 `0x100039e4`, 241
  exports), and kernel/other slots; 3 slots are unresolved
  (`0x503cfcd8`, `0x50a1f06c`, `0x50a1f070`). **30 call sites go into the
  EFSrv slots** (open/write/read/mount), so the real blocker is the EFSrv
  file server being unavailable, not an object vtable.
  `tools/test_round90.sh` pins these facts offline.

- [x] **ROM boot chain and empty kernel object index** (round 91): the real
  chain is `ekern.exe -> EFile.exe -> EFSrv.dll -> EStart.exe ->
  Starter.exe -> SplashScreen.exe`, so EStart's 12 EFSrv slots only work
  after the file server exists — driving EStart alone can never draw. On
  the kernel side, handle lookups go through EUser slot `0x503b3948`
  (rebound by `config/imports-r29-6600.txt` from the ROM's `0x50380270`
  to `0x5038e4b4`) against the process object index `0x80600e98`, whose
  element count at `+8` is **0**, so every handle lookup returns 0 and
  handle `0x32` never resolves. Populating that index (`CObjectIx::AddL`
  semantics) is the first task of the kernel-process-loader route.
  `tools/test_round91.sh` pins these facts offline.

- [x] **The kernel cannot start the next boot stage** (round 92): a 460k
  instruction kernel boot arms the HAL timer once (`reload=compare=0x632ea`,
  `control=0x2`) and takes exactly one IRQ at ~430k, then idles by design;
  the timer-queue `+0x1c` HAL tick getter is never called, so a monotonic
  tick (`NK_HAL_TICK=1`) changes nothing. `Kern::Init2`'s tail
  (`0x50330a88..0x50330aa8`) is a retry wait loop, so completing its status
  from the harness only makes the supervisor re-block at `0x50330a98` about
  11 times between 440,946 and 442,511 instructions. Only two DThreads ever
  exist and no DProcess/EFile/EStart is created. The mask ROM's boot
  hand-off (create and start the first user process) is what is missing, so
  this route requires the harness to perform that hand-off.
  `tools/test_round92.sh` pins the measurement.

- [x] **Thread entry instruction set** (round 93): the first switch forced
  every new thread to ARM (`0x40000013`) and ignored bit 0 of E32
  `iEntryPoint`. Running a Thumb image in ARM mode produced garbage state:
  against `EFile.exe` (uid3 `0x100039e3`, code `0x503b7104`, entry
  `0x503b7105`) the walker ran 9 ARM instructions with `r4=r5=0` and
  null-called through the `bx r0` thunk `0x503c597c`. Honouring the entry
  bit (`sched_resume` and the first switch) makes EFile execute 1,120 Thumb
  instructions, touch `0x40000400`/`0x40000418`, and stop in a kernel panic
  halt at `0x50312b88` instead of a null call. `tools/test_round93.sh` pins
  this; rounds 78 and 92 still pass.

- [x] **EFile past the kernel start hand-off** (round 94): `DThread::StartThread`
  (vtable+0x20 = `0x50321088`) stores its argument at `this+0xf8` and jumps to
  the kernel start hand-off `0x50318398`, which consumes the pending
  `TRequestStatus` at `[0x80001784]`. After the first switch that slot was
  already consumed, so the hand-off raised a PLAT fault (reason `0x73`) and
  the kernel halted at `0x50312b88`. `NK_HANDOFF_ARM=1` re-arms the slot
  before the hand-off and removes that fault. `NK_ALLOC_MAX` (default
  `0x100000`) makes EFile's pointer-sized `ReAlloc` request (`0x503c7168`
  bytes) fail cleanly instead of poisoning the bump heap; the guest then
  follows the null result and leaves the image at `0x2c`, which is the next
  frontier. Adds `pc_hook3`/`pc_hook4`, moves the memcopy clamp to hook 2,
  and adds `NK_SCHED_MODE=auto|arm|thumb` (auto honours iEntryPoint bit 0).
  `tools/test_round94.sh` pins the result.

- [x] **Kernel-time import rebinds must not reach an app thread** (round 95):
  EUser's export table doubles as the import slot table for every ROM image
  (an importer's stub is `ldr rX,[pc]; ldr rX,[rX]; bx rX` and the literal
  points at an EUser `.edata` entry). `config/imports-r29-6600.txt` rebinds
  236 of those entries for the kernel, which was linked against a different
  EUser `.def`, so an application running in the same boot calls the wrong
  EUser function with its own arguments: EFile passed `0x503bfcf3` (a code
  address) and `0x503c7148` (its ctor table) as descriptor lengths and grew a
  buffer to `0x503c7168` bytes. `NK_IMPORTMAP_REVERT=1` records each original
  value while patching and restores all of them when the first application
  thread is resumed. The control run still logs
  `HLE alloc rejected: 0x503c7168 bytes`; the revert run has no anomalous
  allocation and EFile reaches a blocking wait after 868 Thumb instructions.
  `tools/test_round95.sh` pins both runs.

- [x] **App-thread starvation and the "FileServer" gate** (round 96):
  `NK_SCHED_NO_PREEMPT=1` stops the bring-up supervisor from preempting the
  application thread at insns=440,847 and never giving the CPU back (it issues
  no further `svc #0x4d`). EFile's main `0x503bfe6c` first calls the gate
  `0x503bfe18`, which builds the literal `"FileServer"` (UTF-16 at
  `0x503c7a34`), calls EUser export 757 (`0x503b4368` -> `0x5039912c` ->
  `svc #0x1c`) and continues only when the result is -1 (KErrNotFound). Our
  model returns 0, so main returns immediately and the kernel takes the
  non-0x32 `Kern::StartThread` path. The new `NK_SWI_RET=<imm>:<value>`
  override bypasses the gate (`NK_SWI_RET=0x1c:-1`), after which EFile spins
  at `0x5039c6bc` walking a real RHeap free list (`r4=0x2f`,
  `r6=0x80601b64`): the HLE bump allocator does not maintain the guest heap's
  cell links, so guest RHeap code cannot run on a HLE heap. That is the next
  frontier. `tools/test_round96.sh` pins both runs.

- [x] **The application heap is HLE-only** (round 97): `RHeap1::ReAlloc1`
  (`0x5039c630`) was only intercepted for pointers the HLE bump heap owns, so
  any other pointer fell through to the guest allocator, which walked a free
  list the HLE heap never builds (the round-96 `0x5039c6bc` spin with
  `r4=0x2f`). All fall-throughs are gone: realloc of a foreign or null
  pointer becomes a fresh block (nothing copied, the old size is unknown),
  free of a foreign pointer is a logged no-op, and oversized requests still
  fail cleanly. EFile now reaches the trap-handler restore at `0x5038cb34`:
  `svc #0x73` (trap handler uninstall), `ldm r5, {r4..fp, sp, lr}`, then
  `bx lr` through a garbage restored LR of `0x2c`. The trap-handler stack is
  the next frontier. `tools/test_round97.sh` pins the result.

- [x] **Per-thread trap frame and heap pointer** (round 98): two pieces of
  boot state that a direct E32-entry boot never establishes.
  `svc 0x73` UnTrap (`0x503187e8`) returns `[current_thread+0x38]` and pops
  the chain through `[frame+0x40]`; EUser (`0x5038cb34`) then reads
  `[frame+0x44]`/`[frame+0x48]` and, when the latter is zero, restores a
  whole context with `ldm r5, {r4..fp, sp, lr}` and branches through the
  saved LR. B7e left `thread+0x38` zero, so that restore read address 0 and
  jumped to `0x2c`. `NK_TRAP_FRAME=1` installs one initial frame whose saved
  LR is the exit sentinel `0xdead0000`, and the thread unwinds cleanly.
  `svc 0x6c` (`0x503187b8`) returns `[current_thread+0x34]`, the thread heap;
  B7e left it zero too, so guest allocation paths called RHeap with a null
  allocator and the HLE allocator rejected a pointer-sized request.
  `NK_THREAD_HEAP=<addr>` publishes a heap and those rejections disappear.
  Both knobs are opt-in. `tools/test_round98.sh` pins both runs.

- [x] **The handle-lookup slot keeps the kernel-time variant** (round 99):
  round 98's `0x3a` frontier is `CObjectIx::At` (`0x50380270`) executing
  `ldr ip,[ip,#0x14]; bx ip` with `ip=0x3a`. The object index at `0x80600e98`
  is built by the kernel: constructor `0x50384d44` installs vtable
  `0x503b36f8`, sets iCount=1 at `+0x10`, and leaves the entry array at
  `+0x14` null until something is registered. The ROM's `At` (the image value
  of slot `0x503b3948`) dereferences that null array, while the kernel
  build's variant (`0x5038e4b4`, what the round-29 map installs) reads a zero
  count and returns 0. `NK_IMPORTMAP_REVERT` therefore must skip this slot;
  `NK_IMPORTMAP_NO_REVERT=<hex,...>` lists slots that keep the kernel-time
  value. Reverts drop from 236 to 235, the `0x3a` crash is gone and the app
  thread unwinds through its trap frame. The remaining blocker is one bogus
  11.9 MB `ReAlloc` from EUser's descriptor-grow path (`0x5039c37c` via
  `0x5039c400`) while EFile builds its server name.
  `tools/test_round99.sh` pins it.

- [x] **Trace and clamp the oversized descriptor-grow request** (round 100):
  `NK_ALLOC_TRACE=1` logs the HLE bookkeeping size at `[ptr-8]` and the guest
  cell header at `[ptr-4]` for every intercepted realloc. The four healthy
  reallocs all satisfy `book = guest_hdr - 4`; the failing one never reaches
  that path, which proves `0x80601b68` is not a bump-heap payload (alloc_cur
  was only ~`0x80600830`), so EUser's descriptor-grow helper `0x5039c37c` is
  operating on a buffer the HLE heap never allocated and reading a garbage
  capacity word. Round 94's reject policy made EFile leave with KErrNoMemory;
  `NK_ALLOC_CLAMP=<n>` allocates n bytes instead, so the caller continues.
  EFile advances from 1,322 to 1,447 Thumb instructions with zero rejections,
  and the next defect is a null virtual call on `0x80100c38`
  (`[obj+8] -> [+8] == 0`, `r2=r6=0x2f`). `tools/test_round100.sh` pins it.

- [x] **Neutralise the guest heap housekeeping** (round 101): the null virtual
  call is inside `0x5039c954`, RHeap free-list coalescing. It locks
  `[heap]+0x1c`, walks the list at `[heap]+0x2c` and calls back through
  `[[heap+8]+8]`; the harness never builds a real RHeap, so any guest path that
  touches "the heap object" walks garbage. Dumping `0x80100c00..0x80100c80`
  shows the object is zero apart from two data pointers at `+0x0c`/`+0x10`
  (`0x80601b10`, `0x80601b68` - the descriptors from the round-99 grow traces)
  and two kernel handles `0xffff8001` at `+0x30`/`+0x34`. The new
  `NK_STUB_PC=<hex,...>` makes a listed guest address return 0, which
  neutralises unmodelled subsystems: EFile then uses the whole 900,000
  instruction budget (Thumb 1,447 -> 1,601) instead of stopping on the null
  call, and the next frontier is a TDblQue walk with an invalid head
  (`r0=8`, `r3=0x2f`) at `0x503a2660..0x503a2674`.
  `tools/test_round101.sh` pins it.

- [x] **The application thread runs on the kernel's real RHeap** (round 102):
  guest code was already passing a real heap pointer around - `0x80905ec4` is
  the RHeap the kernel creates during boot - which is exactly why round 101's
  heap housekeeping crashed on an object the harness never built. The kernel
  cannot give up the HLE allocator from the start (`NK_ALLOC_HLE=0` makes it
  halt with a PLAT fault at 12,595 instructions), so
  `NK_ALLOC_HLE_KERNEL_ONLY=1` disables it only once an application thread is
  dispatched. With `NK_THREAD_HEAP=0x80905ec4` the guest's alloc, free,
  coalesce and realloc all run for real: no stub, no clamp, no fault. EFile now
  leaves with KErrNoMemory (-4) through the round-98 trap frame (UnTrap returns
  `0x80004500`) because its descriptor grow still receives a stack address
  (`0x80561f28`) as a length. `tools/test_round102.sh` pins it.

- [x] **Application-time import rebinds** (round 103): EFile's startup
  function `0x503bfc78` creates objects and then calls EUser slot
  `0x503b37c4` with ONE argument (`bl` with only `r0` set, taken from the
  fixed global `0x80100c0c`), while the ROM's export 12 at that slot is
  `0x503988a8`, a THREE-argument heap grow (`svc 0x6c` then
  `0x5039c438 -> 0x5039c37c`). The leftover `r1`/`r2` are what make the heap
  receive a `0x503c7180`-byte request and EFile leave with KErrNoMemory: the
  application was linked against a different EUser `.def` revision than the
  ROM ships. `NK_IMPORTMAP_APP=<file>` applies per-slot rebinds after the
  kernel-time map is reverted. Sweeping exports 6..44 for that slot does not
  unlock EFile - the best outcomes are budget-bound spins (exports 20, 23, 44)
  and the Thumb count stays between 1,281 and 1,450 - so the mismatch is
  broader than one slot. `tools/test_round103.sh` pins it.

- [x] **The ROM EUser export table is shifted for applications** (round 104):
  163 ROM images import slot `0x503b37c4`, and SplashScreen (`0x509ef15c`,
  `mov r0,r4; bl`) and Starter (`0x509ececc`, `ldr r0,[sp]; bl`) call it with
  a single pointer argument too. The ROM's entry 12 is `0x503988a8`, a
  three-argument heap grow, while entry 9 (`0x5037fca0`) is the one-argument
  CleanupStack::PushL shape (it panics 0x2c/0x30 on an empty cleanup stack).
  So on this ordinal the application `.def` is three lower than the ROM table,
  matching the kernel map's K -> K-3 rule. Binding that slot to `0x5037fca0`
  makes EFile return from the call and continue at `0x503bfcf8` (before, it
  left with KErrNoMemory). A global table rotation is wrong though:
  `NK_EUSER_ROTATE` from 6/12/14 all fail at `0xe92d4070`, so the shift is not
  uniform. New frontier: `[obj+0x10] == 0` at `0x503bfcfa`.
  `tools/test_round104.sh` pins it.

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
| `tools/test_round36.sh` | MMIO write PC/LR provenance; `0x41000000`/`0x41080000` is the boot-region table, not the LCD framebuffer |
| `tools/test_round37.sh` | static display-chain inventory (`FbServ.exe`, `FbsCli.dll`, `BitGdi.dll`, `ecust.dll` hardware constants) |
| `tools/test_round38.sh` | direct Thumb FbServ startup; now reaches the 500k budget after the boot-state fixes |
| `tools/test_round39.sh` | exact FbServ vtable write/overwrite sequence; byte/halfword write watches |
| `tools/test_round40.sh` | FbServ descriptor/object overlap call chain and 20-byte allocation |
| `tools/test_round41.sh` | FbServ on the real banked SVC path, 1,499,521 instructions, EUser wait chain |
| `tools/test_round42.sh` | the 1.5M blocker is a post-executive stack/context switch, not the vtable or wait SWIs |
| `tools/test_round43.sh` | real SVC exception model; the 1.5M FbServ run was no-op SWIs, not a kernel path |
| `tools/test_round44.sh` | FbServ's first `svc #0x6c`, user/kernel bit-23 selector, and the dispatch-table frontier |
| `tools/test_round45.sh` | stable real-SVC FbServ, full 2M budget in the EUser wait loop |
| `tools/test_round46.sh` | splash-screen route; SplashScreen reaches EwSrv and stops on the bad pointer `0x506cbf1c` |
| `tools/test_round47.sh` | EwSrv export snap; SplashScreen runs the full 2M budget in the wait service |
| `tools/test_round48.sh` | wait-completion exposes a wild descriptor copy; direct EwSrv null-calls at `0x506c0b15` |
| `tools/test_round49.sh` | splash MBM header, no MBM load in RAM, EwSrv bad veneer literal `0x4a7846c0` |
| `tools/test_round50.sh` | EwSrv passes its first missing-DLL call via a mapped zero-return stub |
| `tools/test_round51.sh` | EwSrv callmap redirect to its real prologue, then the packed-veneer literal frontier |
| `tools/test_round52.sh` | EwSrv IAT is resolved but the veneer literal at `0x506c1dba` is padding (`0x40b846c0`) |
| `tools/test_round53.sh` | real LCD base `0x59200000`, framebuffer `0x59800000` |
| `tools/test_round54.sh` | the normal kernel boot also writes no LCD pixels |
| `tools/test_round55.sh` | EwSrv is a `TRomImageHeader` with a 7-entry DLL ref table |
| `tools/test_round56.sh` | app literals behave like link-time addresses; a `0x4a780000` link base lands on valid Thumb prologues |
| `tools/test_round57.sh` | EwSrv dllref section layout; the six tail entries are not per-import slots |
| `tools/test_round58.sh` | first guest-written LCD frame (white splash background) via guest `Mem::Copy` |
| `tools/test_round59.sh` | BitGdi export symbol map (`Clear`/`DrawBitmap` addresses mapped from the SDK import library) |
| `tools/test_round60.sh` | `CFbsBitmap::Create` hits the same unresolved veneer (`0x506dd80c` → `0xe59ff028`) |
| `tools/test_round61.sh` | real `SplashScreen.mbm` logo frame written through guest `Mem::Copy` |
| `tools/test_round62.sh` | app-entry allocator cell header, StartThread completion, and shared EUser export-slot conflict |
| `tools/test_round63.sh` | first app-side EUser import rebind; CBase vtable `0x503b359c`; static init returns cleanly |
| `tools/test_round64.sh` | TTrap rebind exposes the app main path; kernel SVC-return self-loop at `0x50314f78` |
| `tools/test_round66.sh` | low allocator rebind removes `0xe59ff028`; banked SVC loop remains; direct dispatch reaches EwSrv |
| `tools/test_round68.sh` | direct SplashScreen entry only initializes; EStart route opens at slot `0x503b6b38` |
| `tools/test_round69.sh` | EStart import bind; full 200k budget; stops in SVC/pre-handler at `0x50314f68` |
| `tools/test_round70.sh` | EStart wait HLE; 12,136 insns; zero-vtable object at `0x80600000` (historical map) |
| `tools/test_round71.sh` | EStart CBase rebind; 13,162 insns; bad virtual dispatch at `0x00a04d08` |
| `tools/test_round72.sh` | app slot `0x503b4338` = export 745, app expects export 747 (2-entry offset) |
| `tools/test_round73.sh` | HLE EStart bad dispatch; 200k wait loop on handle `0x32`; no draw |
| `tools/test_round74.sh` | nested SVC fix; EStart reaches `0x50398660` wait-status check |
| `tools/test_round75.sh` | exiting the wait retries StartThread handle `0x32`; real thread/server needed |
| `tools/test_round76.sh` | DThread clone still leaves the wait at KRequestPending; need request/server completion |
| `tools/test_round77.sh` | direct dispatch hits the same EStart handshake; SVC model is not the blocker |
| `tools/test_round78.sh` | fake scheduler thread reaches EStart server entry; null call at `0x503db18f` |
| `tools/test_round79.sh` | auto-complete runs the EStart server 200k; wild copy at `0x5038d724` |
| `tools/test_round80.sh` | Mem::Copy clamp advances the server to `0x503da6d5`; new import null call |
| `tools/test_round81.sh` | stack sentinel still null-calls at `0x503da6ee`; real StartThread frame needed |
| `tools/test_round82.sh` | server returns and supervisor resumes; still hits `0x00a04d08` |
| `tools/test_round83.sh` | HLE supervisor dispatch enters TTrap/leave at `0x5038cb70`; real object needed |
| `tools/test_round84.sh` | adjacent EUser slot targets also fail to draw; supervisor object is the blocker |
| `tools/test_round85.sh` | supervisor passes stack params as a CBase; `[this+0x14]` is a return address |
| `tools/test_round86.sh` | vtable pointer alone still enters TTrap/leave; real class vtable/method needed |
| `tools/test_round87.sh` | real vtable/method still fails on the stack params; real class instance needed |
| `tools/test_round88.sh` | global CBase as `this` also fails; real class instance/server response needed |
| `tools/test_round89.sh` | callback receives stack params instead of a CBase (superseded by round 90) |
| `tools/test_round90.sh` | EStart main `0x503db29c`, 0x24-byte params block, 12 EFSrv import slots; EFSrv is the blocker |
| `tools/test_round91.sh` | ROM boot chain `ekern->EFile->EStart->Starter->SplashScreen`; kernel object index is empty |
| `tools/test_round92.sh` | kernel idles after one timer IRQ; no process is ever created; harness must do the boot hand-off |
| `tools/test_round93.sh` | thread entry-mode honours iEntryPoint bit 0; EFile runs into the kernel |
| `tools/test_round94.sh` | EFile passes the kernel start hand-off |
| `tools/test_round95.sh` | `NK_IMPORTMAP_REVERT` keeps kernel-time rebinds out of the app thread |
| `tools/test_round96.sh` | app thread is not starved; EFile's SVC 0x1c "FileServer" gate |
| `tools/test_round97.sh` | application heap is HLE-only |
| `tools/test_round98.sh` | per-thread trap frame and heap pointer |
| `tools/test_round99.sh` | handle-lookup slot keeps the kernel-time variant |
| `tools/test_round100.sh` | oversized allocation traced and clamped |
| `tools/test_round101.sh` | `NK_STUB_PC` neutralises guest RHeap housekeeping |
| `tools/test_round102.sh` | the application thread runs on the kernel's real RHeap |
| `tools/test_round103.sh` | app-time import rebinds; the app/ROM EUser mismatch is broader than one slot |
| `tools/test_round104.sh` | **current acceptance**: first mapping of the EUser table shift (slot 0x503b37c4 -> export 9) |
| `tools/build_kernel_smoke.sh` | lifted C function linked against the runtime |
| `tools/build_rom_image.sh` | rebuild `out/6600_runtime.bin` |

Run everything:

```sh
for t in tools/test_*.sh; do sh "$t" || exit 1; done
```

## Repository layout

```
config/        target config, import maps, call maps
docs/          architecture, boot model, display chain, firmware format, progress
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
