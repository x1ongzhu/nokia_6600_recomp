# recompiler/

Offline tools: Nokia WD2/DCT4 firmware → EKA1 ROM → C.

## Pipeline (Nokia 6600 / NHL-10, v5.53.0)

```
NHL105530.C1  (WD2 BT2 / WD2 ALGORITHM container)
        │ wd2.py extract
        ▼
6600_mcu.bin  (EKA1 ROM, 22 MiB, linked at 0x50000000)
        │ wd2.py kernel          (E32Image header uid3 0x100058e8)
        ▼
fw/6600_kernel.bin  (kernel code at its link address 0x50310000)
        │ extract.py            find Thumb functions
        ▼
functions.json               functions + image bytes
        │ lift.py               ARMv4T + Thumb → C
        ▼
generated.c ──(clang)──▶ native objects, linked against ../runtime/
```

- **`wd2.py`** — unpack a WD2 container (`NHL105530.C1`, `.22`) and inspect the
  embedded EKA1 ROM.  `extract` writes the ROM, `info` prints the ROM/E32Image
  headers, `kernel` carves the kernel image, `list` walks the ROMFS.  The 6600
  image is **not** a `DCT4` chunk container, so `dct4decrypt.py` does not apply.
- **`dct4decrypt.py`** — the older GSM DCT4 (`npl2__05.800`) keyless
  descrambler.  Kept for the 6100/other DCT4 targets; not used by the 6600.
- **`extract.py`** — quick Thumb function scanner (`push {..,lr}` → clean
  return) → `functions.json`.  Default base 0x50000000; use
  `--base 0x50310000` when scanning the carved kernel.
- **`extract_ida.py`** — exact boundaries from headless IDA Pro, then follows
  the BL/BLX call graph.  Launch at `-b0x50000000`.
- **`romimage.py`** — recover the runtime ROM layout from the packed records.
  `scan` lists every `TRomImageHeader`, its `.text`/`.data`/`.edata`/dll-ref
  sections and the header-less rodata block; `build` writes the flat 22 MiB
  runtime image (`out/6600_runtime.bin`) with all 722 packed images and the
  ROMFS directory block; `tree` recovers the S60 app tree by content
  (`\System\Apps` has 63/63 app directories, including `snakeex`/`mixpix`);
  `names` prints the boot-module table and now validates every `TRomDir`
  entry (ASCII name, address in the ROM window, sane size) and reports the
  truncated `\System\Programs` tail instead of inventing entries; `calls`
  classifies every direct ARM `BL` by how far its target is biased into the
  callee.  `build --patch FILE` applies bring-up text repairs
  (`<va> <hex bytes>` per line) and records them in the layout JSON;
  `../tools/build_rom_image.sh` / `../tools/build_bringup_image.sh` and
  `../tools/test_romimage.sh` wrap the raw and patched builds.
- **`relayout.py`** — reconstruct the ROM linker's 4-byte alignment padding.
  It decodes the packed text, finds literal pools from `ldr rd,[pc,#imm]`
  sites and function starts from `push`/`stmdb` prologues, then walks them in
  address order and inserts two bytes before any entity whose final address
  would be 2 mod 4.  `analyze` reports the shift function and the pool
  alignment, `build`/`verify` write and check a relaid kernel text, and
  `image` produces an experimental flat runtime image.  **Round 16:** on the
  page-header-free stream the text is already linked; the residual plan is
  only 26 inserts / `0x34` bytes (detector noise) and must not be applied.
  `tools/test_relayout.sh` treats it as a diagnostic.  The packed bytes are
  unchanged; only gaps are inserted.
