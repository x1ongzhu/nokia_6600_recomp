# Boot notes — NHL-10 v5.53.0

This is the bring-up log for the 6600 EKA1 image.  It records what is known,
what is executed, and the exact frontier.

## Entry points

| entry | address | mode | in the flash image? |
|---|---|---|---|
| UPP mask ROM | not in the dump | Thumb | **no** — internal boot ROM (the `0x00e0ca39` word at +0x84 is `TRomHeader.iTime` high, not an entry) |
| EKA1 ROM reset vector | `0x50000000` | ARM | yes (the image's exception table) |
| Kernel E32Image | `0x50310054` | **ARM** | yes, in the page-header-free stream at `0x31004c`/`0x3100b0` (link `0x50310000`); the raw `0x326924` is a page header |
| Boot-image handoff | `0x00000080` | ARM | target of the secondary loader; round 17 installs `ldr pc,[pc,#-4]; .word 0x50310054` there, so the handoff enters the kernel |

The ROM header's `iTime` high word is **not** a mask-ROM entry.  The kernel is
separate: its EKA1 `TRomImageHeader` (`uid3 0x100058e8`) is at stream
`0x31004c`, and the loader copies its text to **`0x50310000`**.  The entry is
**`0x50310054`** (ARM).

## What runs today

Two modes are available in the same native ARMv4T interpreter
(`runtime/src/nokia_interp.c`):

```sh
# baseline: exact stop at the first unlinked call
tools/build_boot_trace.sh

# assisted: reconstruct sections/DLLs and repair interworking call sites
NK_E32_SECTIONS=1 NK_CALL_INFER=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --e32 0x3268c0

# bring-up: patched flat image + call-site map + crash recovery (historical)
tools/build_bringup_image.sh
tools/test_boot_recover.sh

# round 16/19: real kernel entry (ARM) with its vector table installed
tools/build_rom_image.sh
NK_KERNEL_VECTORS=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=1000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_pagestream.sh

# round 19: direct call gate + the one export-table hole bridged
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
  NK_IMPORTMAP=config/imports-6600.txt NK_RECOVER=0 NK_CALL_INFER=0 \
  NK_BUDGET=200000 NK_MMIO_N=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_imports.sh

# round 20: initial thread -> process -> CObjectIx graph
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=6000000 NK_B7E=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_b7e.sh

# round 23: super page, RAM bank table, page bitmap, WD2 CTSI DMA
tools/test_round23.sh
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-wd2-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x503994e8 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
```

### Round 19: the ROMFS boot table and image imports (2026-10-25)

Two corrections move the frontier past the locale/extension hand-off.

**1. The 586-entry directory is `\System\Libs`.**  The packed directory block
below the kernel is stored at its runtime VAs when read linearly from the root
list: `\System\Libs\Plugins` at `0x5030000c` (171 entries), `\System\Libs` at
`0x50301ec0` (586 entries, starting with `ekern.exe`), `\System\Programs` at
`0x50307964` (55 server entries).  `TRomHeader.iPrimaryFile` (`0x5000009c`),
`iSecondaryFile` (`0xa0`), `iVariantFile` (`0xc8`) and `iExtensionFile` (`0xcc`)
are `TRomEntry` pointers into the **Libs** table: `ekern.exe` (`0x5030ff9c`),
`EFile.exe` (`0x503b70a0`), `ecust.dll` (`0x50339750`) and `rtc.dll`
(`0x5033edb0`).  The old builder overlaid Libs with the Plugins content (and
Programs with the Libs content), so `0x5031eae0` read UTF-16 name bytes as a
`TRomImageHeader` and jumped to 0.  Directories are now verified in place; no
destructive overlay is applied when the packed bytes already sit at their VA.

**2. A flat image already binds every real import.**  EKA1 stubs are
`ldr ip,[pc]; ldr pc,[ip]` and the literal is the **exporting image's export
table entry**.  Because that entry holds the linked code address, only holes
(`0xffffffff`) need loader work.  `recompiler/imports.py` enumerates 1,111
stubs; the kernel has 257 (236 EUser + 21 ELocl) and exactly one hole:
**ELocl ordinal 20**, called unconditionally by the locale initialiser
`0x50326078`.  `NK_IMPORTMAP=config/imports-6600.txt` binds it to a
high-vector `mov r0,#0; bx lr` stub.

With both fixes the kernel runs the real `rtc.dll` extension:
**8,512 instructions, 0 undefined, 0 unbound IAT**.  The next stop is EUser's
`RHeap::Alloc` (`0x50380270`): the kernel overwrites the current-thread global
`[0x800017d4]` with `0x802ffd00`, so `[thread+0x18] -> [process+0x38]` yields a
null heap and `bx ip` leaves to 0 (`pc=0`, `lr=0x503802ac`, `cpsr=0xdb`).
That is the B7e initial-thread/process task, not an import or layout bug.
**Round 20 correction:** `0x50380270` is `CObjectIx::At` (an object-array
accessor), and `process+0x38` is the object index, not a heap.  The real
frontier is the missing initial process/object index; see the round-20 section
below.

### Round 20: MUL destination, and the real B7e state (2026-10-25)

Two corrections move the frontier from 8,512 to **5,575,900 instructions**.

**1. ARM MUL/MLA wrote the wrong register.**  The interpreter took `Rd` from
bits 15-12.  In ARMv4T, `Rd` is **bits 19-16**; bits 15-12 are only MLA's
accumulator (and the low half of a long multiply).  Every plain
`mul rd, rm, rs` therefore stored its product in **r0** and left the real
destination unchanged.  The object-index accessor's size multiply
(`0x5038029c mul r2, r3, r2`) hit this and destroyed its result pointer.
`nokia_interp.c` now stores to bits 19-16 and adds the MLA accumulator from
bits 15-12; `interp_selftest` pins `mul r2, r0, r1` with r0 unchanged.

**2. `0x50380270` is not `RHeap::Alloc`.**  It indexes an object array:
`[this+0x18]` is the array object, `[this+0x14]` the element size and
`[this]` the base added to the element.  Its caller `0x50318410` is the
handle-to-object path, reading `[thread+0x18] -> [process+0x38]`.  This is
**`CObjectIx::At`** (the SDK EUser ordinal 109), so round 19's "null heap"
was a misdiagnosis: the missing boot state is the initial **process and its
object index**.

`NK_B7E=1` installs thread -> process -> `CObjectIx` -> array, follows every
current-thread publication with the new guest write watch, and returns the
live current thread for handle 0.  The kernel publishes `0x802ffd00` and then
creates a second thread `0x80001860`; both get the graph.  The run:

```
insns=5575900 (ARM 5575900 / Thumb 0), undefined=0, call fixups=0, recoveries=0
mmio: 26 reads, 112096 writes
--- stop: pc left the image (5) at 0000000000 ---
```

The next frontier is the second thread's stack underflow (`sp=0`, `pc=0`),
i.e. the real `SThread`/`SProcess` fields (especially the thread's stack and
object slots), not an import, layout or heap stop.  The pre-MMU low alias now
also follows `NK_RAM_EXTRA`.  `tools/test_b7e.sh` is the acceptance test.

### Round 22: the RTC extension is a nested E32 image (2026-10-25)

**1. The header-less block after the RTC PDD is a second image, not rodata.**
The `rtc.dll` record contains two E32 images.  The first is the PDD factory
(uid3 `0x100000d8`, code `0x5033e2f4`, text `0xa9c`, export 1 hole at
`0x5033ed90`).  At stream `0x33ee60` (VA `0x5033edb0`) there is a second
`TRomImageHeader`:

```
uid1 0x10000079  uid2 0x100058d8  uid3 0
entry/code 0x5033ee14   text 0x2600   data 0x50341414
export_count 0           export_dir 0
```

Its text is the code at `0x5033ee14..0x50341414`, the RTC vtable is at
`0x503413e8`, and the driver object constructor is `0x5033ee18`.  The
`--place-rodata` block places the right bytes, but the label "rodata" was
wrong: this code executes.

The kernel's extension loader (`0x5031eae0`) calls the image entry
`0x5033ee14` and then, at `0x5031ebbc`, calls export ordinal 1 through
`[hdr+0x40]`.  With a zero export directory that is a jump to 0.
`NK_EXT_STUB=1` installs a one-entry export table at `0xffff0900` and a
stub at `0xffff0910` (`ldr r0,[pc,#8]; bx lr; .word 0x80003a40`), and points
the header at it.  The kernel installs the returned HAL-like object at
`[0x800003ac]`.

**2. The RTC driver's `operator new` import is RTest in this ROM.**  The
constructor calls the same EUser import slot (`0x503b4f14`, export index
1504) with `r0=0x38` and `r0=8` and treats the result as a pointer.  In this
ROM that slot holds `RTest::operator()`: its code references
`": FAIL : %S failed check %d\n"` and `"Checkpoint-fail\n"`.  The driver and
EUser were linked against different `.def` revisions.  RTest then enters
`Console::NewL` → `RLibrary::Load("econs")` → `svc 0x76`, and the kernel
panics **KERN-NO-SESSION** because the current thread has no session object.
The round-21 "file-server session" was therefore a symptom of a driver
ABI mismatch, not a boot service dependency.
[`config/callmap-rtc-6600.txt`](../config/callmap-rtc-6600.txt) serves the
two `new` sites from the harness bump heap (`NK_HLE_ALLOC`).

**3. The HAL channel must be a dereferenceable object.**  The B7e HAL stub
used to return the integer 1 for `r1=0`.  The RTC driver stores it at
`[this+8]` and later executes `ldr r3,[r0]; ldr pc,[r3,#0x18]`, so it jumped
to 0.  The stub now returns `0x80003a40`, a guest object whose vtable is
`0x80003c00`.  The driver's 64-bit system-time request (`0x5033f040`) is
served by the new `NK_HLE_ZERO2` sentinel (`0xfffffff9`): the kernel's time
formatter uses the same EUser slot `0x503b4d1c` that round 21 rebound to the
2-arg `TPtr16` constructor for the panic printer, and the two call sites need
different ABIs.

**4. Result and the new frontier.**  The extension initialises completely
and the kernel advances to the post-extension boot initialisation
`0x50310fa4`:

```
insns=27470 (ARM 27469 / Thumb 0), undefined=0, call fixups=15,
unbound IAT=0, recoveries=0
mmio: 42 reads, 22 writes
stop: self-branch (panic halt) at 0x50312b88
```

`0x5031f3a8` checks `[0x80000b5c] == 0xff` before using the kernel timer
object and panics PLAT 21 otherwise; the caller builds the `"IrqTimer0"`
descriptor (literal `0x50337200`), so this is the kernel timer/DFC init.  `0x80000b5c` is in kernel `.bss`; the direct
E32 entry skipped the mask-ROM/kernel startup that fills it.  `NK_POKE` and
`NK_PATCH` were added to probe this structure: an experimental patch of the
`cmp r3,#0xff` to `cmp r3,#0` advances another 179 instructions to the next
KERN-NO-SESSION, confirming that this check is the immediate gate.  The
correct next step is to model the boot descriptor/HAL entry table, not to
patch the kernel.  `tools/test_rtc.sh` is the acceptance test.

```
tools/test_rtc.sh

NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=8000000 \
  NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x5031f3c0 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
```

### Round 23: PLAT 21 was a TDesC8 ABI; super page, page bitmap, WD2 DMA (2026-10-25)

Round 22 left the run at the `"IrqTimer0"` gate `0x5031f3a8`
(`[0x80000b5c] == 0xff`, else PLAT 21) and concluded that the direct E32 entry
skipped the mask-ROM boot descriptor.  Round 23 re-read the static
constructor that fills that address and found an EUser ABI mismatch instead.

**1. An 8-byte name array and a 12-byte constructor.**  The second entry of
the kernel's static-constructor table is `0x50311508`.  It first calls
`0x50310dbc(0x80000b5c)`, which constructs the kernel timer object
(`0x5031f35c` sets `[obj] = 0xff`, `[obj+0x10] = 0x50338340`).  It then uses
kernel import slot `0x503b4d34` (this ROM's EUser export index 1384) to
initialise eight-byte `TDesC8` names at `0x80000b54`, `b4c`, `b44`, ... —
`"FiqTimer0"`, `"FiqTimer1"`, the DMA channels, and so on.  In this ROM that
slot holds a **12-byte** default constructor `0x5038a234`:

```
mov r1,#0
str r1,[r0]
str r1,[r0,#4]
str r1,[r0,#8]
```

The third store for `r0 = 0x80000b54` lands on `0x80000b5c` and clears the
timer state.  Rebinding the slot to `TDesC8(const char*)` **`0x50388984`**
makes the timer start normally; PLAT 21 disappears.  The old `NK_PATCH` of
`cmp r3,#0xff` was only hiding the symptom.

**2. The name lookup used `DObject::Close`.**  Timer start calls
`0x5031ba2c -> 0x50311104 -> 0x50310d5c`, which scans the name table at
`[0x80000020]` and compares each entry with the stack descriptor.  Slot
`0x503b3ac4` (index 204) is `DObject::Close` `0x5039d870` in this ROM; it
treated the descriptor length word `0x1000000d` as a handle and called
`svc 0x6b`, which panicked KERN-EXEC.  The correct target is
**`TDesC8::Compare`'s EABI entry `0x50388e30`**.  Do not bind
`0x50388e34`: that is the compare body and expects `ip` to hold the
memcompare helper, so it would `bx ip` back to the import slot.

**3. The super page is at `0x40000000`, not `0x7ff00000`.**  The kernel's
super-page accessor and `0x5031c0ac` show:

```
[0x40000010]   iTotalRamSize   (EKA1 7.0s offset)
[0x40000018]   iRamBootData    -> SRamBank{base,size}[]
[0x40000800]   TMachineConfig
```

The harness had mapped `0x7ff00000..0x80000000`, so every one of these reads
hit the MMIO bus and returned zero; the RAM allocator saw no banks and
panicked with the chunk name `TheRamDriveChunk`.  `NK_SUPERPAGE=1` maps the
fixed page and publishes a 6 MiB bank list split into power-of-two blocks:
`{0, 0x400000}` and `{0x400000, 0x200000}`.  The allocator then builds its
page bitmap and the page-table code runs.

```
super page 0x40000000: total RAM 0x600000, 2 banks at 0x40000100:
  {0,0x400000} {0x400000,0x200000}
```

**4. Three more wrong-ABI slots on the page bitmap.**  The allocator imports
`CBitMapAllocator` methods from EUser.  In this ROM those slots hold:

| slot | index | this ROM | kernel expected | rebind |
|---|---|---|---|---|
| `0x503b433c` | 746 | `0x50394b60` 2-byte array allocator | `CBitMapAllocator::New` | `0x50381b28` |
| `0x503b3980` | 123 | `0x50383718` CBufSeg helper | `CBitMapAllocator::Alloc` | `0x50381b84` |
| `0x503b3efc` | 474 | `0x503a2980` refcounted buffer release | `CBitMapAllocator::AllocAt(pos,count)` | `0x50382418` |

The wrong `New` returned a zeroed 2-byte array, so `AllocFrom` panicked
E32USER-CBase 80; the wrong `AllocFrom` then hit a CBufSeg panic 14.  The
real implementations are identifiable from their object layout
(CBase vtable +0, `iAvail` +4, `iSize` +8, `iLength` +0xc, `iMap` +0x10).

**5. B7e must follow the real DProcess.**  The kernel replaces the provisional
thread→process pointer with a real `DProcess` it allocates from the harness
heap; that process starts with `+0x38` (the `CObjectIx`) null, so
`0x50318410` eventually calls `CObjectIx::At` with `this = 0`.  The harness
now follows the live thread's process field (third write-watch slot), attaches
`B7E_OBJIDX` to the real DProcess, restores the last live thread when the
scheduler transiently clears `[0x800017d4]`, and supplies a thread-local
object at `[thread+0x5c]` whose vtable `+0x24` returns success.  The debug
`NK_WRITE_WATCH` hook now runs **after** the store, so a hook can replace the
value the guest just wrote.

**6. WD2 CTSI DMA hand-off.**  `0x5031380c` calls a HAL routine through
EUser index 970 (`0x503a14ec`); the E32-entry boot has no mask-ROM HAL state,
so it returned an error and `0x50310b30` panicked **KERN-WD2 24, "Invalid
CTSI DMA"**.  `config/imports-wd2-6600.txt` maps that slot to `zero` (success)
as an explicit stand-in.

**7. Result and the next frontier.**  The run now reaches **139,784
instructions, 0 undefined, 0 unbound IAT, 0 recoveries, 15 call fixups**,
passes the 6 MiB RAM bank table, page bitmap, page tables and WD2 CTSI DMA
init, and stops at `0x503994e8` with **USER-EXEC 3**:

```
insns=139784 (ARM 139779 / Thumb 0), undefined=0, call fixups=15,
unbound IAT=0, recoveries=0
mmio: 4106 reads, 7706 writes
stop: self-branch (panic halt) at 0x50312b88
[watch] pc=0x503994e8 ... r1=0x3
```

`0x503994b0` formats `"USER-EXEC"` and raises code 3 when
`0x50399504` returns zero: the current thread has no trap/exception handler.
The direct E32 entry skipped the scheduler's initial trap state.  The next
task is therefore the **initial thread's trap/exception state**, not another
import, layout or page-table fix.

```
tools/test_round23.sh

NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-wd2-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x503994e8 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
```

### Round 16 correction: the 0xec page headers (2026-10-25)

The flash image is a sequence of `0x20ec`-byte records, each a **`0xec`-byte
page header** followed by a **`0x2000`-byte payload**.  Round 7-15 kept the
whole header inline and only called its first six bytes a "tag", which
inserted `0xec` bytes every `0x2000` bytes of every packed record.  Everything
below that depended on the kernel text starting at raw `0x326924` (a page
header) is therefore historical: the "197-instruction entry", the missing
Thumb `pop`, the callmap, the 17.2%/21.8% export rates, the drift null and the
truncated `\System\Programs` directory were all page-header artifacts.

`recompiler/pagestream.py` removes the headers.  The kernel header is at
stream `0x31004c`, its text at `+0x64` (`0x3100b0`), and entry `0x50310054` is
**ARM** (`push {r4,r5,r6,lr}` / `0xe92d4070`).  The 478 exports land on
function starts **469 times (98.1%)**; DLL `0x100039e5` is **1757/1788
(98.3%)** at shift 0.  The 586-entry directory is `\System\Libs` (the boot
image table); `\System\Programs` is the 55-entry server list (round 19).

The flat image built from the stream boots the real entry for **924,964
instructions** (0 undefined, 0 call fixups, 0 recoveries, 2 MMIO reads /
18 writes) and stops at `0x5039b2b8`: the SVC stack has descended through the
`0x7ff00000` super page into `.data`, the saved `lr` is zero, and `bx lr`
returns to 0.  That is the new kernel frontier, not another veneer.

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

### Round 7: the full image map and the ROMFS tree (2026-10-24)

Two things were wrong with the flat image, and both were silent:

1. **Packed records are 2-byte aligned.**  `TRomImageHeader` can start at
   2 mod 4 because the ROM build removed the linker's 4-byte padding.
   `MmfAudioController.dll`'s header, for example, is at file `0x7271ca`.
   Scanning every 4th byte missed 40+ images.  A 2-byte scan plus a
   record-plausibility filter (declared sections must fit before the next
   header; the unexplained rodata gap must be small) recovers **722 images**
   in the raw view (**725** on the page-header-free stream, round 16)
   from 781 candidates.  Their text ranges are disjoint and span
   `0x5030ff9c..0x515978dc`.  `romimage.py build` now places **all** of them
   (1,580 sections, no overlaps), not just the kernel and its two direct DLL
   references.  The boot harness's flat-image loader scans at 2 bytes too and
   declares the kernel + its `TDllRefTable` DLLs as code ranges by default
   (`NK_RANGE_ALL=1` accepts every image for call repair).

2. **ROMFS has a directory tree, and file data is not linear.**  The directory
   block below the kernel is copied at its runtime VAs (round 19).  Locating
   directories by content recovers:

   | directory | packed file | runtime VA | entries |
   |---|---|---|---|
   | root | `0x30fb28` | `0x5030fa78` | 2 (`\System`, `\Nokia`) |
   | `\System` | `0x30f230` | `0x5030f180` | 23 |
   | `\System\Libs` | `0x301f70` | `0x50301ec0` | **586** (boot image table) |
   | `\System\Programs` | `0x307a14` | `0x50307964` | 55 (servers) |
   | `\System\Libs\Plugins` | `0x3000bc` | `0x5030000c` | 171 |

   `\System\Libs` is the ROM's boot image table: `ekern.exe` (the kernel,
   uid3 `0x100058e8`, code `0x50310000`), `EStart.exe`, `EFile.exe`,
   `ecust.dll`, `ecomm.ldd`, `ramdrive.pdd`, `rtc.dll`, `ELocl.dll`,
   `EUser.dll`, ...  The ROM header's primary/secondary/variant/extension
   pointers are `TRomEntry` addresses into it.  `romimage.py names` prints it
   and maps entries to packed records.  `\System\Programs` holds the remaining
   server executables (BTTestServer, PhoneServer, SharedDataServer, ...).
   `\System\Libs\Plugins` holds the plugins (`AcmClassController.dll`, ...).
   The old "9 valid Programs entries" and "586 Programs" figures were page
   header / parent-name artifacts.

   The data files themselves are stored in packed FS order with `0xff`
   padding, not at `addr - 0x50000000`.  The old build copied from the linear
   address and therefore spliced unrelated code into ~17 MB of the flat image;
   `build` now leaves those bytes empty unless `--romfs-linear` is passed.

The faithful image still reaches 364 instructions (without recovery) and the
relaid image still returns after 289.  With `NK_RECOVER=1` and the full image
map on the **faithful** image (no bring-up patch), the trace runs past the entry
into `euser.dll` and settles in the old round-4 loop at `0x50389330`.  That long
run is a **patch artifact**: the missing Thumb `pop` at `0x5039adcc` lets the
helper run into ARM code.  The bring-up image (same layout plus
`config/patches-6600.txt`) completes the entry in 197 instructions; see the
round-8 section below.

### Round 7 finding: the export table does not match the packed text

The kernel's export directory holds 478 addresses, all 4-byte aligned and
inside the text.  Only **17** of them land on a detected prologue; the
backward distances to the nearest prologue are almost uniformly distributed
(0, 4, 8, ... 44 each occur 10-18 times).  Cumulative alignment padding cannot
produce that: the total padding is `0x58` bytes and would grow monotonically.
The packed text and the export directory therefore come from different
layouts.  The relayout pass repairs literal-pool alignment inside a function
but cannot recover inter-function call edges; that needs symbol-level
recovery (B1g in `docs/PROGRESS.md`), not a larger snap window.

### Round 9: the export table is the layout oracle (2026-10-24)

The export directory is a **fixed-up list of function addresses**, indexed by
ordinal (Symbian's `TRomImageHeader` documentation: "the export directory is a
simple list of functions, which can be indexed by ordinal").  Thumb entries
carry the interworking bit (bit 0), so a 4-aligned-only reading loses data.
This makes it the best available ground truth for the layout question: after
a correct unpack every entry must be a function start in the text.

`recompiler/layout.py census` measures that.  Two controls validate the
method first:

| image | exports | on a start | note |
|---|---|---|---|
| `\System\Libs` 0x101f6e00 (small Thumb DLL) | 5 | **5/5 (100%)** | all odd, all `push {..,lr}` |
| 0x10001844 (small DLL) | 8 | 6/8 | the two misses are leaf entries |

For the boot-critical images the same test fails, and not by a small margin:

| image | exports | in text | on a start | random baseline | ratio |
|---|---|---|---|---|---|
| kernel 0x100058e8 | 478 | 478 | **82 (17.2%)** | 13.1% | **1.31x** |
| DLL 0x100039e5 | 1788 | 1726 | **258 (14.4%)** | 5.9% | **2.44x** |

"Random baseline" is the fraction of arbitrary text addresses that the same
detector calls a function start, so 1.31x means the kernel's export table is
essentially unrelated to the stored text layout.  Other tests confirm this is
not an alignment offset:

* applying the current relayout plan (44 pads, `0x58`) and following it
  backwards still gives only **58/478** kernel entries;
* the best **constant** shift is `0xb0`, and only gives **93/478**;
* a linear (or widening) drift model over 100k combinations gives nothing
  better than the constant shift;
* the stored kernel text keeps **1420/1430** ARM function starts and
  **759/787** literal pools 4-byte aligned.  Two-byte padding therefore
  cannot account for more than `0x58` of address drift.

Conclusion: the packed text's function layout is **not** the linked layout.
This is stronger than the round-7 statement ("padding is only a partial
repair"): no padding pass can recover the linked layout, because the drift is
larger than, and not monotone with, the observed pool/function alignment.
`relayout` remains useful (it is directly validated by the pool literals and
fixes the entry's `ldr`), but it cannot restore inter-function semantics.

Consequences for the bring-up:

* stop tuning snap windows against the export/call mismatch;
* keep the runtime's bounded snap/callmap as an explicit **bring-up** layer,
  not as the faithful execution path;
* the next layout step is global recovery from the 478 kernel exports plus
  the 3,854 call sites and the ~7,000 literal code pointers (B1g2), or
  obtaining the linked layout from the container / ROM build description
  (B6b);
* the entry still runs because drift is zero at the start of the text and
  grows slowly: nearby callees stay inside the intended function, which is
  exactly why snap-to-nearest-start works for the first few calls.

```
.venv/bin/python recompiler/layout.py census 6600_mcu.bin --json out/layout_census.json
.venv/bin/python recompiler/layout.py pools 6600_mcu.bin
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin
tools/test_layout.sh
```

### Round 10: pool-aware census and the truncated Programs directory (2026-10-25)

Two corrections to the round-9 picture, neither of which rescues the packed
text, plus one new hard limit on the ROMFS.

**1. The start detector was undercounting leaf functions.**  A leaf function
after a literal pool is a real function start, but its immediately preceding
word is a literal, not a terminator.  `layout.py` now has a `pool_aware`
walk-back (up to 0x60 bytes of address-like words, then a terminator).  The
kernel's export score rises from 82/478 (17.2%) to **104/478 (21.8%)**; the
random baseline rises in the same way (13.1% → 17.2%), so the ratio *falls*
to **1.27x**.  The best constant shift becomes `0x128` with 112/478, still
far from a linked image.  Round 9's conclusion stands: the stored text is not
the linked text at function granularity.

**2. The entry's literal loads are locally consistent after relayout.**  The
three `ldr`s at `0x50310070`, `0x5031007a` and `0x50310084` all resolve to the
packed pool at `0x5031008e`.  Only after the relayout pad before the entry
`push` (`0x50310056`) do they read the intended `0x00046564` / `0x00046fca` /
`0x00000c03` (the B ldr needs the 4-byte PC-base change caused by the shift).
This validates the entry repair, but it does not validate the BL targets: the
same callee is called with different biases from different sites, so the
targets are stale per call site.  Plausible true callees for the entry calls
are the vtable thunk at `0x50312c3c` (+0x2e) and the leaf at `0x503134f0`
(+0x32), not the nearest prologue.  This is why a "nearest prologue" snap
window cannot recover the real function map.

**3. The packed `\System\Programs` directory is truncated.**  Its `TRomDir`
declares `0x5608` bytes, but only **9 entries / 0x114 bytes** are present; the
next packed image record overwrites the remaining `0x54f4` bytes with code.
The nine real entries are the boot-critical set:

```
ekern.exe  ecust.dll  ecomm.ldd  ramdrive.pdd  rtc.dll
nosstarter.ext  pnmsg.dll  isimsg.dll  isaapi.dll
```

The old parser read the code that follows as more entries and produced 236
plausible-looking names (`EStart.exe`, `EFile.exe`, `EFSrv.dll`, ...); those
entries are **not in this dump**.  `\System\Libs` (586, round 19),
`\System` (23), `\System\Programs` (55) and the root (2) are complete.
`romimage.py` now validates every entry (ASCII
name, address inside the ROM window, sane size) and reports the truncation in
`scan`, `names` and `build` instead of inventing entries.  This is a hard
limit on B3e/B3g: the app directory tail must come from the final flash
layout (B6b), a linear ROM dump, or another partition.

The rest of the tree is intact, and `romimage.py tree` recovers it by content:
`\System\Apps` is the only directory whose entries are all subdirectories, and
each app directory is the small directory holding `<App>.app`.  All **63**
app directories resolve, including `snakeex` (`SnakeEx.app`, 0x7ddc) and
`mixpix` (`mixpix.app`, 0xd718).  `romimage.py build` also places the **76
E32Image files** (63 `.app` binaries plus 13 plugin/driver files): a plain
E32Image file header is at `entry_addr`, its `iCodeAddress` is
`entry_addr + 0x64`, and the packed bytes from that header are the file.  The
flat image has `SnakeEx.app` at 0x5147f060, byte-identical to the packed file
record.  The AIF and MBM companions are in the same packed run: their UID
headers (`0x101fb032` / `0x10000041`) locate 84 of them, which `build` copies
too.  The `.r01`/`.wav` resources are stored in the compressed data area and
are the remaining B3g work.

```
.venv/bin/python recompiler/romimage.py names 6600_mcu.bin
.venv/bin/python recompiler/romimage.py tree 6600_mcu.bin --verbose
tools/test_layout.sh
tools/test_romimage.sh
```

### Round 11: padding-only drift is rejected; the mask-ROM loader entry (2026-10-25)

**1. No monotone drift can explain the kernel export table.**  The strongest
form of the "packed text is the linked text with 2-byte padding removed" model
does not require a fixed shift: it may match an export `V` to *any* stored
function start `c <= V`, with a **non-decreasing** cumulative drift `V - c`,
and it may skip exports.  `layout.py drift` finds the longest such monotone
matching and compares it with the same statistic on random text addresses (the
null hypothesis):

| drift budget | best chain | null avg | null max | ratio |
|---|---|---|---|---|
| `0x60` | 149/478 (31.2%) | 140.4 | 152 | **1.06x** |
| `0xc0` | 183/478 (38.3%) | 168.6 | 186 | **1.09x** |
| `0x200` | 225/478 (47.1%) | 217.2 | 227 | **1.04x** |

The best padding-only model is statistically indistinguishable from random.
This closes the **monotone drift** branch of B1g2: the difference is not a
removed-padding offset, it is a different **function order** (or a relocation
table).  Recovering it needs an explicit function-order/relocation table or a
symbol-level permutation, not more padding.

**2. The census now distinguishes a wrong layout from a wrong export table.**
`layout.py census` adds an `in-code%` column.  Across 692 images with exports:
135 have every entry inside their own code range (the kernel and the big DLLs),
155 are about half in-code (the export section is probably misplaced or the
"header" is a data false positive), 36 are lower and 366 are none.  The kernel
is fully in-code, so its low start rate is a real layout mismatch, not a
parser artifact.  The half-in-code group is recorded as the next cleanup, not
used as layout evidence.

**3. The mask-ROM loader entry is identified.**  The boot harness now accepts
`NK_Rn` (n = 0..12) so the register state the UPP boot ROM would pass can be
reproduced.  The secondary loader entry is **`0x500003bc`**:

```
500003bc  mov  r0, fp                 ; r11
500003c0  sub  r1, pc, #0x298         ; 0x50000130 -> KaeP descriptor
500003c4  mov  r2, sl                 ; r10
500003c8  mov  r3, #0
500003cc  b    0x50001648             ; image loader/relocator
```

The `KaeP` block at `0x50000124` (`"KaeP"`, size `0x20`, value `0x1423dc`,
payload at `0x130`) is the loader descriptor.  Without call repair the loader
executes **211 instructions**, recovers 10 stale calls and returns to the
sentinel.  With `NK_CALL_POLICY=3 NK_SNAP_WINDOW=0x400` the first stale call
(`0x50001664 -> 0x50002ae4`) snaps to the nearest prologue **`0x500029dc`**
and the loader runs **>300,000 instructions**, then scans a table whose base
is 0 and whose count is about `0x80000000`.  The snap is a bring-up aid, not a
proof that `0x29dc` is the intended callee.  The scan itself is still
informative: it wants the **boot image/super-page table** the mask ROM would
install at address 0, which is not present in the flash dump.  The next boot
task is therefore concrete: model that table, not another snap window.

**4. The boot bank is linked at 0, not at 0x50000000.**  The loader's type
switch is `ldr pc, [pc, r3, lsl #2]` over a table of **0-based** targets
(`0x2908`, `0x28bc`, ...).  Executed at `0x500003bc`, those targets resolve to
low RAM (`0x00002908`), which is why the loader failed there.  The mask-ROM
physical view is: **boot code at 0**, ROM data/literals at `0x50000000`, RAM at
`0x80000000`.  `NK_LOW_ROM=1` now copies the first 64 KiB of the ROM to `0x0`,
registers that range as code, copies the 16 exception vectors to
`0xffff0000`, and lets the interpreter execute the low alias (the CPU guard
still rejects every other address below `0x40000000`; `allow_low_alias` is
opt-in).  With this view the loader runs **299,991 instructions** without
call repair, then loops at `0x1248` after 9 high-vector exceptions.  That is
the next frontier: the exception/super-page state, not the loader entry.

```
NK_LOW_ROM=1 NK_ENTRY=0x3bc NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
```

```
.venv/bin/python recompiler/layout.py drift 6600_mcu.bin \
  --json out/layout_drift.json

NK_ENTRY=0x500003bc NK_R11=0x80000000 NK_R10=0 \
  NK_RECOVER=1 NK_CODE_ONLY=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
```

**5. The header-less block is not always debug rodata.**  `layout.py gaps`
classifies the block between `.text` and `.data` by printability, pointer
density and instruction decode.  Of 629 images with a gap >= 16 bytes, 404 are
strings/pointer tables and 15 are a **second Thumb/ARM code fragment**
(`0x100039e1` 0x1838, `0x100058c1` 0xbce, `0x101f85e3` 0xa32, ...).  The kernel
(`0x135c`) and the big boot DLL (`0x19dc`) are correctly rodata, so this does
not explain the kernel export mismatch, but it is another way a packed record
is not a simple contiguous image.  `tools/test_layout.sh` pins the split.

```
.venv/bin/python recompiler/layout.py gaps 6600_mcu.bin --code-only
```

### Round 12: the boot bank is fragmented; the linked view runs clean (2026-10-25)

**1. The bank is not stored at its linked addresses, and the mask ROM says by
how much.**  `0x3b0` is `sub r1, pc, #0x308; add r0, r0, r1; mov pc, lr`: it
adds the **relocation addend `0xb0`** to `r0` (`physical = linked + 0xb0`).
So the linked image starts at stored offset `0xb0`.  The loader entry `0x3bc`
is `mov r0, fp; sub r1, pc, #0x298; ...`; in the linked view it sits at `0x30c`
and its descriptor is `0x130 - 0xb0 = 0x80`, the KaeP payload.

Two independent anchors confirm the shift:

* the loader's final hand-off at stored `0x1754` is the literal `0x1244`; the
  real `push {r4,r5,r6,r7,r8,sb,sl,lr}` entry is at stored `0x12f4` = `0x1244 +
  0xb0`;
* the first switch table (`ldrls pc, [pc, r0, lsl #2]` at `0x1238`, table
  `0x1240`) holds `0x11a8/0x11b0/0x11b8/...`; adding `0xb0` gives
  `0x1258/0x1260/0x1268/...`, exactly the `mov r0, #imm; mov pc, lr` case
  bodies that follow the table.

**2. Later fragments have a larger bias.**  The packed bank concatenates code
fragments that were linked for different bases.  The compiler's switch tables
measure the bias: the closest case body follows the table, so
`table_end - entry` is a lower bound, and all tables in one fragment agree to
within `0x20`.  `recompiler/bootbank.py` finds 17 tables in the first 64 KiB:

| fragment | linked range | stored range | measured bias | tables |
|---|---|---|---|---|
| A | `0x0000-0x2000` | `0x00b0-0x20b0` | **0xb0** | 7, all exactly `0xb0` |
| B | `0x2000-0x6000` | `0x219c-0x619c` | **0x19c** | 8 (`0x18c`-`0x19c`) |
| C | `0x6000-0x8000` | `0x6374-0x8374` | **0x374** | 2 (pinned in round 15 by the CPU table) |

The gaps `0x20b0-0x219c` (`0xec`) and `0x619c-0x6374` (`0x1d8`) are **not**
padding: they contain further ARM/Thumb code and literal pools, linked for yet
another base.  Round 12 could only pin A and B, so its `build` moved just
those two; round 15 pins C with the CPU/board table and moves all three.

**3. The reconstructed view boots on the real path.**  `bootbank.py build`
moves A and B to their linked addresses; `boot_kernel` maps the result at 0 via
`NK_LOW_ROM_IMAGE` and starts at linked `0x30c`:

```
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
```

| | verbatim bank (round 11) | linked view (round 12) |
|---|---|---|
| instructions | 299,991 then loop | **600,000** (budget) |
| stale-call recoveries | 9 | **0** |
| undefined | 0 | 0 |
| hand-off `0x1244` | executed as a switch table | real loader function |
| UPP MMIO | none on this path | `0x08000008 = 0x37` |
| stop | `0x125c` (inside the table) | `0x1a1c`, lookup loop `0xc7c` |

The MMIO write is real device surface: linked `0x4298` (called from the size
probe `0x36a4`, which returns `0xb8000`) configures `0x08000000` and was
previously unreachable.

**4. The new frontier is the empty boot-image list, not another veneer.**  The
loader thread at `0x1244` calls `0xc58` with the KaeP payload (`0x80`) and the
frame buffer (`0xfffff400`).  `0xc58` treats the payload as a record: it checks
`[0x80+0x20]` (`0xe59ff018`, the vector table) and looks up the key
`[0x80+0xc]` (`0xdff9ea00`) in the list at `0xfffff400`.  That list is empty
(`[0xfffff400] = 0`), so `0x1a1c` returns `-1`; the caller does not check and
reads `[0x3]`/`[0x5f]`, then loops.  The mask ROM (or a decompression step)
must install the **boot-image/region list** the loader expects.  This is the
concrete successor of round 11's "super-page table" task.

```
.venv/bin/python recompiler/bootbank.py analyze 6600_mcu.bin
.venv/bin/python recompiler/bootbank.py build 6600_mcu.bin \
  out/6600_bootbank_linked.bin
tools/test_bootbank.sh
```

### Round 13: an ARM immediate bug; the boot-region table becomes explicit (2026-10-25)

**1. `and r0, r0, #0xff` was executing as `LDRH`.**  The extra load/store
decoder tested only bits 7-4 (`1xx1`) and bits 6-5.  ARMv4T extra loads/stores
also require **bit 25 = 0** (bit 22 is their immediate flag); data-processing
instructions use bit 25.  A data-processing immediate whose low byte has bit 7
and bit 4 set therefore fell into the extra-transfer branch.  In the linked
boot bank `0x2b40`:

```
0xe20000ff  and r0, r0, #0xff
```

turned `r0 = 0x00000504` into `0xffffd9c0`, which then became the KaeP
descriptor's fourth argument.  With the bit-25 guard it returns `4` (the CPU
revision) as intended.  `interp_selftest` pins both sides: an `and/orr`
immediate and a real `ldrh`.

No other trace moved: kernel entry 197, assisted 364, relaid 315, raw bank
399,991 instructions.  The fix removes a silent wrong-value class from every
future boot run.

**2. The mask ROM's bank table is now an explicit input.**  The loader consumes
the table at `r0/fp` as:

```
+0x00 count (u32), +0x04 zero
+0x08 entry[0] = { base, size, attr, linbase }   (0x10 bytes each)
```

* `0x2a34` finds the bank containing an address (called with 0 for the boot
  bank);
* `0x2a7c` finds the bank with `attr & 0x4000`; its end minus `0x1000` is the
  super page;
* `0x1a1c` translates **linear -> physical** through `linbase` (and back
  through banks whose byte `+0xb` has bit 3);
* `0x1958` compacts the table into the super-page list; types 2/4 expand
  through a page mask; `0x21d0` marks types 1/4;
* `0x1b34` maps a byte offset to an address, but only through type 2 banks.

`recompiler/bootregions.py` derives the table from `TRomHeader`: boot bank
`0..0x10000`, ROM `0x50000000+0x1600000`, RAM `0x80000000+0x300000`
(attr `0x4000`).  `NK_REGIONS=path[@addr]` installs it.

| | round 12 (no table) | round 13 (derived table) |
|---|---|---|
| super page | `0xfffff000` fallback | **`0x802ff000`** (RAM top) |
| thread stack | `0xfffff3fc` | **`0x802ff3fc`** |
| list at super-page+0x400 | empty | **3 banks** |
| recoveries / undefined | 0 / 0 | 0 / 0 |
| UPP write | `0x08000008 = 0x37` | unchanged |

```
.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin \
  out/6600_bootregions.bin
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_REGIONS=out/6600_bootregions.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
tools/test_bootregions.sh
```

**3. The frontier moved inside the KaeP payload.**  The table works, but the
loader thread at `0x1244` calls `0xc58` with the payload at `0x80`; `0xc58`
asks the table to translate `[0x80+0x20] = 0xf018e59f`, which no bank covers.
The region `0x10000..0x2a0000` has 7.998 bits/byte entropy, and the `KaeP`
header at `0x124` (`"KaeP"`, size `0x20`, value `0x1423dc`, repeated
`0xdff9ea00` words at `0x130`) points into it.  That value is therefore not a
linear address to map: the 0x20-byte payload is a packed/obfuscated blob that
must be **unpacked first**.  Guessing more banks cannot fix it; the next task
is the KaeP unpacker.

### Round 14: the KaeP page grid; the loader passes 0xc58 (2026-10-25)

Two independent findings move the boot frontier this round.

**1. The first 7 MiB are a paged image, not a byte stream.**  A six-byte page
tag

```
20 00 00 00 dc 23
```

is inserted every `0x20ec` bytes.  The first real tag is at file `0x20b0` and
the last at `0x6d9134` — **852 tags**.  (`0x128` also reads `20 00 00 00 dc 23`,
but those bytes are the KaeP size field plus the low half of its value, not a
page tag.)  The kernel text starts exactly on a tag (file `0x326924` = runtime
`0x50310000`), which is why its entry `+0x54` is still `nop; push {r4,r7,lr}`;
removing the tag at the text start puts the same entry at `+0x4e`.  Code after
a tag is shifted by six bytes relative to a tag-free layout.

`recompiler/kaep.py` makes this measurable (`analyze`, `despan`, `synth`,
`verify`), and `tools/test_kaep.sh` pins it.  Two cautions:

* the tag semantics are **not** known.  It may be a flash page header, a
  flasher insertion, or part of a KaeP container; the tool only measures the
  grid.
* despinning does **not** repair the export layout.  On the kernel the
  pool-aware export hit rate drops from **104/478 (spanned)** to **67/478
  (despanned)**, so the function-order mismatch (B1g2) is independent of the
  page tags.

The `KaeP` header itself is `{magic, size=0x20, value=0x1423dc}`.  Its payload
at linked `0x80` is the repeated `0xdff9ea00` block; the loader consumes it as
a boot-image descriptor.  `kaep.py synth` can substitute an explicit
descriptor/list node for bring-up, but that is not the real unpack.

**2. The boot-region table's type and flag checks were wrong.**  `0x1a1c`'s
first pass only processes banks whose low-5-bit type is **5..8** *and* whose
attr byte at `+0xb` has bit 2 set (`0x04000000`).  `0x1b34` only processes
**type 2**.  The round-13 legacy table (`attr=1`) is therefore invisible to
both, so the KaeP lookup `0xf018e59f` could never succeed.  The new
`bootregions.py --profile linear` profile is:

| bank | base | size | attr | purpose |
|---|---|---|---|---|
| RAM | `0x80000000` | 6 MiB | `0x04004002` | type-2 offset mapping, super page |
| ROM | `0x50000000` | `0x1600000` | `0x04000005` | type-5 linear translation |
| boot | `0` | `0x10000` | `0x04000005` | type-5 linear translation |

The RAM bank is first so `0x1b34(table, 0)` maps offset 0 to RAM, not the boot
bank.  The harness needs `NK_RAM_EXTRA=0x300000` for the 6 MiB bank.  On the
**original** linked boot bank (no synthetic descriptor) the run now:

| | round 13 | round 14 |
|---|---|---|
| boot-region table | `attr=1` legacy | linear profile |
| KaeP lookup `0xc58` | fails (`0xf018e59f` outside) | **passes** |
| instructions | 600,000 | 600,000 |
| recoveries / undefined | 0 / 0 | 0 / 0 |
| stop | `0xc7c`/`0x1a1c` lookup loop | **`0x2fe4` page-table fill** |

`0x2fe4` is a page-table fill loop (`r2 ≈ 0x65802` entries, `r8` walking the
destination).  It is progress, not a finished boot: the linear profile's
`linbase` is used as a base address by `0x1a1c` but as a page mask by
`0x1958`/`0x18b0`, and that dual role is not modelled correctly yet.  That, the
real KaeP unpack and the page-table destination are the next tasks.

```
.venv/bin/python recompiler/kaep.py verify 6600_mcu.bin
.venv/bin/python recompiler/bootregions.py verify 6600_mcu.bin --profile linear
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
  NK_REGIONS=out/6600_bootregions_linear.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
tools/test_kaep.sh
```

### Round 15: fragment C, the CPU table and the boot-image handoff (2026-10-25)

**1. The boot bank's third fragment was never relocated.**  Round 12 measured
fragment C's switch tables (bias `0x374`) but `build` only moved A and B.  The
loader then read the 16-bit CPU/board table at linked `0x74b8` from instruction
bytes instead of the table:

```
0x3d10  ldr r1,[pc,#0x28]      ; r1 = 0x74b8, table base
        ldrh r3,[r1,r0,lsl#1]
        cmp  r3,ip             ; ip = 0x3b (CPU/revision)
        ...
0x3d44  b .                    ; panic when no entry matches
```

The correct halfwords are at **file `0x782c`** (`0x0000, 0x002a, 0x0029,
0x002b, ... 0x003b, ...`), exactly `linked + 0x374`.  `bootbank.py build` now
relocates `0x6000..0x8000 <- 0x6374..0x8374`; the CPU lookup succeeds and the
`0x3d44` panic disappears.  `verify` pins both the bias and the `0x3b` table
entry.

**2. A corrected synthetic KaeP descriptor/list.**  `0xc58` searches a boot
image list: it translates `descriptor+0x20` (the list head), reads
`head+4` as the node address, then checks `node+0x60` for the type word and
`node+0x5c` for the next pointer.  The earlier stand-in wrote one node at
`0xfd00` but left `+0x5c` as executable code, so the search followed a garbage
pointer and returned 0; the section size then became 0 and the parser mapped a
2 GiB section.  `recompiler/bootbringup.py` now writes:

```
0x80 descriptor: key 0x80000000, entry 0x50310054,
                 code 0x50310000, data 0x80000000,
                 list head 0xfd00, code size 0x28ac0, data+bss 0x2158
0xfd00 head:     +0x04 = 0xfd10
0xfd10 node:     +0x2c = 0, +0x34 = 0x28ac0, +0x48 = 0x2158,
                 +0x5c = 0 (terminator), +0x60 = 0x05040000
```

It also patches `0xfb8` (the KaeP compressed-image parser) to `mov pc,lr`; the
real parser is still in the bank, but it cannot run against the synthetic
descriptor.  This is an explicit stand-in, not a KaeP unpack.

**3. A staging boot-region profile.**  `bootregions.py --profile staging`
uses the `0x18b0` no-expand sentinel (`linbase = 0xffffffff`) for the type-2
RAM bank and two type-5 section banks:

| bank | base | size | flags | section result |
|---|---|---|---|---|
| RAM | `0x80000000` | 6 MiB | type 2, super page | offset mapping / super page |
| kernel code | `0x5030ff9c` | `0x29064` | type 5, `0x4000` | `base+size-0x29000 = 0x50310000` |
| kernel data | `0x50338ac0` | `0x3000` | type 5, `0x8000` | source `0x50338ac0` -> `0x80000000` |
| boot | `0` | `0x10000` | type 5 | identity |

`0xde0` selects the code/data banks by flag; `0x844` advances the section
offset from the bank end, so the code section becomes an identity mapping of
`0x50310000` (`0x29000` bytes) and the data section copies `0x50338ac0` to
`0x80000000` (`0x3000` bytes).

**4. Device and panic observability.**  The interpreter now reports `b .` as
`NK_STOP_SELF_BRANCH` (panic halt) and does not let crash recovery swallow it,
so a firmware panic stops at once instead of burning the budget.  The MMIO bus
has two explicit UPP handshake stubs: `0x58150422` returns bit `0x400` and
`0x58120a08` returns 1.  `0x41001400` returns 1 for the RAM-size probe.  These
are device stubs, not CPU behaviour.

**5. Result.**  `tools/test_bootbringup.sh` runs:

```
36,732 instructions (ARM), 12 MMIO reads, 46 writes,
1 recovered stale call, 0 undefined
--- stop: returned (2) at 0x00000080 ---
```

The call ring ends with `0x3ae8 -> 0x5bb4`; that stale call walks into the
handoff code and returns to `0x80`.  `0x80` is the address the real mask ROM
would have filled with the decompressed boot image.  The synthetic descriptor
is not executable, so this is the new frontier: **the real KaeP decompression
(or a stand-in that installs boot code at `0x80`)**.

```
.venv/bin/python recompiler/bootbank.py build 6600_mcu.bin \
  out/6600_bootbank_linked.bin
.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin \
  out/6600_bootregions_staging.bin --profile staging
.venv/bin/python recompiler/bootbringup.py build 6600_mcu.bin \
  out/6600_bootbank_bringup.bin \
  --regions out/6600_bootregions_staging.bin
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
  NK_LOW_ROM_IMAGE=out/6600_bootbank_bringup.bin \
  NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 \
  NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
  NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=1500000 NK_STOP_PC=0x80 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
  --rom-image out/6600_runtime.bin
tools/test_bootbringup.sh
```

### Round 16: page headers removed; the real kernel entry (2026-10-25)

**1. The page record is `0xec` header + `0x2000` payload, not a 6-byte tag.**
`pagestream.py build` keeps the first `0x20b0` bytes and everything from the
last page header (`0x6d9134`) on, and concatenates only the `0x2000`-byte
payloads in between.  The result is `0x1605ed8` bytes.  The kernel record
moves from raw `0x3268c0`/`0x326924` (header / page header) to stream
`0x31004c`/`0x3100b0` (header / text): the text now starts exactly at
`header + 0x64`, as the E32Image format requires.

**2. The export table becomes the layout oracle again.**  On the stream:

| image | exports | on a start | rate | best shift |
|---|---|---|---|---|
| kernel `0x100058e8` | 478 | 469 | **98.1%** | 0 |
| DLL `0x100039e5` | 1788 | 1757 | **98.3%** | 0 |
| DLL `0x100065a5` | 21 | 20 | 95.2% | 0 |
| reference Thumb DLL `0x101f6e00` | 5 | 5 | 100% | 0 |

`layout.py verify` now asserts the kernel ≥95%; the old drift test is a
control and reports `469/478` vs. a null of ~218 (2.15x) at every budget.
The residual `relayout.py` plan is 26 inserts / `0x34` bytes and is diagnostic
only — applying it would corrupt real instructions.

**3. The full ROMFS tree is intact.**  The 586-entry directory below the
kernel is **`\System\Libs`** (the boot image table; round 19 corrected the old
"Programs" label); `\System\Programs` is the 55-entry server list and Plugins
has 171 entries.  `romimage.py build` places 1,847 sections / 725 images at
their runtime addresses, including 174 E32Image files and 85 AIF/MBM
companions.  The `.r01`/`.wav` data area is still packed in FS order and
remains B3g work.

**4. The real kernel boots.**  `boot_kernel.c` now takes the flat-image entry
mode from the E32 entry bit (`0x50310054` → ARM), and `NK_KERNEL_VECTORS=1`
copies the kernel's first `0x64` bytes (the ARM vector table) to `0x0` and
`0xffff0000`.  The harness also maps `0x7ff00000..0x80000000` as the kernel
super page.  The run:

```
insns=924964 (ARM 924964 / Thumb 0), undefined=0, call fixups=0,
unbound IAT=0, recoveries=0
mmio: 2 reads, 18 writes
stop: pc left the image (5) at 0000000000
last pcs: ... 5038cee8 5038ceec 5039b2b0 5039b2b4 5039b2b8
```

The last call is `0x5039b2a0` → `0x5038ceb4` (a `memzero`), then
`pop {r4,lr}` / `bx lr` at `0x5039b2b8` with `lr=0`.  The SVC stack has
descended through the 1 MiB super-page window into the kernel `.data` region
(`sp ≈ 0x7fefffe4`), so the saved `lr` was overwritten.  This is the new
frontier: initialize the kernel stack/super-page/exception state, not the old
callmap.

**5. The linked boot bank is now trivial.**  `bootbank.py --stream` takes
stream `[0xb0, 0x100b0)` as linked 0..0x10000; all 15 switch tables measure
bias 0 and the loader descriptor is linked `0x80`.  The correct loader follows
a different call path from the old raw A/B/C view and stops at linked `0x624c`
in a board/CPU detection panic (`r5=0x0c0047fd`, `r0=0x10`) after 2,111
instructions.  The old 600k raw run used the B2 page header as code and is
kept only as a legacy regression.

```
.venv/bin/python recompiler/pagestream.py verify 6600_mcu.bin
.venv/bin/python recompiler/layout.py census 6600_mcu.bin
.venv/bin/python recompiler/bootbank.py verify 6600_mcu.bin --stream
tools/test_pagestream.sh

# real kernel entry (ARM, vector table installed)
NK_KERNEL_VECTORS=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=1000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime_paged.bin
```

### Round 17: the KaeP/PeaK container is unpacked; the handoff is executable (2026-10-25)

**1. The 12-byte header is a 10-byte header plus an overlapped record.**  The
bytes are ``"KaeP"`` (the little-endian constant ``0x5065614B``, i.e. the
Nokia "PeaK" marker), a `u32` record size `0x20`, and a `u32` image size
`0x1423dc`.  The 0x20-byte record starts at file **`0x12e`**, two bytes before
the nominal end of the size word: the high half of `0x001423dc` is also the
first halfword of the record's ARM branch stub.  The image starts at file
**`0x14e`**, where a clean ARM vector table begins (`ldr pc,[pc,#0x18]`), and
runs for `0x1423dc` bytes to `0x14252a`.  Image `+0x38` (file `0x186`) is real
ARM boot code (`ldr r1,[pc,#0x1a0]`), so this is a container payload, not a
checksum.

**2. `kaep.py unpack` preserves the boundary.**  It writes the 0x20-byte record
and the embedded image byte-for-byte (`out/6600_kaep_record.bin`,
`out/6600_kaep_image.bin`) and reports both SHA-256 values.  The record codec
used by the mask ROM is still undocumented; the tool does **not** invent a
plaintext descriptor.

**3. The handoff is now executable.**  The previous stand-in wrote a synthetic
descriptor at linked `0x80` and stopped there; removing `NK_STOP_PC` executed
the record bytes as an SWI (`SWI 0xf9ea00` at `0x80`).  `kaep.install` writes
`ldr pc,[pc,#-4]; .word 0x50310054` in the first two descriptor words.  The
loader only checks descriptor `+0/+4/+8` when its `0x40000000` flag is set,
which the boot-bank entry does not do, so the shared words are safe.  The
fields the loader actually consumes (`+0xc/+0x14/+0x1c/+0x20/...`) stay in
place.  `bootbringup.py` now calls this installer and no longer patches the
`0xfb8` parser.

**4. Result.**  The handoff run enters the kernel at `0x50310054`; with the
staging regions and a 1.5M budget it executes **1,499,999 ARM instructions**
with `undefined=0`, one recovered stale call, and ends in the kernel code range
(`0x5039...`) instead of the KaeP record.  The `0x3ae8 → 0x5bb4` stale call is
still present and is what reaches the handoff.  `tools/test_kaep.sh` and
`tools/test_bootbringup.sh` pin both the container extraction and the
kernel-entry run.

```
.venv/bin/python recompiler/kaep.py unpack 6600_mcu.bin \
  out/6600_kaep_record.bin out/6600_kaep_image.bin
.venv/bin/python recompiler/kaep.py install \
  out/6600_bootbank_linked.bin 6600_mcu.bin \
  out/6600_bootbank_kaep_install.bin
tools/test_kaep.sh
```

### Round 18: SWI is not a no-op — the EKA1 executive call gate (2026-10-25)

**1. The 924,964-instruction "kernel boot" was a runaway SWI fall-through.**
EUser.dll implements the user-side kernel API as a dense table of single-
instruction stubs:

```
50392b78  680080ef   svc #0x800068
50392b7c  6900c0ef   svc #0xc00069
50392b80  6a00c0ef   svc #0xc0006a
...
```

A branch into one stub (`0x50398b5c -> 0x50392b78`) should enter the kernel's
SVC vector.  The interpreter only logged `SWI` and continued, so execution
walked the **entire** table, fell into the real function after it at
`0x50392dcc`, and looped.  Each loop iteration allocated `0x420 + 0xc` bytes
in `0x50392e94` and leaked a further `0x84`, i.e. **`0x4b0` bytes of stack per
iteration**.  The `bx lr` with `lr=0` at `0x5039b2b8` is the eventual stack
underrun, not a kernel stack/super-page frontier.  The old number is kept only
as a regression baseline.

**2. The executive table is readable in the linked stream.**  The SVC vector
(`0x50310008`) enters the handler at `0x50314f30`; its bound literal at
`0x50314f7c` is `0x444`, i.e. **273** 32-bit service addresses at
`0x50314aec`.  All non-zero entries are inside the kernel text; four entries
are zero and represent unimplemented services:

| index | target | note |
|---|---|---|
| `0x68` | `0x5032541c` | used by the EUser boot path |
| `0x4d` | `0x503244e4` | `TRequestStatus` wait/poll |
| `0x8a`, `0x94`, `0x95`, `0x96` | `0` | unimplemented |

`recompiler/executive.py verify` pins the handler bound, the table size, the
four zero slots and the code-range membership.  `list --used` shows which
services EUser actually calls; `stubs` scans every image's SVC instructions
and maps them back to service addresses (EUser alone has 372 mapped stubs,
including `0x68` and `0x4d`).

**3. `NK_SWI_DIRECT` models the call gate.**  The interpreter now has an
explicit bring-up mode that dispatches `svc #N` to `table[N & 0x1ff]` with the
caller's LR still live, because an EKA1 stub is a **call gate**, not a normal
post-SWI continuation.  This is not the final CPU model: the real CPU enters
the SVC vector, saves CPSR in SPSR_svc, switches to SVC mode and returns
through `movs pc,lr`/`ldm ^` with banked registers.  That exception/banking
model is still missing.

**4. A second decoder bug: `sub sp, sp, #0x258` executed as MUL.**  The
multiply decoder matched any instruction whose bits 7-4 are `1001`
(`op4 == 9`).  Data-processing immediates also carry arbitrary bits there:
`0xe24ddf96` (`sub sp, sp, #0x258`) has `op4 = 9`, so it executed as a MUL
and wrote zero to SP.  The correct multiply/MLA space also requires bits
27-22 = `000000`; the decoder now checks
`(op & 0x0fc000f0) == 0x00000090`.  This is pinned in `interp_selftest`
("data-processing immediate with low nibble 9 is not a MUL").  It was the
source of the earlier `sp=0xffffffd4`, not a missing bank.

**5. Direct dispatch exposes two real blockers.**  The kernel's
scheduler/current-thread global `[0x800017d4]` is zero, because the E32 entry
is run without the mask-ROM/kernel startup that creates the initial thread.
The flat image also leaves IAT slot `0x5037d0e8` at `0xffffffff`; the
`--e32` loader binds imports, but `--rom-image` only places sections.  The
new IAT detector now treats `0xffffffff` (and any value outside a declared
code range) as an unbound import instead of branching to it.

With the minimal `NK_FAKE_THREAD` object and `NK_SWI_COMPLETE=0x4d` (the wait
request is completed immediately), the kernel runs **7,540 instructions**,
dispatches `0x68`/`0x4d`, and stops at the real next blocker:

```
--- stop: unbound import (IAT) (4) at 0x50336fe8 ---
insns=7540 (ARM 7540 / Thumb 0), undefined=0, unbound IAT=1, recoveries=0
regs: sp=0x802fff08 lr=0x50326178 pc=0x50336fec cpsr=0x800000d3
```

The IAT slot is `0x5037d0e8 = 0xffffffff`.  A **control** with
`NK_IAT_FAKE=1` returns 0 from the unbound import and runs 8,425
instructions, but `r4` becomes `0x00730072` (UTF-16-looking data) and the
indirect call at `0x5031eb98` jumps to 0; that is a symptom, not the
frontier.  The next tasks are (a) flat-image import binding, (b) the initial
thread/scheduler object, (c) banked registers/SPSR and a real SVC exception
(`NK_BANKED=1` now has the bank model and harness mode stacks, but the
kernel's own mode-stack setup still derives from missing boot state), and
(d) timer/interrupt completion so `NK_SWI_COMPLETE` is no longer needed.

```
.venv/bin/python recompiler/executive.py verify 6600_mcu.bin
.venv/bin/python recompiler/executive.py list 6600_mcu.bin --used
.venv/bin/python recompiler/executive.py stubs 6600_mcu.bin --image 0x100039e5
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
  NK_IAT_FAKE=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=20000 NK_MMIO_N=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_executive.sh
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

The bring-up stack now has these layers:

| layer | knob | purpose |
|---|---|---|
| bounded snap | `NK_CALL_INFER=1`, `NK_SNAP_WINDOW_ARM/THUMB` | snap a stale target to the nearest prologue; keep the window small enough that legitimate shared blocks stay exact |
| code-range guard | `nk_code_range_add`, loaded image text ranges | never accept a candidate outside kernel/DLL text; skip out-of-range direct calls under recovery |
| call-site map | `NK_CALLMAP=config/callmap-6600.txt` | pin one call site to its real callee, or to a host-side HLE helper (`div`, `mod`, `memzero`, bump `alloc`, `memcpy`) |
| missing-byte patches | `romimage.py build --patch config/patches-6600.txt` | restore bytes the packed image does not contain (the first one is the `pop {r4,r7,pc}` at `0x5039adcc` that the following packed table overwrote) |
| crash recovery | `NK_RECOVER=1` | snapshot the caller at every BL/BLX; if the callee faults, roll back, log the skipped call, return 0, and keep going |
| spin watchdog | `NK_SPIN=1`, `NK_SPIN_MAX=n` | a tiny loop that keeps revisiting one PC (bogus descriptor/length) is rolled back like a fault instead of burning the budget |
| code-space guard | `NK_CODE_ONLY=1` | a PC in RAM (or outside ROM/low alias/high vectors) is a corrupted return, not code |
| call ring / watch | `NK_WATCH=addr`, `NK_WATCH_LOG=n` | on a watched PC, print registers (including r4-r12 and the stack) and the last n BL/BLX sites with their arguments and resolved targets |
| entry/register injection | `NK_ENTRY=addr`, `NK_Rn=value` (n=0..12), `NK_SP`, `NK_LR` | reproduce a mask-ROM entry without writing a new harness; `NK_R11` is `fp`, `NK_R10` is `sl` |
| panic halt | `NK_STOP_SELFB=1` (default in the boot harness) | stop on `b .` with `NK_STOP_SELF_BRANCH` instead of treating the panic as a recoverable callee fault |
| handoff stop | `NK_STOP_PC=0x80` | stop exactly when the loader reaches the boot-image handoff, before executing the installed `ldr pc` trampoline |
| UPP boot stubs | `runtime/src/nokia_rt.c` | `0x58150422` bit `0x400`, `0x58120a08` non-zero, `0x41001400` bit 0: the two handshakes and RAM probe the loader performs |
| boot-bank alias | `NK_LOW_ROM=1` (`NK_LOW_ROM_SIZE=0x10000`) | copy the first ROM bank to address 0, register it as code, install the 16 high vectors and enable the interpreter's low-alias window |
| boot-region table | `NK_REGIONS=path[@addr]` (`recompiler/bootregions.py`) | install the mask-ROM bank table (`count` + 16-byte `{base,size,attr,linbase}` entries) the secondary loader expects in `r0/fp` |

Measured with `tools/test_boot_recover.sh` **after the Thumb fix**:

| mode | instructions | skips | stop |
|---|---|---|---|
| baseline `tools/build_boot_trace.sh` | 12 | — | `0x50314c16` (Thumb BL into ARM, no veneer) |
| assisted `NK_CALL_INFER=1` | 364 | — | `0x5038337c`, `lr=0`, no undefined |
| recovery + patch + callmap | **197** | **4** | entry returns to `0xdead0000` |
| recovery, **faithful image** (no patch) | 2,000,000 | 23 | long garbage path: missing `pop` at `0x5039adcc`, then `euser.dll`, then the `0x50389330` scan loop |

The faithful-image row is deliberately kept as a warning: a long run is not
progress.  With the spin watchdog it becomes a sequence of recoveries and a
budget stop, not a new frontier.

**Round 16 replaces this whole table.**  The raw rows above execute page-header
bytes.  The page-header-free stream gives:

| mode | instructions | skips/recoveries | stop |
|---|---|---|---|
| real kernel entry, `NK_KERNEL_VECTORS=1` | **924,964** | 0 / 0 | `0x5039b2b8` `bx lr` with `lr=0` → PC 0 (stack underrun) |
| real kernel entry, recovery on | 999,998 (budget) | 2 | SVC trace loop at `0x50392c50` |
| stream boot bank (`--stream`) | 2,111 | 2 | board/CPU detection panic `0x624c` |
| raw A/B/C boot bank (legacy) | 600,000 (budget) | 0 | descriptor lookup loop `0x1a1c` (page-header path) |

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

## Round 8 (2026-10-24): call ring, spin watchdog, and the real entry frontier

The interpreter grew three bring-up observability features that are now part of
the normal workflow:

- **`NK_WATCH=<addr>`** — when the PC first reaches `addr`, print the registers
  and a ring of the last `NK_WATCH_LOG` BL/BLX calls (call site, raw target,
  resolved target, caller/callee mode, r0-r3, sp).  This answers "how did we
  get here" without a 2-million-line trace.
- **`NK_SPIN=1` / `NK_SPIN_MAX=n`** — a tight-loop watchdog.  A descriptor scan
  with a bogus argument turns into a 2 GiB loop; after `n` visits to one PC the
  interpreter rolls the call back through the recovery frame instead of burning
  the budget.
- **`NK_CODE_ONLY=1`** (default in the boot harness) — a PC outside ROM
  (`0x50000000..0x51000000`), the low pre-MMU alias (`<3 MiB`) or the high
  vectors is treated as a corrupted return, not as code.  `NK_ENTRY=<addr>`
  overrides the start address (used to run the ROM vector table).

New findings:

1. **The old "2M instruction" frontier was a patch artifact.**  With the
   faithful image (no patch) and `NK_RECOVER=1`, the missing `pop` at
   `0x5039adcc` lets the Thumb helper run into ARM code, which is recovered and
   sends the trace down a long garbage path into `euser.dll` — including the
   `0x50389330` string loop.  With the bringup image (the same image plus
   `config/patches-6600.txt`) the entry completes in **197 instructions** and
   returns to the mask-ROM sentinel.  Always compare faithful and bringup runs;
   a long run is not automatically progress.
2. **The kernel entry performs real UPP initialisation.**  With the bringup
   image the third call (`0x50313522`, snapped to `0x50313518`) writes
   `0x5815053a`, `0x5815053c`, `0x5815056a`, `0x58150200`, `0x58150508` and
   `0x5815004a` (16-bit UPP registers), and the fifth call touches
   `0x58120308` / `0x59e00040`.  This is the first confirmed device-init code,
   not just logging.
3. **The kernel EXE UID is `0x1000007a`.**  `e32uid.h` defines
   `KExecutableImageUidValue=0x1000007a` and
   `KDynamicLibraryUidValue=0x10000079`; `wd2.py` and `romimage.py` had the two
   names swapped (the filter accepted both, so behaviour did not change).  The
   kernel is an EXE, which is why its entry is expected not to return.
4. **The ROM vector table is exception dispatch, not the reset path.**  Booting
   at `0x50000000` runs **16,396 ARM instructions**, enables the MMU/cache via
   CP15 c1, writes `0x580047e0`/`0x580047dc`, installs high vectors, and then
   branches to 0 (the vector page executed as data).  The mask ROM enters the
   kernel through the primary image header, so `0x50310054` remains the correct
   start.
5. **The second entry call needs kernel object state.**  It reaches
   `0x503364b0`, which dereferences a vtable from a stack argument and calls
   slot `+0x14`; with r0=0 the vtable is null and the call is recovered.  The
   old "unbound IAT" log line was a misclassification of
   `ldr pc,[r3,#0x14]`; the detector now requires `ldr pc,[ip]` with offset 0,
   so the recovery reports "pc left the image" instead.  The kernel's
   global/object state at `0x80000000` and the stack descriptor must be modelled
   before that call can run.

The two calls below the code base (`0x5030fbc6`, `0x5030807a`) are still the
main entry blockers.  They are not fixed by a bigger snap window: both targets
lie in the ROMFS directory block, and every nearby candidate in the final text
is mid-function.

## Next tasks

1. **Resolve the entry's two out-of-range calls (P0)** — `0x5030fbc6` and
   `0x5030807a` are below the kernel code base.  They land inside the ROMFS
   directory block; the +0x10000 hypothesis lands mid-function, so the mapping
   is not a simple relocation.  Round 14 added the page-tag grid
   (`recompiler/kaep.py`) but showed that despinning alone does not repair the
   export layout (104/478 → 67/478); a function-order/constraint solver or an
   explicit relocation table is still required.
2. **Model the kernel object state (P0/P1)** — `0x80000000` starts as zero and
   the entry's second call expects a vtable-backed object at `[0x80000000]`
   (slot `+0x14`).  Decide whether the mask-ROM stand-in must pre-fill the
   super page / kernel data or whether that call should be HLE'd for bring-up.
3. **Complete the relayout** — round 6 implements the padding pass
   (`recompiler/relayout.py`) and validates the entry pool and the
   `0x50312100` helper.  Round 7 shows the model is incomplete: the packed
   text and the export directory do not share a layout (only 17/478 exports
   land on a prologue, with a uniform bias distribution).  The next step is
   symbol-level recovery (a function-order/constraint solver), not more
   padding or a larger snap window.
4. **The header-less rodata blocks** — decide whether they belong to `.text`,
   to a RAM copy, or are debug data.  The kernel's block contains an
   interrupt-name/handler table but is not referenced by any literal in the
   reachable text.
5. **ROMFS data files (B3g)** — rebuild the packed FS order (directory →
   file offset) so the pictures, ringtones, fonts and resource files can be
   placed in the flat image and served by a future file HLE.
6. **Mask ROM stand-in** — CP15/MMU flat mapping, high vectors, SVC/IRQ state,
   and the initial super-page/kernel-data contents.  Round 14's linear
   boot-region profile (`bootregions.py --profile linear`) passes the old
   `0xc58` KaeP lookup and stops in the page-table fill at `0x2fe4`; the
   `linbase` base-vs-page-mask semantics and the page-table destination are
   the concrete next steps.  Round 17 unpacks the KaeP/PeaK container and makes
   the `0x80` handoff executable, but the mask ROM's codec for the 0x20-byte
   PeaK record is still open.
7. **MMIO/display** — the entry already writes UPP registers around
   `0x58150000` / `0x58150500`; the next useful milestone is a real UPP
   display/timer/keypad register table rather than logging every access.

The phased plan, task board and acceptance criteria are in
[`PROGRESS.md`](PROGRESS.md).

---

## Round 21 (2026-10-25): EUser import ABI, RTC driver rodata, and KERN-NO-SESSION

> **Round 22 supersedes sections 3–5 below.**  The "RTC rodata block" is a
> nested second E32Image, and the ECons/KERN-NO-SESSION stop was the RTC
> driver's misbound `operator new` entering EUser's RTest console path.  With
> the round-22 fixups the run reaches 27,470 instructions; see the Round 22
> section above.

Round 20 installed the thread → process → `CObjectIx` graph and reported a
5,575,900-instruction run ending at `pc=0` with `sp=0`.  Round 21 shows that
run was **not** a second-thread stack frontier: it was the panic printer
looping on four EUser imports whose slots resolve to a function with the wrong
ABI, plus an object-index element that returned a bare pointer where the
caller expects a `TDesC8` descriptor.

### 1. The four EUser import rebinds

The kernel was linked against an EUser `.def` revision whose ordinal order
differs from the EUser DLL in this ROM.  The flat-image loader already accepts
`NK_IMPORTMAP` overrides for holes; it now also applies an override to a slot
that already holds a code address.  `config/imports-b7e-6600.txt` pins:

| slot | ordinal | stored target | call site wants | rebind |
|---|---|---|---|---|
| `0x503b391c` | 98 | `0x5038e594` array accessor | `TDesC16::AtC` for the panic category `TPtrC16` | `0x50388474` |
| `0x503b4d1c` | 1378 | `0x50388104` 3-arg `TPtr16` ctor | 2-arg ctor `(buf=0, max=0)` | `0x503880ec` |
| `0x503b4b9c` | 1282 | `0x50388a2c` string copy | `TBuf16(int)` with `r1=8` | `0x50388254` |
| `0x503b3b70` | 247 | `0x50388408` descriptor copy | `TDes16::Copy(buf,len)`, `r2=0` | `0x503883c0` |

The confirmation-only map (`config/imports-6600.txt`) stays at one entry
(ELocl ordinal 20).  These four rebinds are explicit bring-up aids, not
recovered ROM state.

### 2. `CObjectIx` elements are descriptors

`0x50380270` calls the array vtable (`[array+0x14]`) to fill a result at `sp`,
then calls `TDesC8::Ptr` (`0x5038891c`).  The round-20 stub wrote only the
object pointer, so `Ptr()` read the pointer as a length/type word and panicked
USER 19.  The stub now writes `{0x10000004, object_ptr}` (a `TPtrC8`), and the
handle path returns the harness `B7E_THREAD` object (with a vtable at
`0x80003040`) rather than the live scheduler block at `0x802ffd00`, whose
word 0 is not a vtable.

### 3. RTC physical-device-driver rodata

The RTC PDD is uid3 `0x100000d8` (header stream `0x33e340`, code
`0x5033e2f4`, text `0xa9c`).  Its record has a **0x279c-byte header-less
block** after `.text`.  That block is real runtime data: the driver's vtable is
at `0x503413e8`, its `+0x18` slot is `0x5033ef98`, and the strings
`"RTC"`, `"RTC, line number:"` and `"RTC driver not created!"` live there.
Without the block the constructor read a zero vtable and left the image.

`romimage.py --place-rodata` places a driver image's header-less block at
`code + text_size` when it ends before the next packed header (and lets the
declared `.edata` win on the first-word overlap).  The baseline build is still
725 images / 1,847 sections; `--place-rodata` is 726 / 2,335 and
`tools/build_rom_image.sh` now uses it.  This is the first header-less block
that **must** be placed at run time; the kernel's own 0x135c block still
overlaps its `.data` and is skipped.

### 4. Allocator and HAL stand-ins

The RTC constructor allocates 0x124 bytes with `User::AllocZ`, which reaches
`RHeap::Alloc` at `0x5038e2ec` with a null current-thread heap.  The harness
serves that entry from its bump heap:

```
NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000
```

The constructor also calls `[0x800003ac]->vtable[0x108]` before the loader
registers the real HAL object.  A stand-in HAL object at `0x80003a00` with a
vtable at `0x80003c00` returns 0 for `r1=1` (success) and, from round 22, a
dereferenceable channel object for `r1=0` (the old integer 1 crashed when the
RTC driver read its vtable).

### 5. The new frontier

The RTC driver constructor completes.  The kernel next loads **Econs.dll**
(uid3 `0x100039e7`, code `0x5079d244`); the loader asks for a file-server
session and the kernel panics **KERN-NO-SESSION 22** (category
`0x50338230`, reason `0x16`).  The run now stops in the panic printer at
`0x50312b88` after **8,655 instructions**, with **0 undefined, 0 call
fixups, 0 unbound IAT, 0 recoveries**.

The next task is the ROMFS/E32 file-service path (or an explicit HLE that
returns the already-placed ROM image), not a stack/exception model.

> **Round 22:** the ECons load was the misbound RTC allocator/`RTest` path, so
> no file server was actually needed here.  With the round-22 fixups the
> extension completes and the run stops at the kernel timer/DFC init
> (`0x5031f3a8`, `"IrqTimer0"`, `[0x80000b5c] == 0xff`, PLAT 21) after 27,470
> instructions.

### Reproduce

```sh
tools/build_rom_image.sh       # now includes --place-rodata
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=8000000 NK_B7E=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_b7e.sh
```

`NK_WATCH_MEM=r7:0x40` (with `NK_WATCH=pc`) dumps guest memory at a register
when the watch fires; it was added to identify the zero RTC vtable and the
panic category descriptor.

### Diagnostic: the last SVCs before KERN-NO-SESSION

With `NK_SWI_LOG=64` the tail before the panic is:

```
SWI 0x52 at 0x50392b1c -> service 0x503245bc
  (r0=0x64 r1=0x14  r2=0x14     r3=0x503a9fcc)
SWI 0x52 at 0x50392b1c -> service 0x503245bc
  (r0=0x64 r1=0x64  r2=0x503b2f24 r3=0x64)
SWI 0x72 at 0x50392b9c -> trap push (0x503187c8)
SWI 0x6c at 0x50392b88 -> current thread heap (0x503187b8)
SWI 0xc00076 at 0x50392bb0 -> Kernel::Panic (0x5032557c)
  (r0=0x16 ...)
```

`0x503245bc` loads a global session/server object and calls `0x50336abc`
with it; a null object here is the direct source of the "KERN-NO-SESSION"
panic.  The next round should model that service (and the file open/read path)
rather than treating the panic as an import or stack problem.

## Round 25 (2026-10-25): real CTrapCleanup, process construction, vtable ABI

Round 24's `USER-CBase 69` is the user-side startup that the direct E32 entry
skips.  Round 25 does not paper over it with a no-op handler: `NK_TRAPCLEAN=1`
builds, per published thread, a real `TCleanupTrapHandler` whose vtable is
EUser's own `0x503b3518` (`Trap/UnTrap/Leave` = `0x50383c38/40/48`), a
`CCleanup` (`0x503b36a4`, `iBase/iTop/iNext`), eight `TCleanupStackItem`s and
one TRAP level marker.  The handler is published at `SThread::iTrapHandler`
(`+0x3c`); `iFrame` (`+0x38`) stays zero until a guest `TTrap::Trap` pushes a
frame.  `CleanupStack::PushL` now executes the real level/pop code.

Four more call-site ABI mismatches surfaced and are pinned by argument shape:

| slot | kernel call | ROM value | real implementation |
|---|---|---|---|
| `0x503b42c8` | `(dest TDes16*, src TDesC16*)` | `HBufC16::NewLC(int)` | `TDes16::Copy(TDesC16 const&)` `0x50388408` |
| `0x503b3e28` | `(CObjectCon*, TInt&, name, TBuf<128>&)` | descriptor format | `CObjectCon::FindByName` `0x50385650` |
| `0x503b379c` | `DProcess::New` size `0xdc` | 3-descriptor parser, returns 0 | `User::Alloc` `0x503988f0` |
| `0x503b4bec` | `(this+0x44, maxLength=8)` | 20-byte object ctor | `TBufBase8(int)` `0x50388b24` |

The initial `DProcess` `0x806008b8` is now really allocated and constructed.
The run reaches **125,864 instructions, 0 undefined, 0 unbound IAT, 0
recoveries, 22 call fixups** (30 overrides in
`config/imports-r25-6600.txt`).  It stops while closing that process through
DProcess vtable `+0xc`: kernel import slot `0x503b4410` resolves to EUser index
799, which this ROM exports as the object-close panic helper `0x5039e328`, so
the stop is **KERN-NO-SESSION 52**.  Rebinding that slot to the `RHandleBase`
close wrapper only moves the stop to **E32USER-CBase 44**.

The next task is therefore a **symbol-level DProcess/DObject vtable ABI map**.
Several slots in one vtable (`+0xc`, `+0x10`, `+0x18`, `+0x20`) target
different EUser ordinals whose ROM export indices do not match the kernel's
`.def`; using ROM index 799 directly is wrong even though the slot address is
valid.  The cleanup handler and level marker are real; only the initial
`iFrame`/leave context still needs the scheduler or mask-ROM startup TRAP.

Acceptance: `tools/test_round25.sh`.
