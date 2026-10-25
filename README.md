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
| Firmware | **WD2 BT2 / WD2 ALGORITHM** container (`NHL105530.C1`) | A public, reversible flash format; `recompiler/wd2.py` extracts the 23.3 MB flash image (declared `rom_size` 22 MiB). |
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
   6600_mcu.bin  (23.3 MB flash image @ 0x50000000)   │
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
  memory + MMIO bus, a native ARMv4T interpreter for bring-up and unlifted
  callees (`NK_INTERP_FALLBACK=1`), and the S60 HLE layer.
- **`config/`** — per-target config ([`config/6600.toml`](config/6600.toml)).

## Status

**We have the real 6600 firmware, the EKA1 ROM, the kernel E32Image and the
ROMFS.** Honest checkboxes, no vapor. The detailed progress log, acceptance
criteria and phased roadmap live in
[`docs/PROGRESS.md`](docs/PROGRESS.md).

- [x] **Firmware extracted** — `NHL105530.C1` is a **WD2 BT2 / WD2 ALGORITHM**
  flash container. [`recompiler/wd2.py`](recompiler/wd2.py) strips the container
  and writes the **23.3 MB flash image** to `6600_mcu.bin` (linked at
  `0x50000000`); it also parses the ROM header, the E32Image headers and the
  ROMFS. No key, no password.
- [x] **Platform confirmed** — DCT4 / **UPP_WD2 / ARM920T (ARMv4T)**, Symbian OS
  7.0s / S60 2nd Edition. Flash image 23.3 MB at `0x50000000` (declared `rom_size` 0x1600000), kernel data at
  `0x80000000`, ROMFS plaintext and browsable (`wd2.py list`).
- [x] **Kernel located** — the EKA1 kernel E32Image (`uid3 0x100058e8`) is
  stored at packed-stream `0x31004c`; its text follows at `+0x64` (`0x3100b0`)
  and links at `0x50310000`, with entry `0x50310054` (ARM).  `wd2.py kernel`
  now carves the page-header-free text and skips the raw page header; the
  runtime uses the same stream.
- [x] **Packed records deinterleaved — the layout blocker is solved (round 16)**
  — the flash is stored as `0x20ec`-byte records: a **`0xec`-byte page header**
  followed by a **`0x2000`-byte payload**.  Rounds 7–15 kept the whole header
  inline (treating its first six bytes as a "page tag"), which inserted `0xec`
  bytes every `0x2000` bytes of every packed record.  That is why the kernel
  export table looked unrelated to the stored text.  [`recompiler/pagestream.py`](recompiler/pagestream.py)
  removes the headers: the kernel header is at stream `0x31004c`, its text at
  `+0x64` (`0x3100b0`), the entry `0x50310054` is an **ARM** `push {r4,r5,r6,lr}`,
  and the 478 kernel exports land on function starts **469 times (98.1%)**;
  DLL `0x100039e5` scores **1757/1788 (98.3%)** at shift 0.  The old
  "different function order / monotone drift" conclusion (B1g) was the page
  header, not the linker.  `romimage.py`, `layout.py` and `relayout.py` now read
  the page-header-free stream by default.  Bonus: the 586-entry directory below
  the kernel is **`\System\Libs`** — the boot image table the ROM header points
  into — and the old "586 Programs entries" label was wrong (round 19); the
  real `\System\Programs` has 55 server entries and Plugins has 171.
  `build` places 174 E32Image files and 85 AIF/MBM companions.
  `tools/test_pagestream.sh` is the acceptance test.
- [x] **Kernel entry runs — the real one (round 16)** — after removing the page
  headers the entry `0x50310054` is ARM, not Thumb.  The flat runtime image
  boots it for **924,964 instructions** with **0 undefined, 0 call fixups and
  0 recoveries**, programs the UPP (2 MMIO reads / 18 writes), and (with
  `NK_KERNEL_VECTORS=1`) installs the kernel vector table at 0 and
  `0xffff0000`, then reaches a stack/exception
  frontier at `0x5039b2b8` (the saved `lr` has been zeroed; PC returns to 0).
  The old "12 Thumb instructions → `0x50314c16`" and "197 instructions with 4
  skipped calls" results were executing the **page header**, not the kernel.
  `tools/test_pagestream.sh` pins the new run.  **Round 18 correction:** that
  924k run is a **runaway SWI fall-through**, not a boot; see the round-18
  bullet below.
- [x] **Lifter runs end-to-end on the 6600 kernel** — `recursive.py` (mode-aware
  Thumb/ARM discovery) + `lift.py` produce **131 mixed-mode functions** from the
  kernel (1,873 instructions, 99% lifted). `tools/build_kernel_smoke.sh` compiles
  them against the **sparse-memory runtime** and calls a real ARM kernel helper
  (`func_5031308c`): its write to `0x58000000` is logged by the new MMIO bus.
- [x] **Native ARMv4T interpreter + boot trace** — [`runtime/src/nokia_interp.c`](runtime/src/nokia_interp.c)
  executes ARMv4T (ARM + Thumb) against the same sparse bus, with a shadow call
  stack for mode restore and optional Thumb↔ARM inference. Earlier rounds fixed
  two real interpreter bugs: Thumb `BL` returned to `pc+2` instead of `pc+4`,
  and ARM PC-relative loads used `pc+4` instead of `pc+8`; both have regression
  tests. Round 5 added the Thumb format-2 fix described below, and round 13
  stopped data-processing immediates (`and r0,r0,#0xff`) from being decoded as
  extra loads/stores. The interpreter
  also self-checks against the lifted `func_5031308c` (`stop=returned`,
  `r2=0x58000000`).
- [x] **EKA1 image loader / import binding** — `boot_kernel.c` reconstructs the
  packed record (text, rdata, data, export dir, DLL-ref table), follows the
  kernel's two DLL references (UID3 `0x100065a5`, `0x100039e5`), loads their text
  and export directories, and resolves the first import stub through `.edata`
  ordinal 34. With `NK_CALL_INFER=1` the assisted trace runs 364 instructions
  into the imported DLL; the corrected crash-recovery run completes the kernel
  entry in **197 instructions with 4 skipped calls** (page-header artifact; see round 16 below).
- [x] **ROMFS extraction** — `System\Libs`, the app suite, sounds, skins and the
  E32Image headers are all reachable from the plaintext ROM.
- [x] **Flat runtime ROM assembly** — [`recompiler/romimage.py`](recompiler/romimage.py)
  reconstructs the runtime layout: the kernel and all 722 packed images at
  their header addresses, and the packed ROMFS tree below the kernel.
  `out/6600_runtime.bin` is exactly the declared 22 MiB, 1,580 sections with
  no overlaps, and `boot_kernel --rom-image` boots it.  The same tool prints a
  census of every direct `BL`: 3854 kernel sites, 478 exact, 3222 biased by
  4..0x308 bytes.
- [x] **Crash recovery + per-site callmap** — every `BL/BLX` snapshots the
  caller; `NK_RECOVER=1` rolls back a callee that faults and treats the call as
  "returned 0".  [`config/callmap-6600.txt`](config/callmap-6600.txt) pins
  individual stale call sites and supplies host-side helpers for
  compiler-runtime routines (`div`, `mod`, `memzero`, bump `alloc`, `memcpy`).
  [`config/patches-6600.txt`](config/patches-6600.txt) restores a Thumb `pop`
  that the following packed table overwrote.  `tools/test_boot_recover.sh` is
  the acceptance test.
- [x] **Thumb decoder bug fixed (round 5)** — the Thumb `add/sub rd,rs,#imm3`
  selector bit was inverted, so every Thumb pointer/length calculation used the
  wrong operand.  That invalidated the previous 2M/20M traces (including the
  descriptor-copy loop); after the fix the kernel entry executes cleanly and
  returns to the mask-ROM stand-in.  Call repair is also restricted to
  registered code ranges, so it can no longer snap into ROMFS data.