- **`layout.py`** — audit the packed image layout with the export directory as
  ground truth.  `census` reports, per image, how many `iExportDir` entries
  are in the text/code, 4-byte aligned, Thumb-tagged and actually land on a
  function start (including a pool-aware walk-back for leaf functions after a
  literal pool), plus the same number for random addresses (the baseline) and
  the best constant shift.  `pools` reports literal-pool alignment and
  adjacent/duplicate pool starts for the kernel.  `drift` tests the strongest
  padding-only model — every export may match any stored start below it with a
  non-decreasing cumulative drift — against random addresses; the kernel stays
  at the null (1.04–1.09x), so padding/drift cannot recover the linked layout.
  `gaps` classifies the header-less block between `.text` and `.data`: most
  records hold strings/pointer tables there, but 15 carry a second
  Thumb/ARM code fragment (the kernel and the big boot DLL stay rodata).
  `verify` is the machine check used by `../tools/test_layout.sh`.  On the
  page-header-free stream the kernel is **469/478 (98.1%)** and the big DLL
  **1757/1788 (98.3%)** at shift 0, so the round-9..15 "packed text is not
  the linked text" figures are historical page-header artifacts.  `drift`
  remains a control that rejects the padding-only model.
- **`executive.py`** — decode the EKA1 kernel executive-call (SWI) table.
  EUser.dll implements the user-side kernel API as a dense table of single-
  instruction `svc #N` stubs; treating them as no-ops made the kernel fall
  through the whole table and loop with a `0x4b0`-byte stack leak per
  iteration (the old 924k "frontier").  The SVC handler at `0x50314f30` bounds
  the service table with the literal at `0x50314f7c` (`0x444` bytes = **273**
  entries); every non-zero target at `0x50314aec` is inside the kernel text,
  and four entries (`0x8a/0x94/0x95/0x96`) are unimplemented.  `verify` pins
  the handler/table, `list --used` shows which services EUser calls, and
  `stubs` maps every image's ARM/Thumb SVC instructions back to their service
  address.  The runtime's `NK_SWI_DIRECT` mode uses this map as an explicit
  bring-up call gate; `../tools/test_executive.sh` is the acceptance test.
- **`bootbank.py`** — reconstruct the linked view of the UPP boot bank (flash
  first 64 KiB).  The bank is a concatenation of code fragments linked for
  different bases, so its absolute pointers are not at the stored offsets.
  `analyze` reads the relocation addend from `0x3b0` (`sub r1, pc, #0x308; add r0, r0, r1` → `0xb0`)
  and measures the other fragments from the compiler's
  `ldrls pc,[pc,rN,lsl#2]` switch tables (A `0xb0`, B `0x19c`, C `0x374`);
  `build` writes the 64 KiB image with **A/B/C** moved to their linked
  addresses; `verify` pins the measurements and the C CPU/board table (linked
  `0x74b8` <- file `0x782c`, including CPU value `0x3b`).  The boot harness
  maps the result at 0 with `NK_LOW_ROM_IMAGE` and starts at linked `0x30c`.
  Round 16 adds `--stream`: the page-header-free boot bank is simply stream
  `[0xb0, 0x100b0)`, every switch table measures bias 0, and the **correct**
  linked loader stops in a board/CPU detection panic at `0x624c`.  The old raw
  A/B/C 600k run used the B2 page header as code and is a legacy regression
  (`../tools/test_bootbank.sh`).
- **`bootregions.py`** — derive and inspect the mask-ROM boot-region (bank)
  table the secondary loader receives in `r0/fp`.  Entries are 0x10 bytes
  (`base`, `size`, `attr`, `linbase`, with `count` at `+0` and entries from
  `+8`); `attr & 0x1f` is the bank type, `0x4000` marks the RAM bank whose top
  becomes the super page, and `0x04000000` is the linear-translation flag read
  by `0x1a1c` (its first pass also requires type 5..8).  The `legacy` profile
  emits boot/ROM/RAM with `attr=1`, which satisfies the super-page/list
  consumers but is invisible to `0x1a1c`/`0x1b34`.  The `linear` profile puts a
  type-2 RAM bank first (offset mapping, 6 MiB), then type-5 ROM and boot
  banks for linear translation; it is the round-14 control.  The `staging`
  profile is the round-15 bring-up table: type-2 RAM with the `0xffffffff`
  no-expand sentinel (`0x18b0`), a type-5 kernel code bank starting at the
  packed header (`base+size-section_size = 0x50310000`) and a type-5 kernel
  data bank at `0x50338ac0`.  `explain` decodes a file and `verify` pins all
  three profiles.  Install it with `NK_REGIONS=path[@addr]` and
  `NK_RAM_EXTRA=0x300000` for the 6 MiB bank
  (`../tools/test_bootregions.sh`, `../tools/test_kaep.sh`,
  `../tools/test_bootbringup.sh`).
