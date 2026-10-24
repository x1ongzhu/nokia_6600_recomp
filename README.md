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
- [x] **Kernel located** — the EKA1 kernel E32Image (`uid3 0x100058e8`) is at ROM
  `0x3268c0`; its code is stored at `0x32692c` and links at `0x50310000`, with
  entry `0x50310054`. `wd2.py kernel` carves it to `fw/6600_kernel.bin`.
- [x] **Kernel entry runs** — the native interpreter loads the real EKA1 header
  (`0x3268c0`) and runs the entry `0x50310054`. Baseline stops after **12 Thumb
  instructions** at `0x50314c16`, the Thumb `BL` into the ARM IRQ-lock helper at
  `0x50314c0c`; the call target is ten bytes into the helper. That is the ROM
  linker/veneer frontier, not a CPU bug.
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
  tests. Round 5 added the Thumb format-2 fix described below. The interpreter
  also self-checks against the lifted `func_5031308c` (`stop=returned`,
  `r2=0x58000000`).
- [x] **EKA1 image loader / import binding** — `boot_kernel.c` reconstructs the
  packed record (text, rdata, data, export dir, DLL-ref table), follows the
  kernel's two DLL references (UID3 `0x100065a5`, `0x100039e5`), loads their text
  and export directories, and resolves the first import stub through `.edata`
  ordinal 34. With `NK_CALL_INFER=1` the assisted trace runs 364 instructions
  into the imported DLL; the corrected crash-recovery run completes the kernel
  entry in **197 instructions with 4 skipped calls** (see below).
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
- [x] **Literal-pool relayout (round 6)** — `recompiler/relayout.py` finds
  literal pools and function starts in the packed text and inserts the ROM
  linker's 2-byte alignment padding.  The entry's pool moves from
  `0x5031008e` to `0x50310090`, the `ldr` now reads `0x00046564`, and all 787
  detected pools are 4-byte aligned.  The experimental relaid image boots the
  kernel entry **289 instructions** (315 with the callmap) instead of 197 and
  reaches UPP MMIO (`0x58120a04`, `0x58120110`, `0x59e00040`).
  `tools/test_relayout.sh` is the acceptance test.  The early entry also runs
  in the pre-MMU physical view, so `boot_kernel` now maps a second 3 MiB RAM
  at `0x00000000` (`NK_NO_LOW_RAM=1` disables it).
- [x] **Full image map + ROMFS tree (round 7)** — packed image records are only
  **2-byte aligned**: the ROM build removed the linker's 4-byte padding, so a
  `TRomImageHeader` can start at 2 mod 4 (for example
  `\System\Libs\MmfAudioController.dll` at file `0x7271ca`).  Scanning every
  4th byte silently dropped 40+ images.  With a 2-byte scan plus a
  record-plausibility filter, **722 images** are recovered and their text
  ranges are disjoint, spanning `0x5030ff9c..0x515978dc`.
  `romimage.py build` now places **all** of them (1,580 sections, no overlaps)
  instead of only the kernel and its two direct DLL refs; the boot harness
  registers their text as code.  The ROMFS is a tree, and its directories are
  now located by content: root file `0x32639c`, `\System` `0x325aa4`,
  `\System\Libs` `0x3162bc` (171 entries) and `\System\Programs` `0x318170`
  (9 valid boot entries; the declared 0x5608-byte tail is overwritten by the
  next packed record — corrected in round 10).  This gives the boot module
  table — `ekern.exe` (the kernel, uid3 `0x100058e8`), `ecust.dll`,
  `ecomm.ldd`, `ramdrive.pdd`, `rtc.dll`, ... — via the new
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
  **197 instructions**.  The entry's third call (`0x50313522` →
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

**← current frontier →**