- [x] **Literal-pool relayout (round 6; now diagnostic)** — the page-header
  fix (round 16) makes the stream text already linked, so `relayout.py` is kept
  as a diagnostic (26 residual inserts, `0x34` bytes) and is not applied.
  Historically, `recompiler/relayout.py` finds
  literal pools and function starts in the packed text and inserts the ROM
  linker's 2-byte alignment padding.  The entry's pool moves from
  `0x5031008e` to `0x50310090`, the `ldr` now reads `0x00046564`, and all 787
  detected pools are 4-byte aligned.  The experimental relaid image boots the
  kernel entry **289 instructions** (315 with the callmap) instead of 197 and
  reaches UPP MMIO (`0x58120a04`, `0x58120110`, `0x59e00040`).
  (All of these round-6 numbers were measured on the raw page-header text; the
  corrected entry is ARM and the stream needs no relayout.)  The early entry
  also runs in the pre-MMU physical view, so `boot_kernel` maps a second 3 MiB
  RAM at `0x00000000` (`NK_NO_LOW_RAM=1` disables it).
- [x] **Full image map + ROMFS tree (round 7)** — packed image records are only
  **2-byte aligned**: the ROM build removed the linker's 4-byte padding, so a
  `TRomImageHeader` can start at 2 mod 4 (for example
  `\System\Libs\MmfAudioController.dll` at file `0x7271ca`).  Scanning every
  4th byte silently dropped 40+ images.  With a 2-byte scan plus a
  record-plausibility filter, **722 images** are recovered in the raw view
  (725 after the round-16 page-header removal) and their text ranges are
  disjoint, spanning `0x5030ff9c..0x515978dc`.
  `romimage.py build` now places **all** of them (1,847 sections, no overlaps)
  instead of only the kernel and its two direct DLL refs; the boot harness
  registers their text as code.  The ROMFS is a tree, and its directories are
  now located by content: root file `0x30fb28`, `\System` `0x30f230`,
  `\System\Libs` `0x301f70` (**586 entries — the ROM's boot image table**,
  round 19), `\System\Programs` `0x307a14` (55 server entries) and
  `\System\Libs\Plugins` `0x3000bc` (171 entries).  The old "9 valid Programs
  entries" and "586 Programs" labels were page-header/naming artifacts.  This
  gives the boot module table — `ekern.exe` (the kernel, uid3 `0x100058e8`),
  `ecust.dll`, `ecomm.ldd`, `ramdrive.pdd`, `rtc.dll`, ... — via the new
  `romimage.py names`.  Also fixed: ROMFS **data** files are not stored at
  `addr - 0x50000000`; the old build spliced unrelated code into 17 MB of the
  flat image.  They are packed in FS order (0xff-padded), so `build` no longer
  copies them from the linear address.
- [x] **Debugging the frontier (round 8)** — the interpreter now has a
  **call ring** (`NK_WATCH=addr` prints the registers plus the last 64 calls,
  their raw/resolved targets and arguments), a **tight-loop watchdog**
  (`NK_SPIN`, rolls a stuck scan back through recovery instead of burning the
  budget), a **PC-space guard** (`NK_CODE_ONLY`: RAM is not code) and
  `NK_ENTRY` for starting at an arbitrary address.  These features resolved a
  misleading result: the faithful image's old **2,000,000-instruction** trace
  is a path through ARM code created by the missing Thumb `pop` at
  `0x5039adcc`; the patched bring-up image still completes the kernel entry in
  **197 instructions** (page-header artifact).  The entry's third call (`0x50313522` →
  `0x50313518`) is real UPP initialisation (16-bit writes to
  `0x5815053a/0x5815053c/0x5815056a/0x58150200/0x58150508/0x5815004a`), and
  the fifth touches `0x58120308`/`0x59e00040`.  Starting at the ROM vector
  `0x50000000` runs 16,396 ARM instructions, turns on the MMU/cache and
  installs high vectors, then jumps to 0 — it is exception dispatch, not the
  reset path.  The two entry calls below the code base (`0x5030fbc6`,
  `0x5030807a`) remain the main blockers.
- [x] **Layout audit (round 9)** — export directories are fixed-up function
  address lists (Thumb entries carry bit 0; a 5-export DLL scores 5/5 on
  `push` prologues).  The kernel's 478 entries prove that the stored text is
  not the linked text: only 82 (17.2%) land on a start versus a 13.1% random
  baseline; a pool-aware detector (round 10) reaches 104/478 (21.8%) but the
  baseline rises to 17.2% in step (1.27x).  Padding cannot close the gap (the
  stored text is already 4-byte aligned for 1,420/1,430 ARM starts and 759/787
  pools).  [`recompiler/layout.py`](recompiler/layout.py) +
  [`tools/test_layout.sh`](tools/test_layout.sh) make the audit repeatable and
  re-frame B1g; details under the frontier below.
- [x] **App tree recovered (round 10)** — the packed 64 KiB block below the
  kernel holds the whole ROMFS directory tree.  `romimage.py tree` finds
  `\System\Apps` (the only all-directory `TRomDir`) and all **63 app
  directories**, including **`snakeex`** (SnakeEx.app, 0x7ddc) and
  **`mixpix`** (mixpix.app, 0xd718).  `romimage.py build` now copies the
  **76 E32Image files** (63 `.app` binaries plus 13 plugin/driver files) from
  their packed file records to their runtime addresses, plus **84 AIF/MBM**
  companion files found by their UID headers in each app's packed run.  The
  `\System\Programs` directory itself is truncated after nine boot entries
  (the rest is overwritten by the next packed record); `romimage.py` validates
  entries and reports this instead of inventing names.  The `.r01`/`.wav`
  resources still need B3g.
- [x] **Padding-only layout rejected; mask-ROM loader entry (round 11)** —
  `layout.py drift` tests the strongest "packed text + non-decreasing 2-byte
  padding" model (any stored start below an export, any monotone drift).  The
  kernel reaches 149/183/225 of 478 at budgets `0x60/0xc0/0x200`, against a
  random-address null of 140/169/217 (**1.04–1.09x**), so no padding/relayout
  can recover the linked order.  The census now reports `in-code%`: 135 images
  have every export inside their own code (the kernel is one), 155 are about
  half (a separate parser/format question), 36 lower, 366 none.  The boot
  harness accepts `NK_Rn`; the mask-ROM secondary loader is
  **`0x500003bc` → `0x50001648`**, driven by the `KaeP` descriptor at
  `0x50000124`.  It runs 211 instructions before stale calls are recovered;
  its type-switch table is **0-based**, so the boot bank must execute at
  address 0 (`NK_LOW_ROM=1`), not at `0x50000000`.  In that view it runs
  **299,991** instructions and reaches the high-vector/super-page frontier at
  `0x1248`.  `layout.py gaps` also finds **15 records whose header-less
  `.text`/`.data` block is a second Thumb/ARM code fragment** (the kernel and
  the big boot DLL gaps stay rodata).  `tools/test_layout.sh` pins the drift
  null test and the gap split; the interpreter self-test pins the opt-in
  low-alias window.
- [x] **Boot bank is fragmented; the linked view runs clean (round 12)** —
  the first 64 KiB of flash is not stored at its linked addresses.  It
  concatenates code fragments linked for different bases, so every absolute
  branch lands in the wrong fragment when the flash copy is run directly.
  [`recompiler/bootbank.py`](recompiler/bootbank.py) reads the relocation addend from
  `0x3b0` (`sub r1, pc, #0x308; add r0, r0, r1` → **0xb0**) and measures the other fragments
  from the 17 compiler switch tables: **A** `0x0-0x2000` ← stored
  `0xb0-0x20b0` (bias `0xb0`, 7/7 exact), **B** `0x2000-0x6000` ← stored
  `0x219c-0x619c` (bias `0x19c`), **C** `0x6000-0x8000` ← stored
  `0x6374-0x8374` (bias `0x374`, pinned in round 15).  The two gaps
  (`0xec` / `0x1d8`) contain further ARM/Thumb code, not padding.  `build`
  moves A/B/C to their linked addresses and the boot
  harness maps the result at 0 (`NK_LOW_ROM_IMAGE`, start `0x30c`): the loader
  now runs **600,000 instructions with zero stale-call recoveries** (round 11
  needed 9 and looped at `0x125c`), reaches the image-loader thread at
  `0x1244`, and writes a real UPP register (`0x08000008 = 0x37`).
  `tools/test_bootbank.sh` is the acceptance test.
