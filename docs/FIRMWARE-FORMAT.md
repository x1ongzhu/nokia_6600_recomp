# Nokia DCT4 / WD2 firmware format

The Nokia 6600 (type **NHL-10**) is a DCT4 phone built around the **UPP_WD2**
ASIC (104 MHz ARM920T).  Its firmware is distributed as a **WD2** container,
not as the older `DCT4` chunk container used by the 6100 and other DCT4
handsets.  Nothing about either format is encrypted with a secret key: the
flash image is a fixed, reversible transformation that the service tool and the
phone's boot ROM understand.

## What the download contains

For **NHL-10 v5.53.0** the package holds two files:

| file | size | role |
|---|---|---|
| `NHL105530.C1` | ~23.3 MB | MCU / ROM image (EKA1 Symbian 7.0s) |
| `NHL105530.22` | ~1.4 MiB | PPM (language resources) |

Both start with the ASCII tags `WD2 BT2` and `WD2 ALGORITHM`.  A service tool
shows this as `Type: Flash Image, Algo: WD2 BT2, WD2 ALGORITHM`; it is the
flashing/container format, not a password-protected archive.

There is **no `DCT4` chunk framing** in these files.  `recompiler/dct4decrypt.py`
will reject them; use `recompiler/wd2.py` instead.  An earlier working tree
contained a 103 MB `6600_mcu.bin` with neither the WD2 tags nor an EKA1 vector
table (and no E32Image UIDs); it was not a 6600 ROM.  It has been replaced by
the 23.3 MB raw flash image extracted from `NHL105530.C1`.  The canonical layout is
now:

| path | contents |
|---|---|
| `fw/NHL105530.C1` | original WD2 container (gitignored) |
| `6600_mcu.bin` | raw EKA1 flash image, 23.3 MB (0x1634f5c), linked at 0x50000000 |
| `fw/6600_kernel.bin` | E32Image kernel code at its link address |

## Container → ROM

`wd2.py extract` finds the EKA1 vector table

```
75 01 00 ea   b ...
78 01 00 ea
7b 01 00 ea
...
```

at container offset **0x10b** in v5.53.0 and slices from there.  The result is a
23,285,596-byte EKA1 flash image (0x1634f5c) with the following header:

| ROM offset | field | 6600 v5.53.0 |
|---|---|---|
| +0x7c | EKA1 ROM header start | — |
| +0x80 | checksum | `0x91f6bc80` |
| +0x84 | mask-ROM entry | `0x00e0ca39` (Thumb) |
| +0x88 | ROM link base | `0x50000000` |
| +0x8c | ROM size | `0x01600000` (22 MiB; the file is 23.3 MB because the flash is packed) |
| +0x90 | ROMFS root-list pointer | `0x50300000` (runtime VA; the packed file offset is `0x3162b0`) |
| +0x94 | kernel data base | `0x80000000` |
| +0x98 | kernel data limit | `0x80300000` |
| +0x9c | primary file entry | `0x50301ec4` |
| +0xa0 | secondary file entry | `0x50302148` |
| +0xa4 | second checksum | `0x8fc16051` |

The **mask-ROM entry** `0x00e0ca39` is in the UPP's internal boot ROM, which is
not part of the flash dump.  The ROM image itself is linked at
**0x50000000**; its first eight words are exception vectors, and the ROM file
system is appended after a **0x162b0-byte** header/kernel area.

## Kernel

`wd2.py kernel` scans for E32Image headers and selects the one with the EKA1
kernel UID **`0x100058e8`**:

```
hdr     0x3268c0      (guest 0x503268c0)
uid1    0x1000007a
uid2    0x1000008b
uid3    0x100058e8
entry   0x50310054    (Thumb)
code    0x50310000
data    0x50338ac0
code_size 0x29238
text_size 0x28ac0
data_size 0x500
bss_size  0x1c58
```

The code is stored at ROM offset **0x326924**, not at the link address; the
loader copies it to **0x50310000** and starts at **0x50310054**.  `wd2.py
kernel` carves `text_size` bytes (`0x28ac0`) into `fw/6600_kernel.bin`.
`runtime/test/boot_kernel.c --e32 0x3268c0` with `NK_E32_SECTIONS=1` uses the
packed-record layout below to place text, data, export directory and the
DLL-ref table at their runtime addresses, and recursively loads the referenced
DLLs.

The EKA1 `TRomImageHeader` is **0x64 bytes for every image, including the
kernel**.  (An earlier bring-up used `+0x6c`; that shifted the whole kernel by
8 bytes and made genuine ARM code decode as Thumb-2.)  A packed record is:

```
TRomImageHeader  0x64
.text            iTextSize          -> iCodeAddress
.rdata           constant data      (file offset not used at run time)
.data            iDataSize          -> iDataAddress (and RAM base)
.edata           iExportDirCount*4  -> iExportDir
TDllRefTable     if iDllRefTable != 0
```

The record ends immediately before the next `TRomImageHeader`, so sections are
located backwards from that boundary; the packed file offset is unrelated to
the runtime address.

The kernel's `TDllRefTable` (file `0x3513b8`, 0x18 bytes) references two DLLs:
UID3 **`0x100065a5`** (code `0x5037c614`) and UID3 **`0x100039e5`** (code
`0x5037d154`).  Loading those images' text and export directories is enough to
resolve the kernel's import stubs (`ldr ip,[pc]; ldr pc,[ip]; .word slot`):
the slot is an address inside the referenced DLL's `.edata`.  The runtime
loader does this today.