- [ ] **Packed text vs. export table** — the kernel's 478 export addresses are
  all 4-byte aligned and inside the text, but only 82 (17.2%) land on a
  function start in the stored text; a pool-aware detector that walks back
  through a literal pool to the preceding terminator raises this to **104
  (21.8%)**, and raises the random baseline in the same way (13.1% → 17.2%),
  so the ratio stays at **1.27x**.  The DLL `0x100039e5` is 14.4% against a
  5.9% baseline (2.44x).  Export entries are real fixed-up function addresses
  — a small Thumb DLL (`\System\Libs` 0x101f6e00) scores 5/5, with the Thumb
  bit set — so the failure is the stored layout, not the table.  The current
  relayout (44 pads, `0x58`) leaves only 58/478 kernel entries aligned; the
  best constant shift (`0xb0`, now `0x128` with the pool-aware detector) gives
  at most ~112/478; round 11's null test rejects the monotone-drift model.
  Since the stored text already keeps 1,420/1,430 ARM starts and 759/787 pools
  4-byte aligned, padding cannot explain the gap.  Round 11 adds
  `layout.py drift`, the strongest padding-only model: an export may match any
  stored start below it with a non-decreasing cumulative drift.  It reaches
  149/183/225 of 478 exports at drift budgets `0x60/0xc0/0x200`, while the
  same matcher on random addresses reaches 140/169/217 — a **1.04–1.09x**
  ratio, i.e. the null.  The packed text is therefore *not* the linked text at
  function granularity, and **no monotone padding/drift recovery can fix it**.
  Recovering the linked layout needs an explicit function-order/relocation
  table from the container/ROM build description (B6b) or a symbol-level
  permutation (B1g2b).  `recompiler/layout.py`
  (`census` / `pools` / `drift` / `verify`) and `tools/test_layout.sh` make
  this measurable and reproducible.
- [ ] **Packed ROMFS is truncated** — the packed `\System\Programs`
  `TRomDir` declares `0x5608` bytes but only **9 entries / 0x114 bytes** are
  present; the next packed image record overwrites the rest (`0x54f4` bytes).
  The old parser read those code bytes as entries and produced 236
  plausible-looking names (`EStart.exe`, `EFile.exe`, ...); those entries are
  **not in this dump**.  `\System\Libs` (171), `\System` (23), `\System\Apps`
  (63) and the root (2) are complete, and the first nine Programs entries
  (`ekern.exe`, `ecust.dll`, `ecomm.ldd`, ...) are the boot-critical set.
  `romimage.py` now validates names/addresses and reports the truncation
  instead of inventing entries; see `tools/test_romimage.sh`.  The **63
  `<App>.app` E32Image files** (plus 13 plugin/driver files) and **84 AIF/MBM
  companions** are placed by `build`; the `.r01`/`.wav` data in the packed
  data area is the remaining B3g work.
- [ ] **Boot continuation** — the kernel entry still returns to the mask-ROM
  stand-in.  The old claim that recovery + the full image map runs into
  `euser.dll` and loops at `0x50389330` was a faithful-image artifact (missing
  Thumb `pop`); the patched image completes the entry in 197 instructions.
  The entry performs real UPP register writes, but its second call needs a
  vtable-backed kernel object at `[0x80000000]` and two calls
  (`0x5030fbc6`, `0x5030807a`) still point below the code base.  The real
  post-entry path (mask ROM → kernel main → scheduler) is still unknown.

- [ ] **WD2 unpacking** — the extracted 23.3 MB flash image is **not linear**:
  every `TRomImageHeader`+code blob is packed out of line (kernel header at file
  `0x3268c0`, code at `0x32692c`, while the link address is `0x50310000`), and
  the ROMFS directory/files are packed at their own offsets. The ROM header says
  `rom_size = 0x1600000`; file size is `0x1634f5c`. The 2.7 MB high-entropy
  region (`0x10000..0x2a0000`) is the likely packed core.