- [x] **ARM immediate decode fixed; boot-region table modeled (round 13)** — the
  interpreter's extra-load/store test ignored bit 25, so a data-processing
  immediate such as `and r0, r0, #0xff` (bits 7-4 = 1111) was executed as a
  bogus `LDRH/STRH`.  ARMv4T extra loads/stores require bit 25 = 0; the
  regression is pinned in `interp_selftest`.  The mask ROM's boot-region table
  is now explicit: [`recompiler/bootregions.py`](recompiler/bootregions.py)
  derives boot/ROM/RAM banks from `TRomHeader` (count + `0x10`-byte entries:
  `base/size/attr/linbase`), and `NK_REGIONS` installs it in the boot harness.
  With the table the super page moves from the `0xfffff000` fallback to
  `0x802ff000` and the compacted list at `0x802ff400` has the three banks.
  `tools/test_bootregions.sh` is the acceptance test.  The remaining KaeP
  frontier is now inside the payload lookup, not an empty list.
- [x] **KaeP becomes measurable; the loader passes 0xc58 (round 14)** — the
  first 7 MiB of flash are a **paged** boot image: a 6-byte tag
  `20 00 00 00 dc 23` every `0x20ec` bytes, first real tag at `0x20b0`, last
  at `0x6d9134` — **852 tags**.  (The bytes at `0x128` are the KaeP size/value
  prefix and happen to spell the same six bytes; they are not a tag.)  The
  kernel text starts exactly on a tag (`0x326924` =
  `0x50310000`), so its entry `+0x54` is valid while code after later tags is
  shifted six bytes per page.  [`recompiler/kaep.py`](recompiler/kaep.py)
  measures the grid, writes the experimental tag-free view, and provides an
  explicit descriptor/node stand-in.  The boot-region model was corrected:
  `0x1a1c` only sees type 5..8 banks with attr bit `0x04000000`, and
  `0x1b34` only type 2, so the old `attr=1` table could never satisfy the KaeP
  lookup.  `bootregions.py --profile linear` (type-2 RAM, type-5 ROM/boot,
  linear flag, 6 MiB via `NK_RAM_EXTRA`) lets the **original** linked bank
  pass `0xc58`; 600,000 instructions later it stops in the page-table fill at
  `0x2fe4` with zero recoveries/undefined.  `tools/test_kaep.sh` is the
  acceptance test.  This is a new frontier, not a finished boot; the real
  KaeP unpack, the `linbase` base-vs-page-mask ambiguity and the page-table
  target are the next tasks.
- [x] **Fragment C, the CPU table and the boot-image handoff (round 15)** —
  the boot bank's third fragment (**C**) was measured but not relocated.  Its
  16-bit CPU/board table lives at linked `0x74b8`; the correct halfwords
  (including the CPU value `0x3b`) are stored at file `0x782c`, exactly
  `linked + 0x374`.  `bootbank.py build` now relocates C, so the loader's CPU
  lookup at `0x3d10` succeeds instead of comparing `0x3b` against instruction
  bytes and halting in the `b .` panic at `0x3d44`.  Two more pieces make the
  loader reach its real handoff: [`recompiler/bootbringup.py`](recompiler/bootbringup.py)
  writes an explicit KaeP descriptor plus a **list head → node → terminator**
  chain (`0xfd00 → 0xfd10`, node type `0x05040000`), and
  `bootregions.py --profile staging` supplies type-5 code/data banks whose
  `base + size - section_size` resolves the kernel code section to
  `0x50310000` and the `.data` section to `0x80000000`.  The interpreter now
  stops on `b .` as a panic halt (`NK_STOP_SELF_BRANCH`), and the MMIO bus
  stubs the two UPP handshake reads (`0x58150422` bit `0x400`, `0x58120a08`
  non-zero).  Result: **36,732 instructions, 12 MMIO reads, 46 writes, one
  recovered stale call, zero undefined**, stopping at the **boot-image
  handoff `0x80`**.  `tools/test_bootbringup.sh` is the acceptance test.
  Round 17 replaces the parser skip with an executable handoff (below).

**← current frontier →**

- [x] **KaeP/PeaK container unpacked; handoff enters the kernel (round 17)** —
  the block at file `0x124` is the Nokia **PeaK** marker (`0x5065614B`
  little-endian), a `u32` record size `0x20`, and a `u32` image size
  `0x1423dc`.  The 0x20-byte record starts at `0x12e` (it overlaps the high
  half of the size word) and the embedded image starts at `0x14e` with a clean
  ARM vector table; image `+0x38` is real boot code.  [`kaep.py`](recompiler/kaep.py)
  now has `unpack` (extracts the record and image byte-for-byte, with SHA-256)
  and `install` (writes `ldr pc,[pc,#-4]; .word 0x50310054` at linked `0x80`
  plus the descriptor/list the loader consumes).  The loader now enters the
  real kernel instead of taking `SWI 0xf9ea00` on the record bytes:
  **1,499,999 ARM instructions, 0 undefined, one recovered stale call**, ending
  in the kernel code range.  `tools/test_kaep.sh` and
  `tools/test_bootbringup.sh` pin the container and the kernel-entry run.
- [x] **The 924k run was a runaway SWI fall-through; the executive call gate is
  now explicit (round 18)** — EUser.dll implements the user-side kernel API as
  a dense table of single-instruction `svc #N` stubs
  (`0x50392b00..0x50392dc8`).  The interpreter logged SWIs and continued, so a
  branch into one stub fell through the **whole table**, entered the real
  function after it (`0x50392dcc`) and looped with a **`0x4b0` stack leak per
  iteration** until the stack left the mapped super page.  The `bx lr` with
  `lr=0` at `0x5039b2b8` is a symptom, not the stack/super-page frontier.
  [`executive.py`](recompiler/executive.py) now decodes the kernel SVC handler
  (`0x50314f30`), its `0x444`-byte bound, and the **273-entry** service table
  at `0x50314aec` (270 code targets; four unimplemented slots `0x8a/0x94/0x95/
  0x96`), and maps every SVC stub in every image back to its service.
  `NK_SWI_DIRECT=1` models the EKA1 call gate: dispatch to the service with the
  caller's LR still live (the stub is a call gate, not a post-SWI
  continuation).  Direct dispatch exposes the real blockers: the
  scheduler/current-thread global `[0x800017d4]` is zero (the E32 entry is run
  without the mask-ROM/kernel startup that creates the initial thread), and
  IAT slot `0x5037d0e8` still contains `0xffffffff` (the flat-image builder
  does not bind imports).  With the explicit `NK_FAKE_THREAD` object and the
  `NK_SWI_COMPLETE=0x4d` wait-completion stand-in the kernel runs **7,540
  instructions** (0 undefined) and stops at the **unbound IAT slot
  `0x5037d0e8`** (`sp=0x802fff08`, `cpsr=0x800000d3`).  A second decoder bug
  surfaced on this path: the multiply decoder accepted any instruction whose
  bits 7-4 are `1001`, so `sub sp, sp, #0x258` executed as a bogus MUL and
  zeroed SP.  Multiply/MLA now also require bits 27-22 = `000000`
  (`interp_selftest` pins it).  Faking the unbound IAT return
  (`NK_IAT_FAKE=1`) runs 8,425 instructions and corrupts `r4=0x00730072`
  until PC 0; that is a control, not the frontier.  `tools/test_executive.sh`
  pins the table, the stubs and both outcomes.  The old 924k number is kept
  only as a regression baseline.
- [x] **ROMFS boot table + flat-image import binding (round 19)** — two coupled
  corrections.  First, the 586-entry directory below the kernel is
  **`\System\Libs`**, not Programs: the ROM header's
  `iPrimaryFile`/`iSecondaryFile`/`iVariantFile`/`iExtensionFile` are
  `TRomEntry` pointers into it and name `ekern.exe`, `EFile.exe`, `ecust.dll`
  and `rtc.dll`.  An older build overlaid Libs with `\System\Libs\Plugins`
  (171 entries), so the kernel's boot loader read UTF-16 name bytes as an
  image header.  The directory block is now copied linearly at its runtime
  addresses and verified in place; `\System\Programs` is the real 55-entry
  server list and Plugins is the 171-entry plugin directory.  Second,
  [`imports.py`](recompiler/imports.py) enumerates **257 kernel import stubs
  (236 EUser + 21 ELocl)** and proves every slot already holds a code address
  except **ELocl ordinal 20**, an export-table hole (`0xffffffff`).  A flat
  image needs no copy for real exports — the slot *is* the exporting image's
  export entry.  `NK_IMPORTMAP=config/imports-6600.txt` binds the hole to an
  explicit zero-return stub at load time.  With the fixed ROMFS the kernel now
  runs the real `rtc.dll` extension path for **8,512 instructions, 0 unbound
  IAT, 0 undefined**, and stops at the next real blocker: EUser's
  `RHeap::Alloc` with a null current-thread heap (the kernel overwrote
  `[0x800017d4]`).  `tools/test_imports.sh` pins the import map, the ROM-header
  boot entries and the new frontier.