What is still missing is the **ROM build's interworking/alignment fixup**:
Thumb code calls ARM helpers with a plain `BL` and no `mov lr,pc; bx lr`
veneer, and some call targets are a few bytes into the callee.  The round-5
finding was that the packed text is missing **2-byte alignment padding** before
4-byte-aligned literal pools/functions.  Round 6 implements the inverse pass in
[`recompiler/relayout.py`](relayout.py): the kernel entry's pool moves from
`0x5031008e` to `0x50310090`, the entry `ldr` reads `0x00046564`, and all 787
detected pools are 4-byte aligned after the plan.  The early entry runs in the
pre-MMU physical view (pool values are physical offsets), while the rest of the
kernel uses `0x800xxxxx` virtual addresses.  The interpreter still repairs
individual call sites (`NK_CALL_INFER=1`, `NK_CALLMAP`); the open piece is the
complete function map (leaf entries) and relaying the DLLs.  See
`docs/BOOT.md`.

Two bring-up inputs are now kept under `config/`:

- `config/patches-6600.txt` — bytes missing from the packed text, applied by
  `romimage.py build --patch`.  The first one restores the Thumb `pop` at
  `0x5039adcc` that the following packed table overwrote.
- `config/callmap-6600.txt` — per-call-site callee overrides and a few
  host-side HLE helpers (`div`, `mod`, `memzero`, bump `alloc`, `memcpy`) for
  the compiler runtime.  Both are applied only by the bring-up scripts
  (`tools/build_bringup_image.sh`, `tools/test_boot_recover.sh`), not by the
  faithful `out/6600_runtime.bin` build.

Separately, the flash is **packed**: the 23.3 MB file is not the linear
`0x50000000` image.  Every `TRomImageHeader`+code is a packed record, the ROMFS
has its own packed offsets, and `0x10000..0x2a0000` is the high-entropy
(8.0 bit/byte) region.  `rom_size` in the header is `0x1600000` (22 MiB).

`recompiler/romimage.py build` reconstructs the flat runtime image from those
records:

```
0x50000000..0x50010000   boot code / vectors        (file 0..0x10000, linear)
0x50300000..0x50310000   ROMFS root list + dirs     (file 0x3162b0..0x3262b0)
0x50310000               kernel text                (file 0x326924)
0x50338ac0               kernel .data               (file 0x350740)
0x50338fc0               kernel .edata              (file 0x350c40)
0x50339738               kernel dll-ref table       (file 0x3513b8)
0x503397b4..0x5042f170   kernel-reachable DLLs
0x5043fc90..0x51600000   171 ROMFS files            (file = va - 0x50000000)
```

The output is `out/6600_runtime.bin` (exactly `0x1600000` bytes); 184 placed
sections do not overlap.  The 0x34f5c bytes at the end of the original file
are a trailer, not ROM content.

Two sections are still unplaced because no header describes them: the kernel's
`0x135c` bytes at file `0x34f3e4` (interrupt names + handler table) and the
DLL `0x100039e5`'s `0x19dc` bytes at file `0x3cd36c` (UTF-16/pointer tables).
No literal in the reachable text points at them; the working hypothesis is
that they are the pre-ROM-build debug/rodata copies.

## ROM file system

The ROMFS is plaintext and can be browsed without the kernel:

```
py recompiler/wd2.py list 6600_mcu.bin
  root list @ 0x503162b0, TRomDir @ 0x3162bc, 171 entries, data @ 0x317e40
  AcmClassController.dll       size=   0x32c addr=0x5043fc90 attr=0x01
  101FBF20.RSC                 size=    0x2d addr=0x50440020 attr=0x01
  Tfcorefilters.dll            size=  0x31e8 addr=0x505df3d0 attr=0x01
  ...
```

`TRomDir` is `iSize` + `{size, addr_lin, attr, name_len, UTF-16 name}`
records, 4-byte aligned.  The `addr_lin` values are **runtime** addresses:

- The root list's runtime VA is the stored ROM-header pointer **`0x50300000`**;
  its packed file offset is **`0x3162b0`**.  The `+0x162b0` number quoted by
  older notes is the file-offset difference, not a runtime bias.
- The packed directory block is the 64 KiB `[0x3162b0, 0x3262b0)`.  Its last
  `0x64` bytes coincide with the kernel's `TRomImageHeader`, so the directory
  data maps to `[0x50300000, 0x5030ff9c)` and the header sits at
  `0x5030ff9c`.  The `iAddress` field inside the root list (`0x5030fa78`)
  does **not** match the directory's packed position; the flat image copies
  the whole block rather than trusting it.
- The 171 **file** entries are different: `addr_lin` is exact and the file
  data is stored **linearly**, `file_offset = addr_lin - 0x50000000`.  They
  occupy `0x5043fc90..0x515ed6e0`, with no overlaps.  The old `+0x16538`
  entry bias is obsolete.

None of this is encryption: the ROMFS and the image records are plaintext; the
container header is a fixed, keyless WD2 wrapper.

## 6100 and the older DCT4 format

`dct4decrypt.py` remains the tool for the 6100/`npl2__05.800` family.  Those
files use a `DCT4` chunk container with a 0x84-byte plaintext header and a
16-bit CryptKey (`0x026f` on the 6100).  That path is independent of WD2 and
should not be mixed with the 6600 work.
