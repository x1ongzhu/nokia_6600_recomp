# recompiler/ — offline tools

Everything here runs on the host, before the guest starts. Output goes to
`out/` (gitignored).

```
6600_mcu.bin
  │ wd2.py            container / EKA1 header / kernel / ROMFS
  ▼
packed stream
  │ pagestream.py     remove 852 × 0xec page headers
  ▼
linked sections
  │ romimage.py       assemble the flat runtime image
  │ layout.py         export-table / layout audit
  │ imports.py        IAT / stub map
  │ euser_reloc.py    kernel→EUser ordinal relocation
  ▼
out/6600_runtime.bin  +  config/imports-*.txt
```

| Module | Role | Acceptance |
|---|---|---|
| `wd2.py` | Decode the WD2 BT2 container, print the EKA1 ROM header, carve the kernel E32Image, list/extract ROMFS. | `wd2.py info/kernel/list` |
| `pagestream.py` | Rebuild the packed-record stream without the `0xec`-byte page headers; `verify` pins the 852-record grid and the kernel header/text offsets. | `tools/test_pagestream.sh` |
| `romimage.py` | Scan `TRomImageHeader` records, place every image/section at its runtime VA, place ROMFS directories and app binaries; `build` writes the 22 MiB flat image. | `tools/test_romimage.sh` |
| `layout.py` | Census the export directories against function starts; `verify` asserts the kernel ≥95%, `drift` rejects padding-only models. Uses `relayout.py` for the alignment audit. | `tools/test_layout.sh` |
| `relayout.py` | Diagnostic: recover the ROM linker's 4-byte literal-pool/function alignment. The page-header-free stream is already the linked layout, so this is no longer applied to the boot image. | `tools/test_layout.sh` |
| `imports.py` | Enumerate EKA1 `ldr ip,[pc]; ldr pc,[ip]` stubs, resolve each slot to `(uid3, ordinal, value)`, classify holes. | `tools/test_imports.sh` |
| `euser_reloc.py` | Recover the kernel→EUser import order: `K → edata[K-3]` for `K>=6`, low-ordinal specials, one local exception (`K=1361`). Emits `config/imports-r29-6600.txt`. | `tools/test_round29.sh` |
| `bootstate.py` | Static assertions for the mask-ROM boot hand-off: super-page `d0`, kernel header, TStack sequence, `TStack::Set`, time path, idle loop. | `tools/test_round29.sh` |
| `bootbank.py` | Reconstruct the linked view of the 64 KiB UPP boot bank from the stream (`--stream`); used by the stream test. | `tools/test_pagestream.sh` |
| `recursive.py` | Mixed ARM/Thumb function discovery from the carved kernel. | `tools/build_kernel_smoke.sh` |
| `lift.py` | Lift discovered functions to C (Capstone → C). | `tools/build_kernel_smoke.sh` |
| `gen_register.py` | Emit the register-name table used by the lifter. | `tools/build_kernel_smoke.sh` |

## Common commands

```sh
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin

.venv/bin/python recompiler/pagestream.py verify 6600_mcu.bin
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin
.venv/bin/python recompiler/imports.py verify 6600_mcu.bin
.venv/bin/python recompiler/euser_reloc.py verify 6600_mcu.bin --profile boot
.venv/bin/python recompiler/euser_reloc.py build 6600_mcu.bin \
    config/imports-r29-6600.txt --profile boot
.venv/bin/python recompiler/bootstate.py verify 6600_mcu.bin

.venv/bin/python recompiler/romimage.py build 6600_mcu.bin out/6600_runtime.bin
.venv/bin/python recompiler/romimage.py build 6600_mcu.bin \
    out/6600_runtime.bin --place-rodata
```

The lifter is exercised by `tools/build_kernel_smoke.sh`; it is not part of the
current boot path (the boot harness runs the interpreter).