- [x] **Round 20: MUL destination bug + the real B7e state** — two
  corrections.  First, the ARM interpreter decoded MUL/MLA's destination from
  bits 15-12, but `Rd` is bits 19-16 (bits 15-12 are only MLA's accumulator).
  Every plain `mul rd, rm, rs` therefore wrote **r0** and left the real
  destination unchanged; the object-index accessor's size multiply lost its
  result pointer this way.  The fix is in [`nokia_interp.c`](runtime/src/nokia_interp.c)
  with an `interp_selftest` regression (`mul r2,r0,r1` must leave r0 alone).
  Second, the round-19 "EUser `RHeap::Alloc` with a null heap" diagnosis was
  wrong: the accessor at `0x50380270` indexes an object array
  (`[this+0x18]` array, `[this+0x14]` element size, `[this]` base), and its
  caller `0x50318410` is the handle-to-object path
  `[thread+0x18] -> [process+0x38]`.  That is **`CObjectIx::At`**, so the
  missing boot state is the initial **process and its object index**, not a
  heap.  `NK_B7E=1` installs thread → process → `CObjectIx` → element fetch and
  follows every current-thread update with a new guest write watch.  The run
  leaves the old 8.5k stop behind: **5,575,900 instructions, 0 undefined,
  0 call fixups, 0 recoveries**, including the kernel's second thread
  `0x80001860`; the next frontier is that thread's stack underflow (`pc=0`).
  The pre-MMU low alias now also tracks `NK_RAM_EXTRA`.
  `tools/test_b7e.sh` is the acceptance test.  **Round 21 reclassifies the
  5.575M stop:** it was the panic printer looping on a broken import/descriptor
  path, not a second-thread stack frontier.  See the round-21 bullet.
- [x] **Round 21: EUser import ABI, RTC driver rodata, KERN-NO-SESSION** —
  the round-20 graph exposed four kernel EUser import slots that resolve to a
  function with the **wrong ABI**: the kernel was linked against a different
  EUser `.def` revision than the EUser DLL in this ROM.  The panic printer
  (`0x503b391c`, ord 98) expected `TDesC16::AtC` but got an array accessor;
  panic init (`0x503b4d1c`, ord 1378) expected the 2-arg `TPtr16` ctor but got
  the 3-arg one; object-container init (`0x503b4b9c`, ord 1282) expected
  `TBuf16(int)` but got a string copy; locale init (`0x503b3b70`, ord 247)
  expected `TDes16::Copy(buf,len)` but got the descriptor overload.  The
  loader now applies `NK_IMPORTMAP` overrides even to already-bound slots, and
  [`config/imports-b7e-6600.txt`](config/imports-b7e-6600.txt) rebinds those
  four slots explicitly (the confirmation-only map stays in
  `config/imports-6600.txt`).  Two more real fixes: the `CObjectIx` element
  fetch must fill a **`TDesC8` descriptor** (`TDesC8::Ptr` at `0x5038891c`
  runs next), and the handle path must return a **CObject with a vtable**, not
  the live scheduler stack block.  Finally, the RTC physical-device driver
  (uid3 `0x100000d8`) keeps its vtable and strings in the **header-less block**
  after `.text` (`--place-rodata`); without it the RTC constructor read a zero
  vtable and died at `pc=0`.  With the vtable live, `User::AllocZ` served from
  the harness `RHeap::Alloc` (`NK_ALLOC_PC=0x5038e2ec`) and a minimal HAL
  stand-in (`0x800003ac` → vtable `0x80003c00`), the RTC driver constructor
  completes.  The run now reaches **8,655 instructions, 0 undefined,
  0 call fixups, 0 unbound IAT, 0 recoveries** and halts in the panic printer
  at `0x50312b88` with **KERN-NO-SESSION 22** while loading **Econs.dll**
  (uid3 `0x100039e7`).  That is a file-server/session dependency, not an
  import or layout problem.  `NK_WATCH_MEM=rN:len` dumps guest memory at a
  watch PC.  `tools/test_b7e.sh` pins the new frontier.  **Round 22 corrects
  the diagnosis:** the ECons load was the RTC driver's misbound allocator
  entering EUser's RTest console path, not a real boot service.
- [x] **Round 22: RTC extension is a nested E32Image; boot reaches 27,470** —
  the "RTC PDD header-less rodata block" is a **second E32Image**: uid2
  `0x100058d8`, text `0x5033ee14..0x50341414`, data `0x50341414`,
  `export_count` 0.  The kernel's extension loader calls its entry
  `0x5033ee14` (the driver object constructor) and then **export ordinal 1**
  through `[hdr+0x40]`; a zero export directory is a jump to 0, so the boot
  harness needs an explicit extension export stub.  The RTC driver's
  `new(0x38)`/`new(8)` import (EUser export index 1504) resolves to
  `RTest::operator()` in this ROM (it references `": FAIL : ..."` and
  `"Checkpoint-fail"`), not to `operator new`: the driver and EUser were
  linked against different `.def` revisions.  The constructor therefore
  entered the RTest console path, which loaded ECons.dll — the round-21
  "file-server session" was a symptom of that ABI mismatch.  Round 22 adds
  `NK_HLE_ZERO2` (zero a 64-bit `TTime` out parameter), a real HAL channel
  **object** for the B7e HAL stand-in (the old integer 1 was later
  dereferenced as a vtable pointer), and `NK_EXT_STUB=1` (an export stub for
  the nested extension header).  With
  [`config/callmap-rtc-6600.txt`](config/callmap-rtc-6600.txt) the RTC
  extension initialises completely: **27,470 instructions, 0 undefined,
  0 unbound IAT, 0 recoveries**.  The new frontier is the post-extension boot
  initialisation `0x50310fa4` → `0x5031f3a8`, which builds an `"IrqTimer0"` descriptor
  (literal `0x50337200`) and checks the kernel `.bss` timer object at
  `0x80000b5c` (`[0x80000b5c] == 0xff`, else panic PLAT 21); the direct E32
  entry skipped the mask-ROM/kernel startup that fills it.
  `tools/test_rtc.sh` is the acceptance test.
- [x] **Round 23: timer names, RAM page bitmap, super page, WD2 CTSI DMA** —
  the PLAT 21 gate was **another EUser ABI mismatch**, not missing boot state.
  The kernel's `"IrqTimer0"`/FIQ-name initialiser constructs 8-byte `TDesC8`
  names at `0x80000b54, b4c, ...`; the ROM's export index 1384 is a **12-byte**
  default constructor, so it overwrote the timer object's state word at
  `0x80000b5c` with zero.  Rebinding the slot to `TDesC8(const char*)`
  (`0x50388984`) lets the timer start cleanly.  The next lookup used
  `DObject::Close` as `TDesC8::Compare` (descriptor length `0x1000000d` was
  treated as a handle) and panicked KERN-EXEC; it is rebound to
  `0x50388e30`.  The kernel's fixed bootstrap page is **`0x40000000`**
  (`iTotalRamSize` at `+0x10`, `iRamBootData` at `+0x18`,
  `TMachineConfig` at `+0x800`), not the `0x7ff00000` window the harness
  used to map.  `NK_SUPERPAGE=1` maps it and publishes a 6 MiB RAM bank list
  (`4 MiB + 2 MiB`); the RAM allocator then builds its page bitmap.  That
  exposed two more wrong-ABI slots: a 2-byte array allocator used as
  `CBitMapAllocator::New`, and a `CBufSeg` helper used as `AllocFrom`; the
  round-23 map rebinds `New`/`Alloc`/`AllocAt(pos,count)` to the real
  implementations at `0x50381b28`/`0x50381b84`/`0x50382418`.  The B7e stand-in
  now follows the kernel's real `DProcess` (not just the first thread) and
  supplies the live thread's `[thread+0x5c]` object.  With one HAL stand-in
  for the WD2 CTSI DMA hand-off the run reaches **139,784 instructions,
  0 undefined, 0 unbound IAT, 0 recoveries**, through page tables and WD2
  CTSI DMA init, and stops in a deliberate **USER-EXEC 3** because the current
  thread has no trap/exception handler: the direct E32 entry skipped the
  scheduler's initial trap state.  That is the new frontier.
  [`config/imports-wd2-6600.txt`](config/imports-wd2-6600.txt) pins all
  11 overrides; `tools/test_round23.sh` is the acceptance test.
- [x] **Round 24: EUser ABI panorama; real time, object containers, process
  creation; 126,238 instructions** — the round-23 `USER-EXEC 3` was not a
  missing trap state: the kernel's EUser imports were linked against a
  different export order than the EUser image in the same ROM.  The time
  cluster's slot `0x503b50c0` resolves to `__truncdfsf2`, but the kernel calls
  it as `TInt64::operator>>(int)` (hidden return pointer, this, shift); the
  double underflow then raised the exception.  Round 24 rebinds the whole
  call-site-visible cluster: ten `TInt64`/`TTime`/`TTrap` functions, the
  `CObjectConIx::NewL`/`CreateL` pair used to build the 16 kernel object
  containers, and `TDesC16::Locate`/`Mid` plus `TDesC8::Alloc` used to parse
  the initial process name.  The HLE bump heap now carries 8-byte block
  headers and serves `RHeap1::ReAlloc1`/`RHeap::Free`, so the real realloc
  path copies bump blocks instead of reading a synthetic header.  The run
  executes the real `P::InitSystemTime`, creates the object containers and
  enters initial process creation, reaching **126,238 instructions, 0
  undefined, 0 unbound IAT, 0 recoveries, 33 call fixups**.  It stops in
  `CleanupStack::PushL` with **USER-CBase 69** because the direct E32 entry
  has no scheduler-installed trap frame.  [`config/imports-r24-6600.txt`](config/imports-r24-6600.txt)
  pins 26 overrides; `tools/test_round24.sh` is the acceptance test.
- [x] **Round 25: real CTrapCleanup graph; process construction ABI;
  125,864 instructions** — `NK_TRAPCLEAN=1` now builds the objects the
  skipped user-side startup would have created: a `TCleanupTrapHandler`
  whose vtable is EUser's own (`0x503b3518` → `Trap/UnTrap/Leave`
  `0x50383c38/40/48`), a `CCleanup` with `iBase/iTop/iNext`, eight cleanup
  items and one TRAP level marker.  Each published thread gets its own slot,
  published at `thread+0x3c` (`iTrapHandler`); `thread+0x38` (`iFrame`) stays
  zero until guest `TTrap::Trap` pushes a real frame.  `CleanupStack::PushL`
  therefore runs EUser's real `CCleanup` code instead of panicking 69.
  Crossing that point exposed four call-site ABI mismatches: the process-name
  copy needs `TDes16::Copy(TDesC16 const&)` (`0x503b42c8` → `0x50388408`),
  the object lookup needs `CObjectCon::FindByName` (`0x503b3e28` →
  `0x50385650`, not `FindByFullName`), `DProcess::New` needs `User::Alloc`
  (`0x503b379c` → `0x503988f0`), and the 8-byte process name needs
  `TBufBase8(int)` (`0x503b4bec` → `0x50388b24`).  The initial `DProcess`
  `0x806008b8` is now really allocated and constructed; the run reaches
  **125,864 instructions, 0 undefined, 0 unbound IAT, 0 recoveries, 22 call
  fixups** (30 overrides in
  [`config/imports-r25-6600.txt`](config/imports-r25-6600.txt)).  It stops
  while closing that process through DProcess vtable `+0xc`: kernel slot
  `0x503b4410` resolves to EUser index 799, which in this ROM is an object-close
  panic helper, so the stop is **KERN-NO-SESSION 52**.  Rebinding that slot to
  the `RHandleBase` close wrapper only moves the stop to E32USER-CBase 44.
  The next task is a **symbol-level DProcess/DObject vtable ABI map** (several
  slots in the same vtable target different EUser ordinals), not another
  single-function guess.  `tools/test_round25.sh` is the acceptance test.
