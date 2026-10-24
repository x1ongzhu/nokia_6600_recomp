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
  runtime image (`out/6600_runtime.bin`) with the kernel, its two referenced
  DLLs, the packed ROMFS directory block and the 171 linearly-stored ROMFS
  files; `calls` classifies every direct ARM `BL` by how far its target is
  biased into the callee.  `build --patch FILE` applies bring-up text repairs
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
