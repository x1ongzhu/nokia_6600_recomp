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
| `NHL105530.C1` | ~22.2 MiB | MCU / ROM image (EKA1 Symbian 7.0s) |
| `NHL105530.22` | ~1.4 MiB | PPM (language resources) |

Both start with the ASCII tags `WD2 BT2` and `WD2 ALGORITHM`.  A service tool
shows this as `Type: Flash Image, Algo: WD2 BT2, WD2 ALGORITHM`; it is the
flashing/container format, not a password-protected archive.

There is **no `DCT4` chunk framing** in these files.  `recompiler/dct4decrypt.py`
will reject them; use `recompiler/wd2.py` instead.  An earlier working tree
contained a 103 MB `6600_mcu.bin` with neither the WD2 tags nor an EKA1 vector
table (and no E32Image UIDs); it was not a 6600 ROM.  It has been replaced by
the 22 MB raw EKA1 ROM extracted from `NHL105530.C1`.  The canonical layout is
now:

| path | contents |
|---|---|
| `fw/NHL105530.C1` | original WD2 container (gitignored) |
| `6600_mcu.bin` | raw EKA1 ROM, 22 MiB, linked at 0x50000000 |
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
22,285,596-byte EKA1 ROM image (0x1634f5c) with the following header:

| ROM offset | field | 6600 v5.53.0 |
|---|---|---|
| +0x7c | EKA1 ROM header start | — |
| +0x80 | checksum | `0x91f6bc80` |
| +0x84 | mask-ROM entry | `0x00e0ca39` (Thumb) |
| +0x88 | ROM link base | `0x50000000` |
| +0x8c | ROM size | `0x01600000` (22 MiB) |
| +0x90 | ROMFS root-list pointer | `0x50300000` (+0x162b0 bias) |
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

The code is stored at ROM offset **0x32692c**, not at the link address; the
loader copies it to **0x50310000** and starts at **0x50310054**.  The six
`bl` instructions at the entry are the first thing a native loader has to run.
`--kernel` mode in `recompiler/trace_boot.py` does exactly that.

The kernel's code is a mixture of Thumb and ARM.  Parts of the image contain
packed/compressed data (the region around `0x310000` is high-entropy), so a
simple `memcpy` of the E32Image is not the whole story: the EKA1 loader's
relocation/compression step is the current bring-up frontier.

## ROM file system

The ROMFS is plaintext and can be browsed without the kernel:

```
py recompiler/wd2.py list 6600_mcu.bin
  AcmClassController.dll   size=0x1b80 addr=0x5043fc90
  101FBF20.RSC             size=0x2d   addr=0x50440020
  HttpTransportHandler.dll size=0x1f30 addr=0x505e2700
  ...
```

The list pointer in the ROM header needs a **+0x162b0** bias on the 6600; file
addresses inside directory entries need a **+0x16538** bias.  Both biases are
properties of the 6600's ROM layout (the ROM header area plus the kernel image
precede the ROMFS), not encryption keys.

## 6100 and the older DCT4 format

`dct4decrypt.py` remains the tool for the 6100/`npl2__05.800` family.  Those
files use a `DCT4` chunk container with a 0x84-byte plaintext header and a
16-bit CryptKey (`0x026f` on the 6100).  That path is independent of WD2 and
should not be mixed with the 6600 work.