- [x] **Round 26: CObject/DProcess base-class ABI; process registration;
  126,866 instructions** — target EUser has the real `CObject` class at
  vtable `0x503b362c`: `+0x0c Open` (`0x50384b28`), `+0x10 Close`
  (`0x50384b3c`), `+0x14 Name` (`0x50384bf8`, hidden return pointer),
  `+0x18 FullName` (`0x50384c34`); the constructor `0x50384a98` sets
  `iAccessCount=1`.  The kernel's DProcess vtable `0x50338690` inherits the
  same order, so round 25's `+0xc` call was **Open**, not Close.  Eight
  bindings are now real: the five CObject base methods, `CObjectCon::AddL`
  (`0x503851e0`, ordinal 6 — not `CheckUniqueFullName 0x50385598`),
  `CObject::Name` for the name copy, and the shared `memmove`/`memcpy`
  `0x5038cfe0`.  The initial process `0x806008b8` is constructed, opened and
  inserted into `K::Containers[EProcess]`; the run reaches **126,866
  instructions, 0 undefined, 0 unbound IAT, 0 recoveries** (38 overrides in
  [`config/imports-r26-6600.txt`](config/imports-r26-6600.txt)).  It then
  stops in the kernel's own `DProcess::Name` override: its stale descriptor
  slots overwrite the temporary `TName`, so `CheckUniqueFullName` raises
  **USER 7** (`ETDes16BadDescriptorType`).  A documented stand-in that points
  DProcess vtable `+0x14` at EUser's real `CObject::Name` passes name
  registration and reaches **126,778 instructions**, stopping at a zero
  return address in `DProcess::Loaded` (`pc=0`, `lr=0x5031fe84`).  The next
  frontier is therefore the **descriptor ABI in DProcess::Name** and the
  Loaded callback stack, not the CObject base class.  The interpreter
  self-test gained an LDMDB/STMDB writeback regression for the memmove
  backward path.  `tools/test_round26.sh` is the acceptance test.
- [x] **Round 27: the kernel/EUser import order is a constant -3; real
  DProcess name ABI; one K=1361 exception; HAL timer frontier** — the
  kernel was linked against an EUser `.def` one export shorter than the
  generic 7.0 list, while the EUser.dll in the same ROM is four exports
  shorter.  For kernel ordinal `K >= 6` the desired symbol is therefore the
  ROM EUser export at **`K - 3`**; `K=0` (memset), `K=1` (`Mem::Copy`) and
  `K=2` (`User::Alloc`) are the low special cases.  [`euser_reloc.py`](recompiler/euser_reloc.py)
  verifies 49 call-site anchors across the CObject, CObjectCon/ObjectIx,
  TInt64/TTime, descriptor/name and queue-iterator clusters and emits
  [`config/imports-r27-6600.txt`](config/imports-r27-6600.txt) (236 slots)
  plus a 47-slot name probe.  The DProcess name function is now decoded as
  `CObject::Name` + `TUidType::operator[](2)` + a `[uid]` formatter +
  `AppendNumFixedWidth(iGeneration, EDecimal, 4)`, with the real
  `TUidType()`/`TUidType(TUid,TUid,TUid)` constructors
  (`0x5039b2a0`/`0x5039b2f0`) and `TDblQueBase` constructors (not TBuf8/16).
  The name-probe run constructs the process with UIDs
  `1000007a/1000008b/100000b9`, registers its name through
  `CheckUniqueFullName` **without the round-26 NK_PATCH stand-in**, and
  reaches **128,663 instructions, 0 undefined, 0 unbound IAT, 0
  recoveries**.  The full relocation pins one local exception, `K=1361`
  (the 0x74-byte boot-file base constructor): the shifted target
  `0x5039c148` writes at `+0x7c` and overruns the object into the next
  `TRomEntry`, corrupting `0x50301f40`; the ROM's own `0x503a0224` zeroes the
  16-byte base.  With the flat (linked) image and **`NK_CALL_INFER=0`** the
  faithful path reaches **108,231 instructions, 0 undefined, 0 unbound IAT, 0
  recoveries** and stops at **USER-EXEC 3** in `K::Init1`.  The root is the
  **HAL timer frequency**: `0x503109d0` reads `[0x800003ac]->vtable+0x5c`
  and stores it at `0x800017f4`; the current stand-in returns 0, so the kernel
  does `1,000,000 / 0`, and the division slow path returns KErrGeneral
  (`0xffff8001`) which the caller passes to `CObjectIx::At` as a handle.
  Pointing vtable `+0x5c` at a constant-return stub (`0x503109a0` returns 4)
  advances to **117,923 instructions** and a new KERN panic
  (`0x5031c9d0 -> 0x503309fc`).  The
  `NK_CALL_INFER=1` run reaches only **14,354** instructions and a MATHX
  panic because it snaps the valid EUser internal call `0x5038ad44` to
  `0x5038ad20`; it is kept as a control.  The old 126k/128k numbers were
  wrong-import detours.  A `NK_BOOTTABLE_RAM` model copies the 64 KiB ROMFS
  directory to RAM but does not change the 108k stop.
  `tools/test_round27.sh` pins all four runs.