- **`pagestream.py`** — remove the flash's `0x20ec`-byte page records.  Each
  record is a **`0xec`-byte header** (first six bytes `20 00 00 00 dc 23`)
  followed by a **`0x2000`-byte payload**.  The payloads are the packed image
  records; the headers are not.  `build` writes the page-header-free stream,
  `analyze` reports the grid and kernel record, `verify` pins the 852 headers
  and the kernel header/text/entry (`+0x64`, ARM `push`, vector table).
  Without this step the kernel's 478 exports only score 17.2% on function
  starts; with it they score **469/478 (98.1%)**, and `\System\Programs` has
  all **586** entries.  `../tools/test_pagestream.sh` is the acceptance test.
- **`kaep.py`** — unpack the KaeP/PeaK boot container (`0x124`: magic, record
  size `0x20`, image size `0x1423dc`) and measure the page grid.  `unpack`
  extracts the 0x20-byte record at `0x12e` and the 0x1423dc-byte image at
  `0x14e` byte-for-byte (with SHA-256); `install` writes an executable ARM
  `ldr pc` handoff at linked `0x80` plus the descriptor/list the loader
  consumes; `analyze` reports the 852 headers; `despan` writes the old
  (six-byte-only) experimental view; `synth` keeps the old synthetic
  descriptor stand-in; `verify` pins the container and the handoff
  (`../tools/test_kaep.sh`).  The mask ROM's codec for the 0x20-byte record
  is still unknown; `install` is an explicit handoff stand-in, not a decoded
  record.  **Note:** `despan` is superseded by `pagestream.py`; removing only
  the six tag bytes still leaves the other `0xe6` header bytes inline.
- **`bootbringup.py`** — the mask-ROM stand-in for the boot-image handoff.  It
  takes the linked boot bank, calls `kaep.install` to write the executable
  `ldr pc` handoff and descriptor at `0x80`, builds the
  `head -> node -> terminator` list at `0xfd00 -> 0xfd10` (node type
  `0x05040000`, `next = 0`), and emits the `staging` region table.  The real
  loader programs UPP, reaches linked `0x80`, executes the handoff and enters
  the kernel at `0x50310054`; the still-opaque 0x20-byte PeaK record is
  preserved, not decoded (`../tools/test_bootbringup.sh`).
- **`recursive.py`** — mode-aware recursive discovery (Thumb **and** ARM).  It
  follows `BL`, `ldr pc,[pc,#imm]` veneers, and the ARMv4T
  `mov lr,pc; bx lr` interworking stubs, then emits the same `functions.json`
  shape as `extract.py`.  Use it for the kernel:
  `--base 0x50310000 --entry 0x50310054 --thumb`.
- **`lift.py`** — ARMv4T/Thumb → C against `nk_cpu_t` (see `../runtime/include/`).
- **`gen_register.py`** — emit `nk_register()` for every lifted function.
- **`trace_boot.py`** — Unicorn-based research tracer.  `--kernel` loads the
  carved kernel at 0x50310000 and starts at the **ARM** entry 0x50310054
  (the page-header-free stream; the old Thumb assumption was a page header).
  It is a bring-up tool, not the runtime.

`../tools/build_kernel_smoke.sh` runs the whole kernel path and executes a real
lifted ARM helper against the sparse-memory runtime.
