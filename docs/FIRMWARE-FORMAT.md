# Nokia DCT4 / WD2 firmware format

The Nokia 6600 (type **NHL-10**) is a DCT4 phone built around the **UPP_WD2**
ASIC (104 MHz ARM920T). Its firmware is a **WD2** container, not the older
`DCT4` chunk container used by the 6100. Nothing is encrypted with a secret
key: the flash image is a fixed, reversible transformation.

## What the download contains

| file | size | role |
|---|---|---|
| `NHL105530.C1` | ~23.3 MB | MCU / ROM image (EKA1, Symbian 7.0s) |
| `NHL105530.22` | ~1.4 MiB | PPM (language resources) |

Both start with the ASCII tags `WD2 BT2` / `WD2 ALGORITHM`. `wd2.py extract`
finds the EKA1 vector table at container offset **0x10b** in v5.53.0 and
slices a **23,285,596-byte** flash image (`0x1634f5c`).

Canonical local layout:

| path | contents |
|---|---|
| `fw/NHL105530.C1` | original WD2 container (gitignored) |
| `6600_mcu.bin` | raw EKA1 flash image, linked at `0x50000000` (gitignored) |
| `fw/6600_kernel.bin` | carved kernel code at its link address (gitignored) |

## TRomHeader

The 6600 header starts at **+0x7c** (0x7c-byte boot/jump area):

| ROM offset | field | v5.53.0 |
|---|---|---|
| +0x7c | `iRestartVector` | `0` |
| +0x80 | `iTime` (64-bit, µs since year 0) | `0x00e0ca39_91f6bc80` |
| +0x88 | `iRomBase` | `0x50000000` |
| +0x8c | `iRomSize` | `0x01600000` (22 MiB) |
| +0x90 | `iRomRootDirectoryList` | `0x50300000` |
| +0x94 | `iKernDataAddress` | `0x80000000` |
| +0x98 | `iKernelLimit` | `0x80300000` |
| +0x9c | `iPrimaryFile` | `0x50301ec4` → `\System\Libs\ekern.exe` |
| +0xa0 | `iSecondaryFile` | `0x50302148` → `\System\Libs\EFile.exe` |
| +0xa4 | `iCheckSum` | `0x8fc16051` |
| +0xc4 | `iTotalSvDataSize` | `0xc70a0` |
| +0xc8 | `iVariantFile` | `0x50301ee0` → `\System\Libs\ecust.dll` |
| +0xcc | `iExtensionFile` | `0x50301f3c` → `\System\Libs\rtc.dll` |

The primary/secondary/variant/extension fields are `TRomEntry` pointers, not
image headers; each entry's `+4` is a `TRomImageHeader`.

## Packed records and page headers

The flash from `0x20b0` is **852 records** of:

```
0xec-byte page header  ("20 00 00 00 dc 23" + 0xe6 bytes)
0x2000-byte payload
stride 0x20ec
```

The page header is **not** part of the packed image. `pagestream.py build`
removes all 852 headers and yields the `0x1605ed8`-byte packed stream. Every
image's `TRomImageHeader` is immediately followed by its `.text` at `+0x64`.

## Kernel E32Image

`wd2.py kernel` selects UID3 **`0x100058e8`**:

| field | value |
|---|---|
| header (file / guest) | `0x3268c0` / `0x503268c0` |
| uid1 / uid2 / uid3 | `0x1000007a` (EXE) / `0x1000008b` / `0x100058e8` |
| entry | `0x50310054` (**ARM**) |
| code / data | `0x50310000` / `0x50338ac0` |
| code_size / text_size | `0x29238` / `0x28ac0` |
| data_size / bss_size | `0x500` / `0x1c58` |

In the packed stream the header is at `0x31004c`; text starts at `0x3100b0`
(header + `0x64`). In the flat image it is copied to `0x50310000`. Raw flash
`0x326924` is a page header, not text.

`TRomImageHeader` is **0x64 bytes for every image**. A packed record is:

```
TRomImageHeader  0x64
.text            iTextSize          -> iCodeAddress
.rdata           constant data      (no runtime address of its own)
.data            iDataSize          -> iDataAddress
.edata           iExportDirCount*4  -> iExportDir
TDllRefTable     if iDllRefTable != 0
```

The packed file offset is not the runtime address; sections are placed by the
VAs in the header. The kernel's `TDllRefTable` references two DLLs: UID3
`0x100065a5` (code `0x5037c614`) and UID3 `0x100039e5` (code `0x5037d154`).

## Export directory

`iExportDir` is an **ordinal-indexed array of function addresses** (Thumb
entries have bit 0 set), not a name table. After the page headers are removed,
the kernel's 478 exports land on function starts **469 times (98.1%)** and the
EUser DLL's **1757/1788 (98.3%)** at shift 0. `layout.py verify` asserts the
kernel rate. This is the layout oracle used by `euser_reloc.py`.

## ROMFS

The 64 KiB directory block is placed at `0x50300000` and is readable in place.
Known directories:

| directory | entries |
|---|---|
| root | `\System`, `\Nokia` |
| `\System` | 23 |
| `\System\Libs` | 586 (boot image table; primary/secondary/variant/extension entries point here) |
| `\System\Programs` | 55 (server list) |
| `\System\Libs\Plugins` | 171 |
| `\System\Apps` | 63 app directories (recovered by content; includes `snakeex`, `mixpix`) |

`.app`/`.dll`/`.ldd` E32Image files are placed at their runtime addresses;
AIF/MBM companions are placed alongside them. `.r01`/`.wav` data files are not
yet reconstructed.

## Boot bank

The first 64 KiB of the flash is a **segmented, differently-linked** boot bank:
linked view `[0,0x8000)` is read from stream `[0xb0,0x80b0)` (segment A/B) plus
segment C at a `0x374` bias. `bootbank.py --stream` builds that view; all 15
switch tables then have bias 0. The real mask-ROM record codec is still not
decoded; the current boot harness enters the kernel with explicit hand-offs
(see [`BOOT.md`](BOOT.md)).

## Open format questions

- Mask-ROM **PeaK record codec** (`0x124`: magic `0x5065614B`, record size
  `0x20`, image size `0x1423dc`) is not decoded; the boot hand-off is a
  trampoline stand-in.
- ROMFS `.r01`/`.wav` data file ordering is not reconstructed.