- [ ] **Initial thread trap frame (remaining after round 25)** — the handler
  and cleanup stack are real now, but `SThread::iFrame` (`+0x38`) is still
  zero.  A guest `TTrap::Trap` pushes and pops frames correctly; a `Leave`
  that unwinds past the synthetic startup level still has no saved context to
  return to.  Restoring that needs the scheduler/mask-ROM startup TRAP or a
  modeled initial `TTrap` context, and the first request completion.
- [ ] **PeaK record codec** — the mask ROM's transform of the 0x20-byte record
  is still undocumented.  `unpack` preserves the record; `install` is the
  explicit handoff stand-in.  A future round should decode the record rather
  than install the trampoline, and remove the remaining `0x3ae8 → 0x5bb4`
  stale call.
- [ ] **Boot-region page tables (round 14 control)** — the old `linear`
  profile still reaches the `0x2fe4` page-table fill because its type-2 RAM
  bank's `linbase` is a base address where the compaction pass expects a page
  mask.  It is kept as a control; `--profile staging` uses the `0xffffffff`
  no-expand sentinel for that bank.
- [x] **Packed text vs. export table — solved (round 16)** — the 17.2%/21.8%
  export hit rate, the monotone-drift null test and the "different function
  order" conclusion were all measured on raw bytes with the `0xec`-byte page
  headers still inline.  On the page-header-free stream the kernel scores
  **469/478 (98.1%)** and DLL `0x100039e5` **1757/1788 (98.3%)** at shift 0.
  `layout.py verify` now asserts that instead of the old null result;
  `tools/test_layout.sh` pins the new numbers.
- [x] **Kernel stack/exception frontier (round 18/21 reassessment)** — the
  round-16 924,964-instruction run was the SWI-table fall-through loop; the
  direct call gate then stopped at a real missing state (`[0x800017d4]` = 0).
  Round 19 fixed the ROMFS boot table and the import hole; round 20 installed
  the initial thread→process→CObjectIx graph; round 21 found that the
  **5,575,900-instruction run was the panic printer looping** on four
  wrong-ABI EUser imports and a bare-pointer object-index element.  With those
  rebinds, a real `TDesC8` element descriptor, driver rodata and the allocator
  stand-in, the run reaches **8,655 instructions** and halts in the panic
  printer with **KERN-NO-SESSION 22** while loading Econs.dll — a
  file-server/session dependency, not a stack/exception frontier.  The
  banked-register model (`NK_BANKED=1`) and mode stacks remain available but
  are no longer on the critical path to the next boot step.  **Round 22
  reclassifies the ECons stop** (RTest console via the misbound RTC
  allocator) and advances the run to 27,470 instructions.  **Round 23 then
  shows the PLAT 21 gate was a TDesC8 ABI mismatch** and follows the RAM
  allocator, page tables and WD2 CTSI DMA init to **139,784 instructions**.
  **Round 24 shows the resulting USER-EXEC 3 was the last wrong-ABI import**:
  the time cluster, the 16 `CObjectConIx` containers and the initial process
  name parser are all rebound, and the boot reaches **126,238 instructions**
  before the initial process create hits the missing trap frame
  (`USER-CBase 69`).  **Round 25 installs a real per-thread
  `CTrapCleanup` graph**, fixes four process-construction ABI slots, and
  constructs the initial `DProcess` for the first time; the run reaches
  **125,864 instructions** and stops at the DProcess close-vtable ABI
  (`KERN-NO-SESSION 52`).  **Round 26 recovers the CObject base ABI**
  (`+0xc` is `Open`, not `Close`) and the real `CObjectCon::AddL`, so the
  process is opened and inserted into `K::Containers[EProcess]`; the run
  reaches **126,866 instructions** and the next stop is the descriptor ABI
  inside `DProcess::Name` (`USER 7`).  **Round 27 shows the whole kernel EUser
  import table is a constant -3 relocation**, decodes the real DProcess name
  ABI, pins one local exception (K=1361) and reaches the **HAL timer
  frequency frontier** at 108,231 instructions (USER-EXEC 3; the HAL
  vtable+0x5c returns 0 and the kernel divides by it).  Poking vtable+0x5c to
  a constant advances to **117,923**.  The name probe reaches **128,663
  instructions** without a stand-in; the call-inference control
  (14,354/MATHX) is an artifact, not truth.
- [ ] **File server for UI/app loads (round 22 reclassification)** — the
  round-21 ECons.dll / **KERN-NO-SESSION 22** stop was the RTC driver's
  misbound `operator new` import entering EUser's `RTest` console path.  With
  the round-22 allocator/HAL/extension fixups the RTC extension no longer
  requests a session.  A real ROMFS/E32 file service is still required by the
  UI/app layer (P3), but it is no longer the next boot milestone.
- [ ] **Boot bank board/CPU detection (round 16 stream view)** — after the page
  headers are removed the boot bank is the contiguous stream slice
  `[0xb0, 0x100b0)` and all switch tables measure bias 0.  The **correct**
  linked loader follows a different call path from the old raw A/B/C view and
  stops in a deliberate board/CPU detection panic at linked `0x624c`
  (`r5 = 0x0c0047fd`, `r0 = 0x10`).  The old 600k-instruction raw run was
  using the B2 page header as code; it is kept only as a legacy regression.
- [x] **Packed ROMFS naming corrected (round 19)** — the 586-entry list below
  the kernel is `\System\Libs` (the boot image table read by the ROM header),
  `\System\Programs` is the 55-entry server list and
  `\System\Libs\Plugins` is the 171-entry plugin directory.  The old
  "586 Programs / 171 Libs" label came from matching directory contents to the
  wrong parent names.  `build` places 174 E32Image files and 85 AIF/MBM
  companions; the remaining ROMFS work is the `.r01`/`.wav` packed data area
  (B3g).
- [ ] **Boot continuation** — the real post-entry path (mask ROM → kernel main
  → scheduler) is still unknown.  The direct executive-call run now reaches
  the scheduler/UND-mode frontier; the next step is to supply the initial
  thread/scheduler object and bind the imports, then implement the banked
  exception model so the kernel's own mode switches are faithful.

- [ ] **WD2 unpacking** — the extracted 23.3 MB flash image is **not linear**:
  every `TRomImageHeader`+code blob is packed out of line (kernel header at file
  `0x3268c0`, code at `0x32692c`, while the link address is `0x50310000`), and
  the ROMFS directory/files are packed at their own offsets. The ROM header says
  `rom_size = 0x1600000`; file size is `0x1634f5c`. The 2.7 MB high-entropy
  region (`0x10000..0x2a0000`) is the likely packed core.
- [ ] **Mask ROM** — the UPP's internal boot ROM is not in the dump (the
  `0x00e0ca39` word at header `+0x84` is `iTime` high, not an entry).
  Round 11 found the secondary loader entry it calls: **`0x500003bc` →
  `0x50001648`**, driven by
  the **`KaeP`** descriptor at `0x50000124` (payload `0x130`).  Round 12 showed
  the bank must be **unpacked**, not just copied: it is a concatenation of
  fragments linked for different bases.  `bootbank.py build` +
  `NK_LOW_ROM_IMAGE` runs the loader for **600,000 instructions with no stale
  calls**, through the `0x1244` image-loader thread and into a real UPP write.
  Round 13 models the boot-region table (boot/ROM/RAM banks, `0x4000` on RAM):
  the super page becomes `0x802ff000`, and the compacted list at `0x802ff400`
  is populated.  Round 16 corrects the storage model: the bank is not a set of
  separate fragments, it is the packed stream slice `[0xb0, 0x100b0)`; all
  switch tables measure bias 0 (`bootbank.py --stream`).  The **correct**
  linked loader stops in a board/CPU detection panic at `0x624c`; the old
  600k raw-fragment run was following the B2 page header.  Round 17 unpacks the
  KaeP/PeaK container (`record 0x12e`, `image 0x14e`, length `0x1423dc`) and
  installs an executable `ldr pc` handoff at `0x80`; the loader now enters the
  kernel at `0x50310054`.  The mask ROM's codec for the 0x20-byte record is
  still the open piece.