- [ ] **Mask ROM** — the reset path at `0x00e00000` (entry `0x00e0ca39`) is in
  the UPP's internal boot ROM and is not in the flash dump.  Round 11 found the
  secondary loader entry it calls: **`0x500003bc` → `0x50001648`**, driven by
  the **`KaeP`** descriptor at `0x50000124` (payload `0x130`).  With the
  `NK_Rn` register overrides the loader executes 211 instructions before the
  stale call sites are recovered.  The loader's jump tables are **0-based**,
  so the boot bank has to run at address 0: `NK_LOW_ROM=1` copies it there and
  installs the high vectors, and the loader then runs **299,991** instructions
  to the `0x1248` high-vector/super-page frontier.  Modelling the
  **boot image/super-page table** (`base=0`, `count≈0x80000000`) that the mask
  ROM should have installed is the next boot step.
- [ ] **MMIO + display** — the sparse bus is in place; the entry already writes
  UPP registers around `0x58150000`, which is the first real device surface.
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

# interpreter self-test (ARM + Thumb decode, flags, push/pop, nk_call fallback)
tools/test_interp.sh

# EKA1 loader + DLL import-binding regression
tools/test_loader.sh

# native ARMv4T boot trace (interpreter, not Unicorn)
tools/build_boot_trace.sh

# assisted: load the EKA1 sections + referenced DLLs and repair call sites
NK_E32_SECTIONS=1 NK_CALL_INFER=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --e32 0x3268c0

# rebuild the flat runtime ROM and boot it directly
tools/build_rom_image.sh
tools/test_romimage.sh
NK_CALL_INFER=1 ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin

# round 7: the full image map + the boot module table
.venv/bin/python recompiler/romimage.py scan 6600_mcu.bin
.venv/bin/python recompiler/romimage.py names 6600_mcu.bin
.venv/bin/python recompiler/romimage.py names 6600_mcu.bin --all
#   722 images placed; ekern.exe -> uid3 0x100058e8, \System\Programs tables

# the S60 app tree (63 app directories, including SnakeEx and MixPix)
.venv/bin/python recompiler/romimage.py tree 6600_mcu.bin
.venv/bin/python recompiler/romimage.py tree 6600_mcu.bin --verbose

# bring-up image (missing Tail patched) + call-site map + crash recovery
tools/build_bringup_image.sh
tools/test_boot_recover.sh

# the same run by hand: the entry returns after ~200 instructions
NK_BUDGET=2000000 NK_RECOVER=1 NK_CALL_INFER=1 \
NK_SNAP_WINDOW_ARM=0x200 NK_SNAP_WINDOW_THUMB=0x400 \
NK_CALLMAP=config/callmap-6600.txt \
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
entry executes **197 instructions and returns cleanly** (4 skipped calls, no
undefined instruction) through the mask-ROM stand-in.  The next frontier is not
a longer trace but the packed image's **missing 4-byte alignment padding**: the
entry's literal pool is stored two bytes early at `0x5031008e` instead of
`0x50310090`, and its values become valid RAM pointers after adding the
`0x80000000` base.  `tools/test_boot_recover.sh` is the acceptance test; the
full analysis and the relayout plan are in [`docs/BOOT.md`](docs/BOOT.md) and
[`docs/PROGRESS.md`](docs/PROGRESS.md).

## Toolchain

- **Python 3 + Capstone** — the recompiler (`wd2.py`, `extract.py`, `lift.py`,
  `gen_register.py`, `romimage.py`, `relayout.py`, `layout.py`);
  `dct4decrypt.py` remains for the older 6100 DCT4 chunks.
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

- [N64: Recompiled](https://github.com/N64Recomp/N64Recomp) — the static-recomp pattern this follows
- [ngagerecomp](https://github.com/sp00nznet/ngagerecomp) — sibling project; the ARMv4T lifter + runtime model
- [DCT4Crypt](https://github.com/g3gg0/DCT4Crypt) by g3gg0 + [retro-phone-tools](https://github.com/RobyRew/retro-phone-tools) — the DCT4 decryption algorithm
- Everyone still holding a phone that survived the 2000s. 📞
