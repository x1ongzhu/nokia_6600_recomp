# Boot notes — NHL-10 v5.53.0

This is the bring-up log for the 6600 EKA1 image. It records what is known,
what is executed, and the exact frontier.

## Entry points

| entry | address | mode | in the flash image? |
|---|---|---|---|
| UPP mask ROM | `0x00e0ca39` | Thumb | **no** — internal boot ROM |
| EKA1 ROM reset vector | `0x50000000` | ARM | yes (the image's exception table) |
| Kernel E32Image | `0x50310054` | Thumb | yes, at ROM `0x32692c`, link `0x50310000` |

The ROM header's `entry` field is the **mask-ROM** entry.  The kernel is
separate: its E32Image header (`uid3 0x100058e8`) is at ROM `0x3268c0`, its code
is stored at ROM `0x32692c`, and the loader copies it to **`0x50310000`**.  The
entry is the Thumb address **`0x50310054`**.

The kernel image ends at `0x32692c + 0x29238 = 0x34fb64`.  The ROM file system
starts after the ROM header/kernel area; directory-entry addresses carry a
`+0x16538` bias and the root list is at `0x503162b0`.

## What runs today

`recompiler/trace_boot.py --kernel` maps the ROM at `0x50000000`, copies the
carved kernel to `0x50310000`, maps RAM at `0x80000000` and high vectors at
`0xffff0000`, then starts at `0x50310054` in Thumb mode:

```sh
.venv/bin/python recompiler/trace_boot.py 6600_mcu.bin --kernel fw/6600_kernel.bin
```

`6600_mcu.bin` is the raw 22 MiB EKA1 ROM extracted from `fw/NHL105530.C1`;
`fw/6600_kernel.bin` is emitted by `wd2.py kernel`.

Result: **423 unique Thumb instructions**, including

- stack and register setup,
- the `bl` chain at the entry,
- a long loop of stores around `0x503122e4`–`0x503123f0`,
- a call through the ARM interworking code at `0x5031140c`.

It then stops on `UC_ERR_INSN_INVALID` because the CPU is still in Thumb mode
at `0x5031140c`, which is ARM code.  The bytes are correct; the mode is not.

## The interworking frontier

ARMv4T has no immediate `BLX`.  The kernel uses the classic veneer

```
mov lr, pc        ; Thumb: fe 46, ARM: 0f e0 a0 e1
bx  lr            ; Thumb: 70 47, ARM: 1e ff 2f e1
```

The `mov lr, pc` sets LR to the next instruction (even), so `bx lr` switches to
**ARM in place**.  The reverse veneer uses `add lr, pc, #1; bx lr`.

The first `bl` at `0x50310054` targets `0x50312c62`, whose first Thumb
instruction is a short branch into the Thumb handler at `0x5031279e`.  Later in
that handler the execution crosses into ARM code (`0x5031140c`) without a
veneer in the flat copy.  This is the loader/relocation step that is still
missing: the E32Image contains mixed ARM/Thumb functions and the linker's
relocation/interworking data has to be applied before the code is a valid
in-place image.

`recompiler/recursive.py` starts to solve this by tracking both modes, following
`bl`, `ldr pc,[pc,#imm]` and the `mov lr,pc; bx lr` veneers.  It currently finds
**122 functions (112 Thumb, 10 ARM)** in the kernel and lifts **99%** of
them.  The ARM functions include the interworking target at `0x50318ab0` and a
real helper at `0x50313084`.

## Native smoke test

`tools/build_kernel_smoke.sh` runs

```
wd2.py kernel -> recursive.py -> lift.py -> gen_register.py -> clang
```

and calls the lifted ARM helper `func_50313084` with `r0=0x1234`, `r1=0`.  It
writes to the ROM export area and the runtime's MMIO bus logs

```
[mmio] write 0x58000000 = 0x1234 (4)
```

That is a real 6600 kernel instruction executing natively through the new
sparse-memory runtime, not through Unicorn.

## Next tasks

1. **EKA1 loader** — copy the kernel to `0x50310000`, zero BSS
   (`data + data_size`), set the initial stack/registers, and apply the
   E32Image relocation/export data.  The current smoke uses the raw image.
2. **Mode-aware runtime** — add a `T` bit and an ARM/Thumb dispatcher to
   `nk_call`, or run unlifted thunks in a small interpreter.  This is what the
   `mov lr,pc; bx lr` veneers need.
3. **Packed region** — the high-entropy block around ROM `0x310000` is not
   reached by the current entry run; determine whether it is the compressed
   kernel payload (`KaeP`) or a data file, then implement the decompressor if
   needed.
4. **Mask ROM stand-in** — the real `0x00e0ca39` path is not in the dump; the
   runtime has to provide the MMU/vector state and jump to `0x50310054`.
5. **MMIO/display** — after the kernel runs, the UPP display/timer/keypad
   registers become the next HLE surface.

The phased plan, task board and acceptance criteria are in
[`PROGRESS.md`](PROGRESS.md).