- [ ] **MMIO + display** — the sparse bus is in place; the entry already writes
  UPP registers around `0x58150000`, which is the first real device surface.
- [ ] **First light** — the Nokia boot logo on a host window.
- [ ] Keypad + timers → navigable idle menu (Snake, the app list)
- [ ] Stub the radio → the phone boots to "no network" and just *runs*


> **Historical note (round 16).**  The round-5..15 entries below are kept as a
> lab log.  Their 197-instruction kernel entry, "missing Thumb `pop`", callmap,
> "packed text is not the linked text" and "truncated Programs directory"
> results were all produced by keeping the `0xec`-byte page headers inline.
> The corrected page-header-free stream is described in the round-16 bullet
> above and in [`docs/BOOT.md`](docs/BOOT.md); do not use the old acceptance
> numbers as the current frontier.

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

# interpreter self-test (ARM + Thumb decode, flags, push/pop, nk_call fallback)
tools/test_interp.sh

# EKA1 loader + DLL import-binding regression
tools/test_loader.sh

# round 16: remove the 0xec-byte page headers -> the packed text is the
# linked text (kernel exports 469/478, DLL2 1757/1788)
.venv/bin/python recompiler/pagestream.py analyze 6600_mcu.bin
.venv/bin/python recompiler/pagestream.py verify 6600_mcu.bin
.venv/bin/python recompiler/layout.py census 6600_mcu.bin
.venv/bin/python recompiler/bootbank.py verify 6600_mcu.bin --stream
tools/test_pagestream.sh

# boot the real kernel entry (ARM) with the kernel vector table installed
tools/build_rom_image.sh
NK_KERNEL_VECTORS=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=1000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
# ... 924,964 instructions, UPP programmed, stop at the stack/exception frontier

# native ARMv4T boot trace (interpreter, not Unicorn)
tools/build_boot_trace.sh

# assisted: load the EKA1 sections + referenced DLLs and repair call sites
NK_E32_SECTIONS=1 NK_CALL_INFER=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --e32 0x3268c0

# rebuild the flat runtime ROM and run it directly
tools/build_rom_image.sh
tools/test_romimage.sh
NK_KERNEL_VECTORS=1 ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin

# round 7/16/19: the full image map + the complete boot module table
.venv/bin/python recompiler/romimage.py scan 6600_mcu.bin
.venv/bin/python recompiler/romimage.py names 6600_mcu.bin
.venv/bin/python recompiler/romimage.py names 6600_mcu.bin --all
#   725 scanned images; 726 placed with --place-rodata (RTC PDD)
#   ekern.exe -> uid3 0x100058e8
#   Libs 586 (boot image table), Programs 55, Plugins 171

# round 19: EKA1 import/IAT map and the one export-table hole
.venv/bin/python recompiler/imports.py verify 6600_mcu.bin
.venv/bin/python recompiler/imports.py scan 6600_mcu.bin --image 0x100058e8
.venv/bin/python recompiler/imports.py map 6600_mcu.bin --json out/imports_map.json
tools/test_imports.sh

# the S60 app tree (63 app directories, including SnakeEx and MixPix)
.venv/bin/python recompiler/romimage.py tree 6600_mcu.bin
.venv/bin/python recompiler/romimage.py tree 6600_mcu.bin --verbose

# historical bring-up image (now an alias for the clean build; the old
# patches/callmap targeted the page-header bytes and are not applied)
tools/build_bringup_image.sh
tools/test_boot_recover.sh

# the same clean run by hand (recovery enabled; <=2 bounded events)
NK_KERNEL_VECTORS=1 NK_BUDGET=1000000 NK_RECOVER=1 NK_CALL_INFER=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime_bringup.bin

# call-target census: how far each BL is biased into its callee
.venv/bin/python recompiler/romimage.py calls 6600_mcu.bin

# round 6: literal-pool relayout and the experimental relaid image
.venv/bin/python recompiler/relayout.py analyze 6600_mcu.bin
.venv/bin/python recompiler/relayout.py image 6600_mcu.bin \
  out/6600_runtime.bin out/6600_runtime_relaid.bin
tools/test_relayout.sh

# round 9/11: is the stored text the linked text?  Audit the export tables.
.venv/bin/python recompiler/layout.py census 6600_mcu.bin --json out/layout_census.json
.venv/bin/python recompiler/layout.py pools 6600_mcu.bin
.venv/bin/python recompiler/layout.py drift 6600_mcu.bin --json out/layout_drift.json
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin
tools/test_layout.sh

# round 11: mask-ROM secondary loader entry (registers via NK_Rn)
NK_ENTRY=0x500003bc NK_R11=0x80000000 NK_R10=0 \
  NK_RECOVER=1 NK_CODE_ONLY=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin

# ... and the same loader in its real physical view: boot bank at address 0
NK_LOW_ROM=1 NK_ENTRY=0x3bc NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin

# round 12: measure the boot-bank fragments and boot the linked view
.venv/bin/python recompiler/bootbank.py analyze 6600_mcu.bin
.venv/bin/python recompiler/bootbank.py build 6600_mcu.bin \
  out/6600_bootbank_linked.bin
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
tools/test_bootbank.sh

# round 13: the mask-ROM boot-region (bank) table
.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin \
  out/6600_bootregions.bin
.venv/bin/python recompiler/bootregions.py explain out/6600_bootregions.bin
.venv/bin/python recompiler/bootregions.py verify 6600_mcu.bin
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_REGIONS=out/6600_bootregions.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
tools/test_bootregions.sh

# round 14: KaeP page grid + the linear boot-region profile
.venv/bin/python recompiler/kaep.py analyze 6600_mcu.bin
.venv/bin/python recompiler/kaep.py verify 6600_mcu.bin
.venv/bin/python recompiler/kaep.py despan 6600_mcu.bin out/6600_despanned.bin

.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin \
  out/6600_bootregions_linear.bin --profile linear
.venv/bin/python recompiler/bootregions.py verify 6600_mcu.bin --profile linear
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_REGIONS=out/6600_bootregions_linear.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
# ... now the old 0xc58 frontier is gone; stop is the page-table fill 0x2fe4

# round 17: unpack the KaeP/PeaK container and install the executable handoff
.venv/bin/python recompiler/kaep.py unpack 6600_mcu.bin \
  out/6600_kaep_record.bin out/6600_kaep_image.bin
.venv/bin/python recompiler/kaep.py install \
  out/6600_bootbank_linked.bin 6600_mcu.bin \
  out/6600_bootbank_kaep_install.bin
tools/test_kaep.sh

# round 18: the EKA1 executive (SWI) call gate
.venv/bin/python recompiler/executive.py verify 6600_mcu.bin
.venv/bin/python recompiler/executive.py list 6600_mcu.bin --used
.venv/bin/python recompiler/executive.py stubs 6600_mcu.bin --image 0x100039e5
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=20000 NK_MMIO_N=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
# ... 7,540 instructions, 0 undefined, stop at the unbound IAT slot 0x5037d0e8
# round 19: bridge that slot instead of faking it, and fix the ROMFS table
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
  NK_IMPORTMAP=config/imports-6600.txt NK_RECOVER=0 NK_CALL_INFER=0 \
  NK_BUDGET=200000 NK_MMIO_N=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
# ... 8,512 instructions, 0 unbound IAT, stop in the CObjectIx::At path
.venv/bin/python recompiler/imports.py verify 6600_mcu.bin
tools/test_imports.sh
# add NK_IAT_FAKE=1 for the 8,510-instruction control that reaches the same stop
# add NK_BANKED=1 for the banked r13/r14 + SPSR model and per-mode stacks
tools/test_executive.sh

# round 20/21: initial thread -> process -> CObjectIx -> array, driver rodata
# and the real RTC frontier (8,655 insns, KERN-NO-SESSION 22 on Econs.dll)
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=8000000 NK_B7E=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_b7e.sh

