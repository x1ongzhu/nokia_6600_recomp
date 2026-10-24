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
  `image` produces the experimental flat runtime image used by
  `tools/test_relayout.sh`.  The packed bytes are unchanged; only gaps are
  inserted.  It currently handles the kernel text; moving the following
  images and the out-of-range call targets is still open.
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
  `verify` is the machine check used by `../tools/test_layout.sh`.  Small
  images are stored in their linked layout (the 5-export Thumb DLL is 5/5)
  but the kernel and the big DLLs are not: the pool-aware census reaches
  104/478 (21.8%) against a 17.2% baseline, and the drift null test rejects
  monotone relayout.
- **`bootbank.py`** — reconstruct the linked view of the UPP boot bank (flash
  first 64 KiB).  The bank is a concatenation of code fragments linked for
  different bases, so its absolute pointers are not at the stored offsets.
  `analyze` reads the relocation addend from `0x3b0` (`sub r1, pc, #0x308; add r0, r0, r1` → `0xb0`)
  and measures the other fragments from the compiler's
  `ldrls pc,[pc,rN,lsl#2]` switch tables (A `0xb0`, B `0x19c`, C `0x374`
  provisional); `build` writes the 64 KiB image with A/B moved to their linked
  addresses; `verify` pins the measurements.  The boot harness maps the result
  at 0 with `NK_LOW_ROM_IMAGE` and starts at linked `0x30c`
  (`../tools/test_bootbank.sh`).
- **`bootregions.py`** — derive and inspect the mask-ROM boot-region (bank)
  table the secondary loader receives in `r0/fp`.  Entries are 0x10 bytes
  (`base`, `size`, `attr`, `linbase`, with `count` at `+0` and entries from
  `+8`); `attr & 0x1f` is the bank type and `0x4000` marks the RAM bank whose
  top becomes the super page.  `build` emits boot/ROM/RAM from `TRomHeader`,
  `explain` decodes a file and `verify` pins the derived values.  Install it
  with `NK_REGIONS=path[@addr]` (`../tools/test_bootregions.sh`).
- **`recursive.py`** — mode-aware recursive discovery (Thumb **and** ARM).  It
  follows `BL`, `ldr pc,[pc,#imm]` veneers, and the ARMv4T
  `mov lr,pc; bx lr` interworking stubs, then emits the same `functions.json`
  shape as `extract.py`.  Use it for the kernel:
  `--base 0x50310000 --entry 0x50310054 --thumb`.
- **`lift.py`** — ARMv4T/Thumb → C against `nk_cpu_t` (see `../runtime/include/`).
- **`gen_register.py`** — emit `nk_register()` for every lifted function.
- **`trace_boot.py`** — Unicorn-based research tracer.  `--kernel` loads the
  carved kernel at 0x50310000 and starts at the Thumb entry 0x50310054.
  It is a bring-up tool, not the runtime.

`../tools/build_kernel_smoke.sh` runs the whole kernel path and executes a real
lifted ARM helper against the sparse-memory runtime.
