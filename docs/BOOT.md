# Boot notes — NHL-10 v5.53.0

This is the bring-up log for the 6600 EKA1 image.  It records what is known,
what is executed, and the exact frontier.

## Entry points

| entry | address | mode | in the flash image? |
|---|---|---|---|
| UPP mask ROM | `0x00e0ca39` | Thumb | **no** — internal boot ROM |
| EKA1 ROM reset vector | `0x50000000` | ARM | yes (the image's exception table) |
| Kernel E32Image | `0x50310054` | Thumb | yes, at ROM `0x326924` (link `0x50310000`) |

The ROM header's `entry` field is the **mask-ROM** entry.  The kernel is
separate: its EKA1 `TRomImageHeader` (`uid3 0x100058e8`) is at ROM `0x3268c0`,
its text is stored at ROM `0x326924`, and the loader copies it to
**`0x50310000`**.  The entry is the Thumb address **`0x50310054`**.

## What runs today

Two modes are available in the same native ARMv4T interpreter
(`runtime/src/nokia_interp.c`):

```sh
# baseline: exact stop at the first unlinked call
tools/build_boot_trace.sh

# assisted: reconstruct sections/DLLs and repair interworking call sites
NK_E32_SECTIONS=1 NK_CALL_INFER=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --e32 0x3268c0

# bring-up: patched flat image + call-site map + crash recovery
tools/build_bringup_image.sh
tools/test_boot_recover.sh
```

### Round 5 correction (2026-10-24)

The interpreter's Thumb **format-2** decoder had bit 10 inverted:
`00011 I Op Rn/imm3 Rs Rd` selects `imm3` when `I=1`, but the code used the
register form for `I=1` and the immediate for `I=0`.  Every Thumb
`adds rd,rs,#n` therefore executed as a register add, which is why the old
traces saw `0x800000` pointers and 8 MiB `memcpy` lengths.  The fix is in
`runtime/src/nokia_interp.c`, with a regression test in `interp_selftest.c`
("Thumb add/sub immediate and register forms").

Consequences:

- the old **2,000,000 / 20,000,000 instruction frontiers are invalid**; they
  were produced by the bug, not by the packed image;
- the kernel entry now executes **197 instructions** and returns through the
  mask-ROM stand-in (`0xdead0000`), with **4 skipped calls and no undefined
  instruction**;
- call repair is restricted to registered **code ranges**, so a stale target is
  no longer snapped into the ROMFS directory block.  A direct call outside every
  code range is skipped (return 0) under `NK_RECOVER=1`;
- the descriptor helper at `0x5039adb8` is now an explicit `NK_HLE_MEMCPY`
  (destination, source, length), which completes the allocation/copy pair.

The current honest frontier is therefore **"kernel entry completes; the two
calls below the code base are unresolved"**, not a 2M-instruction loop.

### Packed text is missing alignment padding (new evidence)

The entry's code ends at `0x5031008c`.  Its Thumb literal pool should start at
the 4-byte boundary `0x50310090`, but the packed text stores it at
`0x5031008e`:

```
0x5031008e  64 65 04 00   0x00046564
0x50310092  ca 6f 04 00   0x00046fca
0x50310096  03 0c 00 00   0x00000c03
0x5031009a  b0 b5 07 1c   next function (push {r4,r5,r7,lr})
```

Adding the RAM base gives valid pointers `0x80046564`, `0x80046fca` and
`0x80000c03`; the `ldr` at `0x50310070` instead reads `0x6fca0004` because the
pool is two bytes early.  The next function starts at `0x5031009a` (2 mod 4)
but should start at `0x5031009c` after the missing padding.

This is the strongest evidence yet that the packed text is the ROM image with
the linker's **alignment padding removed**, and that the address biases are
cumulative 2-byte insertions rather than per-callee veneers.  The next task is a
**function map + relayout**: enumerate function/pool starts, re-insert the
2-byte padding at 4-byte boundaries, rebuild the flat image, and then re-run the
call census.  Do not tune snap windows against the old 2M trace.

A quick prototype that used only `push`/`stmdb` prologues found ~860 kernel
functions and matched only ~17% of BL targets after relayout, so a prologue-only
map is **not** sufficient.  Function discovery needs recursive control-flow
following (and IDA/`extract_ida.py` as a second opinion), including leaf entries
and shared blocks, before the padding model can be validated.

### Round 6: the literal pools are relaid (2026-10-24)

The round-5 "missing 2-byte padding" is now implemented as a real pass.
`recompiler/relayout.py` decodes every function, collects the literal loads
(`ldr rd,[pc,#imm]`), finds the pool that follows each function's terminator,
and walks **pools + function starts** in packed order.  An entity whose final
address would be 2 mod 4 gets two zero bytes inserted before it.  This is the
inverse of the linker's padding pass, and it is validated on the two cases
that exposed the problem:

| function | packed pool | final pool | literal |
|---|---|---|---|
| kernel entry `0x50310054` | `0x5031008e` | **`0x50310090`** | `0x00046564` |
| Thumb helper `0x50312100` | `0x5031213e` | `0x50312140` | `0x0004654c` |

The entry's `ldr r0,[pc,#0x1c]` now reads the intended word instead of the
middle of a 32-bit literal.  The plan currently inserts **44 gaps (0x58
bytes)** into the kernel text; all 787 detected pools are 4-byte aligned
afterwards.

Two corrections to the round-5 picture:

- The first gap is *before the entry's `push` at `0x50310056`*, not before its
  literal pool.  Aligning the push shifts the whole text by two bytes and the
  entry pool lands on `0x50310090` by itself.  Later gaps accumulate from the
  pools/functions that need re-alignment.
- The raw scan finds both real pools and **8-byte address-pair tables** (for
  example `0x50311a20` and `0x50312070`).  The tables are data, not literal
  pools; treating each pair as a pool inflated the shift.  `relayout.py`
  filters them with an address-pair/terminator heuristic and only counts pools
  referenced from decoded functions.

An experimental flat image (`relayout.py image`) puts the relaid kernel text
at `0x50310000` and moves the kernel `.data` copy into the free gap before the
first ROMFS file (`0x50400000`), updating the header's `text_size`,
`code_size` and `data` fields.  The DLLs stay at their stored addresses.  On
this image the boot trace runs **289 instructions** (315 with the callmap)
instead of 197, reaches UPP MMIO (`0x58120a04`, `0x58120110`, `0x58120308`,
`0x59e00040`), and still returns through the mask-ROM stand-in with no
undefined instruction.

The early entry also revealed the **pre-MMU physical view**: its literal pool
contains physical data offsets (`0x00046564`, `0x00046fca`), while the rest of
the kernel uses virtual `0x800xxxxx` pointers.  `boot_kernel` now maps a second
3 MiB RAM at `0x00000000` (disable with `NK_NO_LOW_RAM=1`); before that, the
entry's early stores went to the MMIO log instead of memory.

What is still open on this axis: the shift at the first callee
(`packed 0x5031261c`) is `0x14`, while the encoded call target `0x50312634`
would need `0x18`.  The remaining four bytes are most likely leaf functions
that have no `push`/`stmdb` prologue and are therefore not yet entities.  The
encoded targets are also known to be stale per call site (round 4), so the
callmap/snap path is still needed.  The next task is a complete function map
(leaf entries + export-derived starts), followed by rebuilding the flat image
with the DLLs relaid as well.

```sh
.venv/bin/python recompiler/relayout.py analyze 6600_mcu.bin
.venv/bin/python recompiler/relayout.py build 6600_mcu.bin out/6600_kernel_relaid.bin
.venv/bin/python recompiler/relayout.py verify 6600_mcu.bin out/6600_kernel_relaid.bin
.venv/bin/python recompiler/relayout.py image 6600_mcu.bin out/6600_runtime.bin out/6600_runtime_relaid.bin
tools/test_relayout.sh
```

### Historical results (rounds 3-4, before the Thumb fix)

Baseline (unchanged by the fix):

```
insns=12 (ARM 0 / Thumb 12)
--- stop: undefined instruction (1) at 0x50314c16 ---
bytes @0x50314c16: 2d e9 00 10 a0 e3 18 00 9f e5 ...
nearest 4-aligned word @0x50314c14 = 0xe92d0002  (Thumb PC is 2 bytes past it)
```

The entry runs `nop; push {r4,r7,lr}`, calls an ARM helper at `0x5031261c`, and
then reaches the Thumb BL at `0x50312186` whose target is the ARM IRQ-lock
helper at **`0x50314c0c`**.  The encoded target is `0x50314c16`, ten bytes into
it: the ROM linker would have inserted a Thumb→ARM veneer here.  This is a
linker frontier, not a CPU bug.

Assisted result (with the runtime loader and call repair):

- the loader places kernel text/data/exports/dllref at their runtime addresses;
- it follows the kernel's `TDllRefTable` and loads the two referenced DLLs
  (UID3 `0x100065a5` and `0x100039e5`) plus their export directories;
- the first import stub (`0x50337c00`) resolves through an `.edata` entry and
  enters the imported DLL;
- **364 instructions** later the trail stops at `0x5038337c` with `lr=0`.  The
  old "truncated Thumb tail at `0x5039ad9e`" explanation was partly a Thumb-bug
  artifact; the missing-tail patch is still useful but does not explain 364 by
  itself.

The packed image's BL targets are stale **per call site**, not per callee:
`0x50310060` calls the print routine at `0x50313518` with a `+0xa` target,
while `0x503103bc` calls the same routine with `+0x78`; `0x5039390c` encodes
`0x5039f980` as `0x5039f9f4` (`+0x74`).  A target can also land on a *valid*
shared entry of an unrelated neighbour (for example `0x50389d14`, the `>=32`
entry of a 64-bit shift helper, is a plausible leaf start but `0x503965fc`
wanted the 32-bit divider).  The round-4 callmap entries for those sites remain
in `config/callmap-6600.txt`, but the census must be repeated after relayout.

The bring-up stack now has five layers:

| layer | knob | purpose |
|---|---|---|
| bounded snap | `NK_CALL_INFER=1`, `NK_SNAP_WINDOW_ARM/THUMB` | snap a stale target to the nearest prologue; keep the window small enough that legitimate shared blocks stay exact |
| code-range guard | `nk_code_range_add`, loaded image text ranges | never accept a candidate outside kernel/DLL text; skip out-of-range direct calls under recovery |
| call-site map | `NK_CALLMAP=config/callmap-6600.txt` | pin one call site to its real callee, or to a host-side HLE helper (`div`, `mod`, `memzero`, bump `alloc`, `memcpy`) |
| missing-byte patches | `romimage.py build --patch config/patches-6600.txt` | restore bytes the packed image does not contain (the first one is the `pop {r4,r7,pc}` at `0x5039adcc` that the following packed table overwrote) |
| crash recovery | `NK_RECOVER=1` | snapshot the caller at every BL/BLX; if the callee faults, roll back, log the skipped call, return 0, and keep going |

Measured with `tools/test_boot_recover.sh` **after the Thumb fix**:

| mode | instructions | skips | stop |
|---|---|---|---|
| baseline `tools/build_boot_trace.sh` | 12 | — | `0x50314c16` (Thumb BL into ARM, no veneer) |
| assisted `NK_CALL_INFER=1` | 364 | — | `0x5038337c`, `lr=0`, no undefined |
| recovery + patch + callmap | **197** | **4** | entry returns to `0xdead0000` |

(`recoveries` in the stats line counts both a real stack rollback and an
out-of-code call skipped by the code-range guard.)

The entry skips two calls below the code base (`0x5030fbc6`, `0x5030807a`) and
two callees that fault on the current (pre-relayout) image.  Those are the next
concrete threads, together with the literal-pool padding evidence above.

### Interworking call census (this round)

`recompiler/romimage.py calls` classifies every direct ARM `BL` in the
reachable images.  A target is "exact" when it is a strong prologue
(`push {..,lr}` / `stmdb sp!` / `sub sp`) preceded by a function terminator;
"biased" when the nearest such prologue is a few bytes or a few hundred bytes
earlier.

| image | BL sites | exact | biased | no nearby entry |
|---|---|---|---|---|
| kernel `0x100058e8` | 3854 | 478 | 3222 | 154 |
| DLL `0x100039e5` | 3886 | 705 | 2908 | 273 |

The bias is **not a constant**: the most common values are `0x308` (176
sites), `0x34` (117), `0x28` (86), `0x40` (82), then `0x10`, `0x14`, `0x18`,
`0x24`.  A single call can be more than one function's length away from its
prologue.  Example: the Thumb caller at `0x5039adb8` encodes `0x5038231e`;
the nearest real entry is `0x503820b8` (`push {r4-r10,lr}`, preceded by
`bx lr`) — a **0x266** bias.

Two facts make this harder than a simple "snap back by N bytes":

1. Some targets are **legitimate shared basic blocks**, not function
   entries.  `0x503364b0` (called by `bl 0x503364b0` from `0x50312c50`) starts
   with `mov r0,r7` and uses the caller's `r7`; the word before it is a
   `bl`, not a terminator.  Snapping it to the nearest prologue
   (`0x503361d4`) executes the wrong function and derails at 31
   instructions.
2. Some targets are **2 mod 4** even though the callee is ARM
   (`0x50312c6a`, `0x50313522`, `0x503138fe`).  The Thumb decoder sees a
   valid `b`, so mode inference alone cannot reject it; the target has to be
   rounded to a 4-byte ARM boundary or snapped to a prologue.

The runtime now exposes two bring-up knobs:

```
NK_SNAP_WINDOW=0x40        # how far back a call fixup may search (default)
NK_CALL_POLICY=0|1|2|3     # 0 back (default), 1 ARM-at-target,
                           # 2 forward, 3 back -> forward -> ARM-at-target
```

Measured on the assisted trace (budget 200k): window `0x40`, `0x100` and
`0x200` all stop at the same `0x50383364` frontier (364 instructions);
window `0x400` regresses to 31 because it snaps the shared basic block
above.  Making the window Thumb-only (`NK_SNAP_WINDOW_THUMB=0x400`, ARM
window `0x40`) reaches 380 instructions and then hits an undefined Thumb
instruction at `0x5039ba4e`.  The reason is visible in the trace: the Thumb
function at `0x5039ad9e` has **no `pop`** before the packed data at
`0x5039adcc`; its tail is missing from the image.  Snapping call targets
cannot repair a truncated function, so this is recorded as evidence for a
real function/veneer map, not as a fix.

## Flat runtime image (`romimage.py build`)

The packed records can now be assembled into the flat ROM the phone actually
runs.  `recompiler/romimage.py build` places:

- the first 64 KiB of boot code at `0x50000000`;
- the kernel and the two DLLs it references at `code`, `data`, `edata` and
  `dllref` from their headers;
- the packed ROMFS directory block at `0x50300000` (the 64 KiB region below
  the kernel; the last `0x64` bytes are reserved for the kernel's own header,
  so `0xff9c` bytes are copied), which contains the root list and its 171
  entries;
- all 171 ROMFS files at their runtime addresses — they are stored linearly
  (`file = va - 0x50000000`) and do not overlap.

The output is `out/6600_runtime.bin` (exactly `0x1600000` bytes) plus a
layout JSON.  `runtime/test/boot_kernel.c --rom-image` maps it directly and
reaches the same 364-instruction frontier as the packed-record loader, with
all imports bound.

Two open questions came out of the assembly:

- **The header-less block between `.text` and `.data`.**  The kernel carries
  `0x135c` bytes at file `0x34f3e4` (interrupt names plus a table of handler
  addresses); DLL `0x100039e5` carries `0x19dc` bytes at file `0x3cd36c`
  (UTF-16 tables and pointer tables).  The `TRomImageHeader` does not
  describe either block, the runtime addresses of `.data`/`.edata` leave no
  room for them, and no literal in the reachable text points into them.  The
  working hypothesis is that they are the pre-ROM-build debug/rodata
  sections; they are recorded in the layout JSON but not placed in the flat
  image.  This is the one remaining layout question.
- **The ROMFS directory's stored address.**  The root-list entry says the
  directory is at `0x5030fa78`; its packed bytes are at file `0x3162bc`.
  The flat image therefore copies the packed directory block (`0xff9c`
  bytes, stopping at the kernel header) to `0x50300000` instead of trusting
  the stored address.  The file entries themselves are exact.

## Bugs fixed this round

Three real interpreter bugs had been masking the image analysis:

1. **Thumb format-2 operand selector** — bit 10 of `00011` selects `imm3`
   when set, but the interpreter used the register form.  Every Thumb
   `adds rd,rs,#n` silently became a register add; this produced the bogus
   `0x800000` descriptor pointer and the 8 MiB `memcpy` length.  Fixed and
   covered by the "Thumb add/sub immediate and register forms" regression.
2. **Thumb BL return address** was `pc+2`; a 4-byte Thumb `BL` returns to
   `pc+4`.  The callee returned into the second half of its own `BL`, which is
   why traces fell into literal pools.
3. **ARM PC-relative loads** used `c->r[15]` after it had been advanced to
   `pc+4`.  `ldr r0,[pc,#imm]` must read `pc+8 + imm`; without this, a kernel
   helper loaded the instruction word as its literal.

The first two have regression tests in `runtime/test/interp_selftest.c`
(`Thumb BL returns to pc+4`, `Thumb add/sub immediate and register forms`);
the ARM PC-relative load test is `ARM PC-relative ldr reads instruction+8`.

The earlier `0x6c` kernel header size was also wrong: every EKA1
`TRomImageHeader` serialized in this ROM is **0x64** bytes.  The two words at
`+0x64` are the first 8 bytes of text.  Using `+0x6c` shifted all kernel code
by 8 bytes and turned genuine ARM helpers into apparent Thumb-2.

## EKA1 header and record layout (confirmed)

| structure | size / layout |
|---|---|
| `TRomHeader` | `iJump[124]` + `iVersion` at `0x7c`; `rom_base` `0x88`, `rom_size` `0x8c`, root list `0x90`, kern data `0x94`, kern limit `0x98`, primary `0x9c`, secondary `0xa0`, checksum `0xa4` |
| `TRomImageHeader` (EKA1) | **0x64** bytes: entry `+0x10`, code `+0x14`, data `+0x18`, code size `+0x1c`, text `+0x20`, data size `+0x24`, bss `+0x28`, dll-ref `+0x38`, export count `+0x3c`, export dir `+0x40` |
| packed record | `header`, `.text` (`iTextSize`), `.rdata`, `.data` (`iDataSize`), `.edata` (`iExportDirCount*4`), `TDllRefTable` |
| `TDllRefTable` | `{u16 flags; u16 count; u32 entry[count][2]; u32 0xffffffff}` |

Sections are located **backwards from the next `TRomImageHeader`**, because the
packed file offset is unrelated to the runtime address.

### Kernel sections (recovered)

| section | file offset | size | runtime address |
|---|---|---|---|
| header | `0x3268c0` | `0x64` | — |
| text | `0x326924` | `0x28ac0` | `0x50310000` |
| rdata | `0x34f3e4` | `0x135c` | not relocated |
| data | `0x350740` | `0x500` | `0x50338ac0` (also RAM `0x80000000`) |
| export dir | `0x350c40` | `0x778` (478 entries) | `0x50338fc0` |
| DLL-ref table | `0x3513b8` | `0x18` | `0x50339738` |
| bss | — | `0x1c58` | RAM `0x80000500` |

`TRomImageHeader` fields and the section order are validated against the
Symbian `e32rom.h` / `romimage.rtf` documentation; the target image remains the
authority.

## Import binding

The kernel's DLL-ref table references two DLLs by code address.  Their headers
are found in the same packed ROM by scanning for the matching `iCodeAddress`:

| DLL UID3 | code address | header file offset | export dir |
|---|---|---|---|
| `0x100065a5` | `0x5037c614` | `0x396188` | `0x5037d098` |
| `0x100039e5` | `0x5037d154` | `0x396cc8` | `0x503b3794` |

A kernel import stub is `ldr ip,[pc]; ldr pc,[ip]; .word slot`.  The `slot`
value is an address inside one of those `.edata` arrays (for example
`0x503b381c` is ordinal 34 of `0x100039e5`).  Loading the DLL's text and export
directory makes the stub resolve without patching: the word at the slot is the
exported function address.

What remains is the **veneer bias**: exported/called functions are a few bytes
into their real prologue (`0x5039f700` vs. the prologue at `0x5039f6e8`).
`NK_CALL_INFER=1` snaps to the nearest prologue with a `push`/`stmdb sp!`/`sub
sp` prefix, and switches ARM/Thumb mode at the call.  It works for the first
few calls but is not a substitute for the real linker.

## The packed flash

The 23.3 MB `6600_mcu.bin` is not the linear `0x50000000` image:

- every `TRomImageHeader` + code + tables is a packed record;
- the ROMFS directory and files have their own packed offsets;
- `rom_size` is `0x1600000` while the file is `0x1634f5c`;
- `0x10000..0x2a0000` is an 8.0 bit/byte high-entropy region (likely packed
  data), but the ROM images themselves are plaintext records.

## Next tasks

1. **Complete the relayout (P0)** — round 6 implements the padding pass
   (`recompiler/relayout.py`) and validates the entry pool and the
   `0x50312100` helper.  What remains is the **complete function map**: leaf
   functions without a `push`/`stmdb` prologue are not yet alignment entities,
   which is why the shift at the first callee is `0x14` instead of the `0x18`
   its encoded target expects.  Add export-derived and cross-referenced leaf
   starts, then rebuild the flat image with the DLLs relaid too.  Re-run
   `romimage.py calls` and the boot trace; the old 2M/20M traces and the
   round-4 census remain invalid.
2. **Resolve the entry's two out-of-range calls** — `0x5030fbc6` and
   `0x5030807a` are below the kernel code base.  They are either linker veneer
   slots or code that the packed record does not contain; recovering them is
   part of the relayout/veneer work, not a snap-window problem.
3. **The header-less rodata blocks** — decide whether they belong to `.text`,
   to a RAM copy, or are debug data.  The kernel's block contains an
   interrupt-name/handler table but is not referenced by any literal in the
   reachable text.  The entry's truncated string at the text boundary suggests
   the block may be a continuation of the same rodata, so re-check this after
   relayout.
4. **Boot continuation** — the kernel entry now returns to the mask-ROM
   stand-in.  Find the real post-entry path (the mask ROM / boot loader's next
   call) so the trace can continue into the scheduler instead of stopping at
   the sentinel.
5. **Mask ROM stand-in** — CP15/MMU flat mapping, high vectors, SVC/IRQ state.
6. **MMIO/display** — the entry already writes UPP registers around
   `0x58150000` / `0x58150500`; the next useful milestone is a real UPP
   display/timer/keypad register table rather than logging every access.

The phased plan, task board and acceptance criteria are in
[`PROGRESS.md`](PROGRESS.md).