# round 22: the RTC extension is a nested E32Image; allocator ABI, HAL channel
# and the 27,470-instruction post-extension boot frontier
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=8000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x5031f3c0 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
# ... 27,470 instructions, 0 undefined/unbound/recoveries, stop panic PLAT 21
#     at 0x5031f3a8 (boot descriptor [0x80000b5c] == 0xff is missing)
tools/test_rtc.sh

# round 23: the 0x40000000 super page, RAM bank list, CBitMapAllocator ABI,
# page tables and WD2 CTSI DMA; 139,784 instructions, USER-EXEC 3 frontier
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-wd2-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x503994e8 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round23.sh

# round 24: EUser ABI panorama; real system time, 16 object containers and
# initial process creation; 126,238 instructions, cleanup-stack frontier
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r24-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=64 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x50312b34 NK_WATCH_HITS=1 NK_WATCH_LOG=12 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round24.sh

# round 25: real per-thread CTrapCleanup graph, descriptor Copy, FindByName,
# User::Alloc and TBufBase8; 125,864 instructions, DProcess close-vtable frontier
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r25-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x5039e328 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round25.sh

# round 26: EUser CObject/DProcess base ABI; process registration; 126,866 insns
#   real path stops in DProcess::Name with USER 7 (descriptor ABI)
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r26-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
  NK_CALLMAP=config/callmap-rtc-6600.txt \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round26.sh

# explicit Name stand-in (not recovered state): DProcess vtable +0x14 ->
# EUser CObject::Name; reaches DProcess::Loaded with 126,778 insns and pc=0
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r26-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
  NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_PATCH=0x503386a4:0x50384bf8,0x503384bc:0x50384bf8 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

# round 27: kernel EUser imports are a constant -3 relocation
.venv/bin/python recompiler/euser_reloc.py verify 6600_mcu.bin
.venv/bin/python recompiler/euser_reloc.py analyze 6600_mcu.bin
.venv/bin/python recompiler/euser_reloc.py build 6600_mcu.bin \
    config/imports-r27-6600.txt
.venv/bin/python recompiler/euser_reloc.py build 6600_mcu.bin \
    config/imports-r27-name-6600.txt --profile name

# full relocation: 236 slots (K=1361 local exception); linked image,
#   NK_CALL_INFER=0: 108,231 insns, USER-EXEC 3 after At(handle 0xffff8001)
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r27-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
  NK_CALLMAP=config/callmap-rtc-6600.txt \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
#   control: NK_CALL_INFER=1 snaps a valid EUser call and stops at 14,354 /
#   MATHX; optional NK_BOOTTABLE_RAM=0x80900000 does not change the 108k stop

# DProcess name probe: 47 slots, no NK_PATCH; 128,663 insns, UIDs correct
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r27-name-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=0 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 NK_HLE_HEAP=0x80700000 \
  NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x5032b5d4 NK_WATCH_HITS=1 NK_WATCH_LOG=0 NK_WATCH_MEM=r1:0x30 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round27.sh

# round 21: the header-less driver block (RTC PDD uid3 0x100000d8) at
# code+text_size; the default runtime image now includes it
.venv/bin/python recompiler/romimage.py build 6600_mcu.bin \
  out/6600_runtime_rodata.bin --place-rodata
#   2335 sections from 726 images (725 without --place-rodata)

# round 15: relocate fragment C, map the kernel sections and reach the handoff
.venv/bin/python recompiler/bootbank.py build 6600_mcu.bin \
  out/6600_bootbank_linked.bin
.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin \
  out/6600_bootregions_staging.bin --profile staging
.venv/bin/python recompiler/bootbringup.py build 6600_mcu.bin \
  out/6600_bootbank_bringup.bin \
  --regions out/6600_bootregions_staging.bin
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_bringup.bin \
  NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=1500000 NK_STOP_PC=0x80 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
# ... 36,732 instructions, UPP programmed, stop at the boot-image handoff 0x80
tools/test_bootbringup.sh
```

`6600_mcu.bin` is now the **23.3 MB raw EKA1 flash image** extracted from
`NHL105530.C1` (the original WD2 container lives in `fw/`).  The old 103 MB
`6600_mcu.bin` was not a 6600 ROM and has been replaced.

`build_kernel_smoke.sh` prints the MMIO write made by the lifted ARM helper
(`0x58000000 = 0x1234`), the same write from the interpreter
(`0x58000000 = 0x5678`), and `native 6600 kernel function returned`.
`build_boot_trace.sh` prints the instruction counts and the exact stop:

```
--- stop: undefined instruction (1) at 0x50314c16 ---
insns=12 (ARM 0 / Thumb 12) ...
bytes @0x50314c16: 2d e9 00 10 a0 e3 18 00 9f e5 ...
nearest 4-aligned word @0x50314c14 = 0xe92d0002  (Thumb PC is 2 bytes past it)
```

That is the interworking/linker frontier, not a CPU bug: a Thumb `BL` lands
ten bytes into the ARM helper at `0x50314c0c`.  Set `NK_TRACE=1` for the
instruction stream, `NK_CALL_INFER=1` to snap interworking call sites to the
nearest prologue, and `NK_E32_SECTIONS=1` to load the packed record and its
referenced DLLs.  The assisted trace reaches `0x5038337c` (364 instructions,
all imports bound, no undefined); `NK_SNAP_WINDOW` and `NK_CALL_POLICY=0..3` let
you compare call-repair strategies, and `romimage.py calls` shows why a single
radius is not enough: the kernel's 3854 direct `BL`s are biased by 4..0x308
bytes and a few are legitimate shared basic blocks.

This round fixed a **Thumb decoder bug that invalidated the previous boot
traces**: bit 10 of the `add/sub rd,rs,#imm3` group selects the immediate when
set, but the interpreter used the register form.  Every Thumb pointer/length
calculation therefore used the wrong operand, producing the bogus `0x800000`
descriptor pointer and the 8 MiB `memcpy` length — and the old "2,000,000
instructions into `euser.dll`" result.  With the selector fixed, the kernel
entry executes **197 instructions and returns cleanly** (page-header artifact; the
corrected ARM entry is in round 16) (4 skipped calls, no
undefined instruction) through the mask-ROM stand-in.  The next frontier is not
a longer trace but the packed image's **missing 4-byte alignment padding**: the
entry's literal pool is stored two bytes early at `0x5031008e` instead of
`0x50310090`, and its values become valid RAM pointers after adding the
`0x80000000` base.  `tools/test_boot_recover.sh` is the acceptance test; the
full analysis and the relayout plan are in [`docs/BOOT.md`](docs/BOOT.md) and
[`docs/PROGRESS.md`](docs/PROGRESS.md).

## Toolchain

- **Python 3 + Capstone** — the recompiler (`wd2.py`, `extract.py`, `lift.py`,
  `gen_register.py`, `pagestream.py`, `romimage.py`, `relayout.py`, `layout.py`,
  `executive.py`, `bootbank.py`, `bootregions.py`, `kaep.py`,
  `bootbringup.py`); `dct4decrypt.py` remains for the older 6100 DCT4 chunks.
- **IDA Pro 9.1 (headless)** — exact function boundaries on the EKA1 image
  (`extract_ida.py`).
- **clang** — compiles the generated C + runtime.
- **Unicorn** — legacy research only (`trace_boot.py`); the shipped runtime and
  the boot trace use the project's own ARMv4T interpreter, not Unicorn.
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

Offline reference sources and bundled format documentation are indexed in
[`docs/REFERENCES.md`](docs/REFERENCES.md), including pinned versions, local paths,
license cautions and the command to restore the ignored `references/` directory.
A locally supplied **Series 60 2.0 SDK for Symbian OS** (7.0s) under
`references/Series60_v20/` provides the matching headers, import libraries, SDK
docs and examples. It is proprietary, stays out of the repository and build, and is
used only for API/ABI comparison.

- [N64: Recompiled](https://github.com/N64Recomp/N64Recomp) — the static-recomp pattern this follows
- [ngagerecomp](https://github.com/sp00nznet/ngagerecomp) — sibling project; the ARMv4T lifter + runtime model
- [DCT4Crypt](https://github.com/g3gg0/DCT4Crypt) by g3gg0 + [retro-phone-tools](https://github.com/RobyRew/retro-phone-tools) — the DCT4 decryption algorithm
- Everyone still holding a phone that survived the 2000s. 📞
