/*
 * boot_kernel — native boot/trace harness for the 6600 interpreter.
 *
 *   out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin
 *   out/boot_kernel 6600_mcu.bin - --e32 0x3513d0     # any EKA1 ROM image
 *   out/boot_kernel 6600_mcu.bin - --rom-image out/6600_runtime.bin
 *
 * `--rom-image` maps a flat runtime image produced by
 * `recompiler/romimage.py build` at 0x50000000, copies every image's .data to
 * its RAM base, zeroes .bss, and starts at the kernel entry.  It needs no
 * packed-record parsing and is the preferred path once the image exists.
 *
 * Maps the EKA1 ROM at its link address, allocates the kernel RAM window, loads
 * either the carved kernel or an E32Image described by a TRomImageHeader, and
 * executes it with the ARMv4T interpreter.  This is the bring-up engine: it
 * reports the first undefined instruction, the first MMIO access and the last
 * PCs before the frontier instead of dying inside Unicorn.
 *
 * Environment:
 *   NK_BUDGET=2000000       instruction budget
 *   NK_TRACE=1              print every executed instruction (first NK_TRACE_N)
 *   NK_TRACE_N=64           trace window size
 *   NK_TRACE_FROM=0x...     only trace PCs >= this address
 *   NK_TRACE_AFTER=n        only start tracing after n instructions
 *   NK_CALLS=1              print the interpreter shadow call stack at stop
 *   NK_INFER=0|1            mode inference on an undefined instruction (default 1)
 *   NK_CALL_INFER=1         repair Thumb<->ARM mode at BL/BLX call sites
 *   NK_CALL_POLICY=0|1|2|3  how to repair a call target:
 *                             0 snap back to the nearest prologue (default)
 *                             1 execute the target as ARM (round down to 4)
 *                             2 snap forward to the next prologue
 *                             3 back, then forward, then ARM-at-target
 *   NK_SNAP_WINDOW=n        how far back a call fixup looks for the callee's
 *                           prologue (default 0x40; the packed image's
 *                           cumulative veneer bias can exceed 0x200)
 *   NK_SNAP_WINDOW_THUMB=n  override for Thumb callers (default: above)
 *   NK_SNAP_WINDOW_ARM=n    override for ARM callers (default: above)
 *   NK_FIXUP_LOG=n          log the first n call fixups (default 16)
 *   NK_CALLMAP=path         call-site fixups / HLE stubs (see config/callmap-rtc-6600.txt)
 *   NK_RECOVER=1            roll back a broken callee and continue (bring-up)
 *   NK_RECOVER_MAX=n        stop after n skipped calls (default 256)
 *   NK_RECOVER_LOG=n        log the first n skips (default 16)
 *   NK_SNAP_NOFAST=1        ignore a leaf entry at the raw target and always
 *                           snap to the nearest prologue
 *   NK_HLE_HEAP=0x...       bump heap for NK_HLE_ALLOC (default: above the
 *                           allocated RAM window, at least 0x80400000)
 *   NK_IAT_FAKE=1           unresolved imports return 0 instead of stopping
 *   NK_IAT_LOG=n            log the first n unbound imports (default 16)
 *   NK_IMPORTMAP=path       bind export-table holes from a file
 *                           (`<slot> <target|zero>`, see config/imports-6600.txt)
 *   NK_ALLOC_HLE=1          serve EUser RHeap::Alloc calls from a bump heap
 *                           (experimental bring-up for the missing current-thread
 *                           heap; see NK_ALLOC_* below)
 *   NK_ALLOC_PC=0x...       guest RHeap::Alloc entry (default 0x50380270)
 *   NK_REALLOC_PC=0x...     guest RHeap1::ReAlloc1 entry (default 0x5039c630;
 *                           bump blocks are copied by the harness)
 *   NK_FREE_PC=0x...        guest RHeap::Free entry (default 0x5038e3d8;
 *                           bump blocks are a no-op, real blocks fall through)
 *   NK_ALLOC_BASE/END=0x... bump heap range (default: the harness HLE heap).
 *                           Each block has an 8-byte header (payload size +
 *                           'HLEH'), so pointers returned to the guest are
 *                           alloc_base+8 .. alloc_cur.
 *   NK_ALLOC_LOG=n          log the first n HLE allocations (default 8)
 *   NK_ENTRY_ARM=1          force ARM state (the flat image now takes the mode
 *                           from the E32 entry bit; the real kernel is ARM)
 *   NK_ENTRY_THUMB=1        force Thumb state
 *   NK_KERNEL_VECTORS=1     copy the kernel text's first 0x64 bytes (its ARM
 *                           exception vector table) to 0x0 and 0xffff0000
 *   NK_NO_SUPER_PAGE=1      do not map the 0x7ff00000..0x80000000 kernel
 *                           super-page window (control run)
 *   NK_SUPERPAGE=1          model the 6600's boot super page at 0x40000000:
 *                           iTotalRamSize, iRamBootData and an SRamBank list
 *                           (base+size pairs, largest power-of-two blocks)
 *                           plus the machine-config area at +0x800.  The mask
 *                           ROM normally fills this before the E32 entry.
 *   NK_BOOTTABLE_RAM=addr   copy the 64 KiB ROMFS directory block at
 *                           0x50300000 to addr and repoint the ROM header's
 *                           primary/secondary/variant/extension TRomEntry
 *                           pointers (round 27 experiment: a writable boot
 *                           table for the loader; not required after the
 *                           K=1361 import exception)
 *   NK_BOOT_HANDOFF=1       install the mask-ROM super-page hand-off
 *                           ([0x400000c4/c8/cc/d0] = primary/variant/
 *                           extension/kernel TRomEntry pointers).  Without it
 *                           the kernel reads address 4 as its own image
 *                           header and the initial thread fields are garbage.
 *   NK_PRIMARY_RAM=addr      copy the 64 KiB ROMFS directory block to RAM and
 *                           repoint only iPrimaryFile (0x5000009c); the
 *                           initial TStack object is iPrimaryFile+iStackSize.
 *   NK_SYSTEM_TIME=1        install the mask ROM's initial system TTime at
 *                           [0x50000084] (64-bit), sourced from the
 *                           TRomHeader iTime at 0x50000080.  The kernel's
 *                           system-time init reads that hand-off slot, not
 *                           the header word.
 *   NK_HAL_TIMER_HZ=n        with NK_B7E: make the fake HAL's vtable+0x5c
 *                           (timer frequency) return n.  4 is the round-27
 *                           probe value, not recovered firmware state.
 *   NK_BOOT_TIME=1           replace the kernel's computed system time with
 *                           the ROM header iTime (0x50000080/84) after the
 *                           store.  Diagnostic: the TTime conversion is the
 *                           round-28 frontier; this hook alone does not fix
 *                           the following TTime::SecondsFrom call.
 *   NK_SUPERPAGE_BASE=0x... override the super page address (default 0x40000000)
 *   NK_SUPERPAGE_TOTAL=0x... override iTotalRamSize (default: mapped RAM size)
 *   NK_ENTRY=0x...          override the entry address (e.g. 0x50000000 to
 *                           run the ROM's exception-vector code)
 *   NK_WATCH=0x...          dump registers + the call ring when PC hits this
 *   NK_WATCH_HITS=n         how many times to report (default 1)
 *   NK_WATCH_LOG=n          how many recent calls to print (default 16)
 *   NK_WATCH_MEM=rN[:len]   at a watch hit, dump len bytes at rN (default 0x40)
 *   NK_WRITE_WATCH=0x...    log stores to this guest word with the writing PC
 *                           (fourth watch slot; coexists with all live hooks)
 *   NK_WRITE_WATCH_MAX=n    stop reporting after n stores (default 8)
 *   NK_SPIN=1               enable the tight-loop watchdog
 *   NK_SPIN_MAX=n           visits to one PC before it is a spin (default 20000)
 *   NK_CODE_ONLY=0|1        reject a PC outside ROM/low-RAM/high vectors
 *                           (default 1 in this harness)
 *   NK_KERNEL_CODE=0x...    where to copy the kernel blob (default 0x50310000)
 *   NK_SP=0x...             initial stack pointer (default 0x80300000)
 *   NK_R0=0x... NK_R1=0x... NK_R2=0x...
 *                           initial argument registers (the mask ROM passes
 *                           the ROM header in r0 and the super page in r1)
 *   NK_LR=0x...             initial link register (default 0xdead0000, the
 *                           mask-ROM return sentinel)
 *   NK_STOP_PC=0x...        stop when PC reaches this address (default NK_LR)
 *   NK_STOP_ON_SWI=1        stop at the first SWI
 *   NK_SWI_DIRECT=1         EKA1 executive call gate: dispatch `svc #N` to
 *                           table[N & 0x1ff] with the caller's LR still live
 *                           (bring-up model; not the full SVC exception)
 *   NK_SWI_TABLE=0x...      kernel 32-bit service table (default 0x50314aec)
 *   NK_SWI_COMPLETE=0x4d    comma-separated service indices modelled as
 *                           "request already complete": write 0 to [r0]
 *   NK_SWI_LOG=n            log the first n direct SWI dispatches (default 16)
 *   NK_NESTED_SVC=1         keep the caller LR for an SVC entered from SVC
 *                           mode; fixes the 0x50314f78 pre-handler self-loop
 *                           (round 74, off by default)
 *   NK_FAKE_THREAD=1        install the round-18/19 minimal current-thread
 *                           object at [0x800017d4] (legacy stand-in; the
 *                           process+0x38 field was misread as a heap)
 *   NK_B7E=1                install thread -> process -> CObjectIx -> array
 *                           when the kernel publishes [0x800017d4].
 *                           NK_B7E_HEAP/NK_B7E_SIZE
 *                           set the guest bump allocator window.
 *   NK_EXT_STUB=1           give an extension image with no export table a
 *                           synthetic export 1 (HAL-like object); needed by
 *                           the nested rtc.dll image (round 22)
 *   NK_TRAPCLEAN=1          with NK_B7E: build a real CTrapCleanup graph per
 *                           published thread (TCleanupTrapHandler vtable ->
 *                           EUser Trap/UnTrap/Leave, CCleanup + one level
 *                           marker) and publish it at thread+0x3c.  This is
 *                           the user-side startup that the direct E32 entry
 *                           skips; without it CleanupStack::PushL panics 69.
 *   NK_B7E_LIVE=1           keep live kernel objects: only fill a thread's
 *                           +0x18 DProcess / +0x5c request semaphore / +0x64
 *                           CObjectIx when the kernel has none.  Also enables
 *                           status-completion scheduler wakes, low exception
 *                           stacks, the HAL object-3 Request(0xd) stand-in and
 *                           the live-mode HAL map stub.  Round 34.
 *   NK_BANKED=1             enable the banked r13/r14, FIQ r8-r12 and SPSR
 *                           model; the harness presets per-mode stacks
 *   NK_BANK_LOG=1           log every banked CPSR mode switch
 *   NK_TIMER=1              enable the instruction-driven UPP timer/ICU model
 *                           (implies NK_BANKED; guest writes arm the timer)
 *   NK_TIMER_LOG=n          log the first n timer register writes/expiries
 *   NK_IRQ_LOG=n            log the first n IRQ exception entries
 *   NK_TIMERQ=1             inject the mask-ROM/HAL timer-queue object at
 *                           [0x80001c34] at 0x5031ef40 (after the first timer
 *                           IRQ wakes Kern::Init1).  The default ("override")
 *                           calls the kernel's own constructor (export 451,
 *                           0x5032aff8) and substitutes a zero-return HAL
 *                           tick getter for the pure-virtual vtable slot;
 *                           NK_TIMERQ_MODE=ctor keeps the abstract base vtable
 *                           and NK_TIMERQ_MODE=stub installs an all-zero
 *                           vtable.  NK_TIMERQ_ADDR=0x... selects the guest
 *                           object page (default 0x80500000).  This is a
 *                           boot-state model, not recovered firmware.
 *   NK_CPSR=0x...           override the initial CPSR.  The mask-ROM IRQ
 *                           hand-off needs I=0 (0x40000053 for SVC/ARM);
 *                           the default 0x400000d3 keeps IRQs masked.
 *   NK_SCHED=1              model WaitForAnyRequest with a NULL-thread switch
 *                           (round 33).  NK_SCHED_LOG=n limits the scheduler
 *                           log; NK_SCHED_DEFER=1 preempts only after the
 *                           start hand-off returns at 0x5033130c (round 35).
 *   NK_SCHED_FAKE=1         pre-create a scheduler slot at 0x80004600 and
 *                           point [0x80000400] at it; NK_SCHED_ENTRY is its
 *                           first PC and NK_SCHED_STACK its stack (round 78).
 *   NK_SCHED_R0=0x...       initial r0 for that fake thread (round 78).
 *   NK_SCHED_STACK_FILL=0x. fill the fake thread stack with this word
 *                           instead of zero (round 81).
 *   NK_SCHED_STACK_SIZE=n   mapped fake stack size (default 0x2000)
 *   NK_SCHED_STACK_EXTRA=n  extra mapped/filled words above the initial sp,
 *                           for epilogues whose frame sits above it (round 82)
 *   NK_SCHED_EXIT=1         when the fake thread returns to 0xdead0000,
 *                           retire it and resume the supervisor (round 82).
 *   NK_SUPERVISOR_OBJECT_FIX=1  at 0x503ce696, write the B7e vtable into
 *                           [this+0x14] before EUser reads it (round 86).
 *   NK_SCHED_AUTOCOMPLETE=1  after a switch, complete the blocked thread's
 *                           status and make it runnable again (round 79).
 *   NK_MEMCOPY_CLAMP=1      at Mem::Copy 0x5038cfe0, zero copies whose
 *                           length > 0x100000 or src/dst is outside
 *                           0x50000000..0x80a00000 (round 80; uses pc_hook,
 *                           so NK_TIMERQ must be off).
 *   NK_E32_SECTIONS=1       with --e32: place data/exports/dllref at their
 *                           runtime addresses (finds the packed export run)
 *   NK_E32_HDR=0x64         serialized EKA1 image header size (code offset)
 *   NK_TEXT_SHIFT=n         diagnostic: load the text n bytes later in the
 *                           packed record (default 0)
 *   NK_LOW_ROM=1            copy the boot bank to address 0 (the loader's jump
 *                           tables and hand-off are 0-based)
 *   NK_LOW_ROM_IMAGE=path   with NK_LOW_ROM: map this 64 KiB *linked* view
 *                           instead of the raw flash bytes (recompiler/
 *                           bootbank.py build); start at linked 0x30c
 *   NK_REGIONS=path[@addr]  install a mask-ROM boot-region table (count +
 *                           0x10-byte segments) at
 *                           addr (default 0x80000000) and report it; pass the
 *                           same addr in NK_R11 to reproduce the mask-ROM
 *                           hand-off
 *   NK_RAM_EXTRA=n          allocate n extra bytes of RAM above the 3 MiB
 *                           kernel-data window (the linear boot-region profile
 *                           uses NK_RAM_EXTRA=0x300000 for a 6 MiB bank)
 *   NK_MAP_LCD=1            map the LCD controller 0x59200000 and the
 *                           0x59800000 framebuffer (ecust.dll's display base)
 *   NK_FB_MBM=1             decode SplashScreen.mbm's first bitmap from guest
 *                           memory into a guest RGB565 source buffer at
 *                           0x80800000 (round 61); pair with a guest
 *                           EUser Mem::Copy to write the real Nokia logo frame
 *   NK_FB_SRC=1             fill that source buffer with 16bpp white instead
 *                           (round 58 splash-background control)
 *   NK_START_HLE=1          complete the thread-start TRequestStatus in r3
 *                           from the bring-up DThread vtable+0x20 slot (round
 *                           62).  Without it SplashScreen spins in the
 *                           EUser wait-any-request poll loop.
 *   NK_USER_SVC_KERNEL=1|2  clear bit 23 on EUser SVC stubs so the kernel
 *                           service table is dispatched instead of the missing
 *                           mask-ROM user-SVC handler.  Mode 1 patches only
 *                           SVC 0x76 (StartThread); mode 2 patches all nine
 *                           stubs in the 0x50392b80 table.
 *   NK_APP_IMPORTMAP=path   app-side EUser import rebinds, applied after the
 *                           flat image load.  Use this instead of
 *                           NK_IMPORTMAP for direct app entries: the kernel
 *                           map patches shared EUser export slots.
 *   NK_DUMP=a:l[,a:l...]    append guest memory ranges to NK_DUMP_FILE at the
 *                           end of the run (default out/memdump.bin)
 *   NK_POKE=a:v[,a:v...]    write 32-bit values to guest addresses before the
 *                           run (bring-up experiments; logged)
 *   NK_PATCH=a:w[,a:w...]   patch 32-bit guest code words before the run
 *                           (bring-up experiments; logged)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nokia_rt.h"
#include "nokia_interp.h"

static uint32_t u32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint8_t* read_file(const char* path, long* len) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t* p = (uint8_t*)malloc((size_t)*len);
    if (!p) { fclose(f); return NULL; }
    if (fread(p, 1, (size_t)*len, f) != (size_t)*len) { fclose(f); free(p); return NULL; }
    fclose(f);
    return p;
}

static const char* env_str(const char* name, const char* def) {
    const char* s = getenv(name);
    return (s && *s) ? s : def;
}

static unsigned long env_ulong(const char* name, unsigned long def) {
    const char* s = getenv(name);
    return s ? strtoul(s, NULL, 0) : def;
}

/* Round 61: decode the first bitmap of the ROM MBM at SplashScreen.mbm and
 * materialise it as 16bpp RGB565 in a guest buffer.  This is a bring-up HLE
 * for the blocked FbsServ/CFbsBitmap loader (rounds 55-60): the compressed
 * bytes are read from guest memory, so the picture is the firmware resource,
 * not a host demo.  The framebuffer write itself is still done by guest
 * EUser Mem::Copy (0x5038cfe0), exactly like the round-58 white frame. */
typedef struct mbm_frame_info {
    unsigned width, height, pixels, nonwhite;
    unsigned x0, y0, x1, y1;
    uint32_t fnv;
} mbm_frame_info;

static void mbm_put_pixel(nk_cpu_t* c, uint32_t dst, unsigned index, uint8_t v,
                          mbm_frame_info* info) {
    /* The ROM resource's 8bpp run payload is an anti-aliasing grey ramp
     * (0xff white .. 0x00 black).  Expand it to RGB565 grey. */
    uint16_t px = (uint16_t)((((uint32_t)v >> 3) << 11) |
                             (((uint32_t)v >> 2) << 5) |
                             ((uint32_t)v >> 3));
    nk_w16(c, dst + index * 2u, px);
    info->fnv = (info->fnv ^ (px & 0xffu)) * 16777619u;
    info->fnv = (info->fnv ^ (px >> 8)) * 16777619u;
    if (px != 0xffffu) {
        unsigned x = index % info->width;
        unsigned y = index / info->width;
        if (!info->nonwhite) {
            info->x0 = info->x1 = x;
            info->y0 = info->y1 = y;
        } else {
            if (x < info->x0) info->x0 = x;
            if (x > info->x1) info->x1 = x;
            if (y < info->y0) info->y0 = y;
            if (y > info->y1) info->y1 = y;
        }
        info->nonwhite++;
    }
}

static int mbm_first_frame_to_rgb565(nk_cpu_t* c, uint32_t mbm, uint32_t mbm_size,
                                     uint32_t dst, uint32_t dst_cap,
                                     mbm_frame_info* info) {
    memset(info, 0, sizeof(*info));
    info->fnv = 2166136261u;
    if (nk_r32(c, mbm) != 0x10000041u) return -1;
    uint32_t count = nk_r32(c, mbm + 4);
    uint32_t off0  = nk_r32(c, mbm + 8);
    uint32_t off1  = (count > 1) ? nk_r32(c, mbm + 0xc) : mbm_size;
    if (!count || off0 + 0x34u > mbm_size) return -2;

    /* ROM bitmaps are stored as in-memory CBitwiseBitmaps: five header words,
     * then SEpocBitmapHeader at +0x14 (same layout eka2l1's mbm loader uses). */
    uint32_t h = mbm + off0 + 5u * 4u;
    uint32_t size     = nk_r32(c, h + 0x00);
    uint32_t hdrlen   = nk_r32(c, h + 0x04);
    uint32_t width    = nk_r32(c, h + 0x08);
    uint32_t height   = nk_r32(c, h + 0x0c);
    uint32_t bpp      = nk_r32(c, h + 0x18);
    uint32_t palette  = nk_r32(c, h + 0x20);
    uint32_t compress = nk_r32(c, h + 0x24);
    if (!width || !height || width > 4096u || height > 4096u) return -3;
    if (bpp != 8u || compress != 1u) return -4;
    if (size <= hdrlen || size > mbm_size || off1 > mbm_size) return -5;
    if (palette != 0u) return -6;   /* grey ramp resource: no CLUT */

    uint32_t n = width * height;
    if (n > dst_cap / 2u) return -7;

    /* The payload is placed from the *next* bitmap's offset so the ROM's
     * alignment padding is included; eka2l1's bitmap_data_offset does the
     * same.  For index 0 this resolves to MBM+0x54. */
    uint32_t data_size = size - hdrlen;
    if (off1 < data_size) return -8;
    uint32_t data_off = (off1 - data_size) & ~3u;
    if (data_off < (h - mbm) + hdrlen || data_off >= mbm_size) return -9;

    info->width = width;
    info->height = height;
    info->x0 = width; info->y0 = height;

    uint32_t pos = mbm + data_off, out = 0;
    while (out < n && pos < mbm + mbm_size) {
        uint8_t ctl = nk_r8(c, pos++);
        if (ctl < 0x80u) {
            if (pos >= mbm + mbm_size) return -10;
            uint8_t v = nk_r8(c, pos++);
            unsigned run = (unsigned)ctl + 1u;
            while (run-- && out < n) mbm_put_pixel(c, dst, out++, v, info);
        } else {
            unsigned run = 256u - (unsigned)ctl;
            while (run-- && out < n) {
                if (pos >= mbm + mbm_size) return -11;
                mbm_put_pixel(c, dst, out++, nk_r8(c, pos++), info);
            }
        }
    }
    info->pixels = out;
    return out == n ? 0 : -12;
}

/* Load call-site fixups: `<call_pc> <target> <A|T>` per line, '#' comments.
 * This is how the bring-up pins a stale packed-image BL target to the real
 * callee without changing the global snap heuristic. */
static void load_callmap(nk_interp_t* ip, const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open callmap %s\n", path); return; }
    char line[256];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '\n' || *p == '#' ||
            (p[0] == '/' && p[1] == '/')) continue;
        char* end = NULL;
        unsigned long pc = strtoul(p, &end, 0);
        if (end == p) continue;
        p = end;
        unsigned long target = strtoul(p, &end, 0);
        if (end == p) continue;
        p = end;
        while (*p == ' ' || *p == '\t') p++;
        int thumb = (*p == 'T' || *p == 't' || *p == '1');
        if (nk_callmap_add(ip, (uint32_t)pc, (uint32_t)target, thumb)) n++;
    }
    fclose(f);
    printf("callmap %s: %d call-site fixups\n", path, n);
}

/* The 6600 kernel's fixed bootstrap page is at 0x40000000, with the machine
 * configuration (TMachineConfig) at +0x800.  EKA1's mask ROM fills the super
 * page before jumping to the E32 entry: iTotalRamSize and iRamBootData (an
 * SRamBank {base,size} list).  Jumping straight to the entry leaves the whole
 * page as unmapped MMIO, so every read returns 0 and the RAM allocator sees
 * no banks.  This is a model of that bootstrap hand-off, not a firmware
 * patch.  The bank list is split into power-of-two blocks because the
 * allocator derives its zone shift from the smallest bank.
 */
static void install_super_page(nk_cpu_t* c, uint32_t base, uint32_t total) {
    if (nk_alloc_ram(c, base, NK_PAGE_SIZE) != 0) return;
    uint32_t list = base + 0x100;
    uint32_t off = 0, remain = total, n = 0;
    uint32_t blocks[32];
    while (remain && n < 30) {
        uint32_t chunk = 1u << (31 - (uint32_t)__builtin_clz(remain));
        if (chunk > remain) chunk = remain;
        blocks[n++] = chunk;
        off += chunk;
        remain -= chunk;
    }
    if (n == 1) {                    /* the allocator wants >= 2 banks */
        blocks[n++] = blocks[0] >> 1;
        blocks[0] >>= 1;
    }
    off = 0;
    for (uint32_t i = 0; i < n; i++) {
        nk_w32(c, list + 8 * i, off);
        nk_w32(c, list + 8 * i + 4, blocks[i]);
        off += blocks[i];
    }
    nk_w32(c, base + 0x10, total);   /* iTotalRamSize (EKA1 7.0s offset) */
    nk_w32(c, base + 0x18, list);    /* iRamBootData */
    printf("super page %#010x: total RAM %#x, %u banks at %#010x:",
           base, total, n, list);
    off = 0;
    for (uint32_t i = 0; i < n; i++) {
        printf(" {%#x,%#x}", off, blocks[i]);
        off += blocks[i];
    }
    printf("\n");
}

/* Round 28: the E32-entry boot is normally preceded by the mask ROM, which
 * builds the kernel's super-page hand-off.  The kernel reads
 * [0x400000d0] -> the ekern.exe TRomEntry and then [TRomEntry+4] -> its own
 * TRomImageHeader.  Without it the kernel reads address 4 (the low exception
 * vector word) as a header and the initial thread/process fields are
 * garbage.  NK_BOOT_HANDOFF installs the primary/variant/extension TRomEntry
 * pointers the mask ROM would leave in the super page. */
static void install_boot_handoff(nk_cpu_t* c) {
    uint32_t primary = nk_r32(c, 0x5000009cu);
    uint32_t variant = nk_r32(c, 0x500000c8u);
    uint32_t extension = nk_r32(c, 0x500000ccu);
    nk_w32(c, 0x400000c4u, primary);
    nk_w32(c, 0x400000c8u, variant);
    nk_w32(c, 0x400000ccu, extension);
    nk_w32(c, 0x400000d0u, primary);
    printf("boot handoff: superpage c4/c8/cc/d0 = %#010x/%#010x/%#010x/%#010x\n",
           primary, variant, extension, primary);
}

/* Round 28: the initial DThread's TStack object is taken from
 * iPrimaryFile + iStackSize (the kernel uses the TRomEntry address as a
 * writable base).  In the flash image that lands inside the read-only ROMFS
 * directory block.  Copy the 64 KiB directory to RAM and repoint only
 * iPrimaryFile; the variant/extension entries stay at their ROM addresses so
 * the extension loader keeps working.  This mirrors the mask ROM's
 * writable boot-table copy. */
static void install_primary_ram(nk_cpu_t* c, uint32_t to) {
    const uint32_t from = 0x50300000u;
    const uint32_t size = 0x10000u;
    if (nk_alloc_ram(c, to, size) != 0) {
        fprintf(stderr, "primary RAM: cannot map %#010x\n", to);
        return;
    }
    for (uint32_t i = 0; i < size; i += 4)
        nk_w32(c, to + i, nk_r32(c, from + i));
    uint32_t primary = nk_r32(c, 0x5000009cu);
    uint32_t rel = primary - from;
    nk_w32(c, 0x5000009cu, to + rel);
    printf("primary RAM: %#010x..%#010x -> %#010x, iPrimaryFile %#010x -> %#010x\n",
           from, from + size, to, primary, to + rel);
}

/* Round 27 experiment: give the boot loader a writable copy of the ROMFS
 * directory block.  With K=1361 misbound to the larger constructor the loader
 * writes 0x84 into the rtc.dll TRomEntry (0x50301f40); the K=1361 exception
 * removes that write, but the RAM table is still useful for later loader
 * steps.  This is an explicit boot-state model, not a firmware patch.
 */
static void install_boot_table_ram(nk_cpu_t* c, uint32_t to) {
    const uint32_t from = 0x50300000u;
    const uint32_t size = 0x10000u;
    if (nk_alloc_ram(c, to, size) != 0) {
        fprintf(stderr, "boot table RAM: cannot map %#010x\n", to);
        return;
    }
    for (uint32_t i = 0; i < size; i += 4)
        nk_w32(c, to + i, nk_r32(c, from + i));
    const uint32_t fields[] = {0x5000009cu, 0x500000a0u,
                               0x500000c8u, 0x500000ccu};
    printf("boot table RAM: %#010x..%#010x -> %#010x",
           from, from + size, to);
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        uint32_t v = nk_r32(c, fields[i]);
        if (v >= from && v < from + size) {
            nk_w32(c, fields[i], v + (to - from));
            printf(" %#x->%#x", v, v + (to - from));
        }
    }
    printf("\n");
}

/* NK_WRITE_WATCH: a bring-up store watch that reports the writer.  The B7e
 * graph owns the first nk_dbg watch slot (current-thread publication), so
 * this uses the second one.  Frame pointers are not reliable in ARM code; the
 * PC/LR pair plus r0-r3 is enough to identify the clearing loop. */
static uint32_t g_ww_addr;
static long     g_ww_max = 8;
static long     g_ww_hits;

/* Round 28: initial system time.  A cold boot copies the ROM header's iTime
 * (a TTime built into the image) into the kernel's system-time global.  The
 * direct E32-entry path reaches the same code with a TDateTime built by
 * EUser's calendar helper, but that conversion produces an out-of-range
 * TTime, so the following TTime::SecondsFrom fails and Kern::Init1 panics
 * KERN-WD2 24.  Model the mask-ROM hand-off by replacing the computed value
 * with the header's iTime.  This is boot state, not a firmware patch. */
#define NK_BOOT_TIME_GLOBAL 0x800017ecu
static void boot_time_raw_w32(nk_cpu_t* c, uint32_t a, uint32_t v) {
    uint8_t* p = nk_page_ptr(c, a);
    if (p) {
        p += a & NK_PAGE_MASK;
        p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
        p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
    }
}
static void boot_time_hook(nk_cpu_t* c, uint32_t addr, uint32_t value) {
    (void)addr; (void)value;
    /* Write directly: nk_w32 would re-enter this same watch hook. */
    boot_time_raw_w32(c, NK_BOOT_TIME_GLOBAL, nk_r32(c, 0x50000080u));
    boot_time_raw_w32(c, NK_BOOT_TIME_GLOBAL + 4u, nk_r32(c, 0x50000084u));
}

/* The kernel SVC handler calls the mask-ROM-installed pre-handler at
 * [0x80000f34] before dispatching the service table.  A direct E32-entry boot
 * leaves that global zero, so `ldr pc,[r12,#-4]` reads from 0 and jumps to 0.
 * Install a zero-return hook object in the high-vector page as boot state. */
static void install_svc_hook(nk_cpu_t* c, nk_interp_t* ip) {
    if (!env_ulong("NK_SWI_EXCEPTION", 0)) return;
    uint32_t slot = 0xffff0b00u;       /* [slot] = hook entry              */
    uint32_t code = 0xffff0b10u;       /* mov r0,#0; bx lr                 */
    nk_w32(c, slot, code);
    nk_w32(c, code, 0xe3a00000u);
    nk_w32(c, code + 4, 0xe12fff1eu);
    nk_w32(c, 0x80000f34u, slot + 4u); /* handler loads [obj-4]            */
    nk_code_range_add(ip, slot, code + 8u);
    printf("svc hook: [0x80000f34] = %#010x -> %#010x (zero return)\n",
           slot + 4u, code);
}

static void debug_write_hook(nk_cpu_t* c, uint32_t addr, uint32_t value) {
    if (g_ww_hits >= g_ww_max) return;
    if (g_ww_hits == 0)
        printf("[write-watch] %#010x:\n", addr);
    printf("[write-watch] pc=%08x lr=%08x sp=%08x store=%08x "
           "r0=%08x r1=%08x r2=%08x r3=%08x\n",
           c->r[15], c->r[14], c->r[13], value,
           c->r[0], c->r[1], c->r[2], c->r[3]);
    if (++g_ww_hits == g_ww_max)
        printf("[write-watch] %ld stores seen; suppressing the rest\n",
               g_ww_hits);
}

/* Some ROM extension records (rtc.dll is the first one) carry a nested
 * E32 image whose header has no export table.  The EKA1 extension loader
 * calls export ordinal 1 unconditionally after the image entry
 * (0x5031ebbc: ldr r3,[hdr+0x40]; ldr pc,[r3]), so a zero export_dir jumps
 * to 0.  NK_EXT_STUB=1 binds that slot to a stub in a high vector that
 * returns a HAL-like object, so the kernel installs it at [0x800003ac].
 * It is an explicit bring-up stand-in for the ROM-build export fixup, not
 * recovered firmware state. */
#define EXT_STUB_TABLE 0xffff0900u
#define EXT_STUB_CODE  0xffff0910u
static void install_extension_stub(nk_cpu_t* c, nk_interp_t* ip) {
    if (!env_ulong("NK_EXT_STUB", 0)) return;
    uint32_t entry = nk_r32(c, 0x500000cc);
    if (!entry) {
        printf("extension stub: TRomHeader.iExtensionFile is null\n");
        return;
    }
    uint32_t hdr = nk_r32(c, entry + 4);
    if (hdr < 0x50000000u || hdr >= 0x51600000u) {
        printf("extension stub: bad extension image header %#010x\n", hdr);
        return;
    }
    uint32_t count = nk_r32(c, hdr + 0x3c);
    uint32_t dir = nk_r32(c, hdr + 0x40);
    printf("extension stub: image header %#010x exports=%u dir=%#010x\n",
           hdr, count, dir);
    if (count && dir) return;
    nk_w32(c, EXT_STUB_TABLE, EXT_STUB_CODE);
    nk_w32(c, EXT_STUB_CODE + 0x00, 0xe59f0008u); /* ldr r0,[pc,#8] */
    nk_w32(c, EXT_STUB_CODE + 0x04, 0xe12fff1eu); /* bx lr          */
    nk_w32(c, EXT_STUB_CODE + 0x10, 0x80003a40u);/* HAL-like object */
    nk_w32(c, hdr + 0x3c, 1);
    nk_w32(c, hdr + 0x40, EXT_STUB_TABLE);
    nk_code_range_add(ip, EXT_STUB_CODE, EXT_STUB_CODE + 0x14);
    printf("extension stub: export 1 -> %#010x (HAL object %#010x)\n",
           EXT_STUB_CODE, 0x80003a40u);
}

/* ------------------------------------------------------------------ */
/* Round 31: the kernel timer/queue singleton at [0x80001c34]          */
/*                                                                     */
/* After the round-30 timer IRQ wakes the idle loop, Kern::Init1        */
/* continues at 0x5031ef40 with `[0x80001c34] -> vtable+0xc`.  Nothing */
/* in the E32 image writes that global: the object is created by the    */
/* mask-ROM/HAL boot state that a direct E32-entry boot skips.  Kernel  */
/* export 451 (0x5032aff8) is the class constructor and export 344      */
/* (0x5032b33c) the setter, but no image imports either.               */
/*                                                                     */
/* NK_TIMERQ=1 injects the boot-state object at the exact instruction   */
/* that consumes it, using the kernel's own constructor.  The default   */
/* ("override") also substitutes the pure-virtual HAL tick slot; "ctor" */
/* keeps the abstract base vtable (control) and "stub" builds an        */
/* all-zero vtable.  This is an explicit boot-state model, not a        */
/* recovered mask-ROM implementation.                                  */
#define TIMERQ_CTOR       0x5032aff8u
#define TIMERQ_SENTINEL   0xdead0100u

/* Round 92: the timer-queue object's +0x1c slot is the HAL tick/time
 * getter.  A zero-return stub makes the kernel's timing math produce no
 * delay, so no timer is ever armed and the idle loop spins forever with
 * "timer: off, 0 expiries".  NK_HAL_TICK=1 replaces the stub with a hook
 * that returns a monotonic tick derived from executed instructions. */
/* Round 94: DThread::StartThread (vtable+0x20 = 0x50321088) stores the
 * argument at this+0xf8 and tail-branches to the kernel's start hand-off at
 * 0x50318398, which consumes the pending TRequestStatus at [0x80001784].  If
 * that slot is 0 (already consumed) the hand-off raises a PLAT fault with
 * reason 0x73.  NK_HANDOFF_ARM=1 re-arms the slot with a fresh pending status
 * just before the hand-off runs. */
#define HANDOFF_PENDING 0x80001784u
static uint32_t g_handoff_arm_count;

static void handoff_arm_hook(nk_cpu_t* c, nk_interp_t* ip, uint32_t pc) {
    (void)ip; (void)pc;
    uint32_t cur = nk_r32(c, HANDOFF_PENDING);
    if (cur >= 0x80000000u && cur < 0x80a00000u) return;  /* already armed */
    uint32_t dummy = 0x80530000u;
    if (!nk_page_ptr(c, dummy)) {
        if (nk_alloc_ram(c, dummy, 0x1000u) == 0)
            for (uint32_t o = 0; o < 0x1000u; o += 4) nk_w32(c, dummy + o, 0);
    }
    nk_w32(c, dummy, 0x80000001u);   /* KRequestPending */
    nk_w32(c, HANDOFF_PENDING, dummy);
    g_handoff_arm_count++;
}

static unsigned long g_tick_calls;

static void hal_tick_hook(nk_cpu_t* c, nk_interp_t* ip, uint32_t pc) {
    (void)pc;
    uint32_t v = (uint32_t)env_ulong("NK_HAL_TICK_SHIFT", 10);
    c->r[0] = (uint32_t)(ip->st.insns >> (v ? v : 1));
    uint32_t lr = c->r[14];
    c->r[15] = lr & ~1u;
    if (lr & 1u) c->cpsr |= NK_CPSR_T; else c->cpsr &= ~NK_CPSR_T;
    g_tick_calls++;
}

static int g_timerq_state;

/* Call one guest function with a private interpreter, preserving the CPU
 * state of the interrupted boot.  The constructor calls EUser imports and
 * must see the same executive-call model as the main run. */
static int timerq_nested_call(nk_cpu_t* c, nk_interp_t* parent,
                              uint32_t target, uint32_t ret) {
    nk_interp_t sub;
    nk_interp_init(&sub);
    sub.budget = 400000;
    sub.return_pc = ret;
    sub.return_thumb = 0;
    sub.infer_mode = 0;
    sub.infer_calls = 0;
    sub.recover = 0;
    sub.require_code = 0;
    sub.swi_direct = parent->swi_direct;
    sub.swi_table = parent->swi_table;
    sub.swi_log = 0;
    memcpy(sub.swi_complete, parent->swi_complete, sizeof sub.swi_complete);
    sub.banked = parent->banked;
    sub.alloc_hle = parent->alloc_hle;
    sub.alloc_pc = parent->alloc_pc;
    sub.realloc_pc = parent->realloc_pc;
    sub.free_pc = parent->free_pc;
    sub.alloc_base = parent->alloc_base;
    sub.alloc_cur = parent->alloc_cur;
    sub.alloc_end = parent->alloc_end;
    sub.hle_heap = parent->hle_heap;
    sub.hle_heap_end = parent->hle_heap_end;
    sub.stop_selfb = 1;
    c->cpsr &= ~NK_CPSR_T;
    c->r[15] = target & ~1u;
    nk_interp_run(c, &sub);
    parent->alloc_cur = sub.alloc_cur;
    return (c->r[15] & ~1u) == (ret & ~1u);
}

/* Round 80: the EStart server reaches Mem::Copy with a corrupted length
 * (0xe59ff028) and a destination outside RAM, which turns into a 600k-access
 * MMIO storm.  Clamp obviously-wild copies to zero so the server can return
 * to its caller and expose the next handshake step. */
static void memcopy_clamp_hook(nk_cpu_t* c, nk_interp_t* ip, uint32_t pc) {
    (void)ip; (void)pc;
    uint32_t dst = c->r[0], src = c->r[1], len = c->r[2];
    int invalid = (dst < 0x50000000u || dst >= 0x80a00000u ||
                   src < 0x50000000u || src >= 0x80a00000u);
    if (len > 0x100000u || invalid) {
        c->r[2] = 0;
    }
}

/* Round 86: the EStart supervisor's 0x00a04d08 dispatch treats its stack
 * params block as a CBase and reads [this+0x14] as a vtable.  Replace that
 * field with the B7e vtable so the +0xc dispatch lands on a zero-return
 * stub instead of a code address. */
static void supervisor_object_hook(nk_cpu_t* c, nk_interp_t* ip, uint32_t pc) {
    (void)ip; (void)pc;
    uint32_t forced = (uint32_t)env_ulong("NK_SUPERVISOR_THIS", 0);
    if (forced) c->r[4] = forced;
    uint32_t thisp = c->r[4];
    if (thisp >= 0x80500000u && thisp < 0x80600000u)
        nk_w32(c, thisp + 0x14u,
               (uint32_t)env_ulong("NK_SUPERVISOR_VTABLE", 0x80003040u));
}

static void timerq_pc_hook(nk_cpu_t* c, nk_interp_t* ip, uint32_t pc) {
    (void)pc;
    ip->pc_hook = NULL;
    if (g_timerq_state) return;
    g_timerq_state = 1;

    uint32_t obj   = (uint32_t)env_ulong("NK_TIMERQ_ADDR", 0x80500000u);
    uint32_t page  = obj & ~(NK_PAGE_SIZE - 1u);
    uint32_t stack = page + 0x1800u;
    const char* mode = getenv("NK_TIMERQ_MODE");

    if (!nk_page_ptr(c, obj)) {
        if (nk_alloc_ram(c, page, 0x2000u) != 0) {
            printf("timerq: cannot map %#010x..%#010x\n", page, page + 0x2000u);
            return;
        }
        for (uint32_t i = 0; i < 0x2000u; i += 4) nk_w32(c, page + i, 0);
    }

    int ctor_ok = 0;
    if (!mode || strcmp(mode, "stub") != 0) {
        nk_cpu_t saved = *c;
        c->r[0] = obj;
        c->r[13] = stack;
        c->r[14] = TIMERQ_SENTINEL;
        c->cpsr = saved.cpsr & ~NK_CPSR_T;
        ctor_ok = timerq_nested_call(c, ip, TIMERQ_CTOR, TIMERQ_SENTINEL);
        *c = saved;
        printf("timerq: ctor %#010x -> %s", TIMERQ_CTOR,
               ctor_ok ? "ok" : "failed");
        if (ctor_ok)
            printf(" (vtable %#010x, +4=%#010x, +0xc=%#010x, +0x10=%#010x)",
                   nk_r32(c, obj), nk_r32(c, obj + 4),
                   nk_r32(c, obj + 0xc), nk_r32(c, obj + 0x10));
        printf("\n");
    }

    /* The kernel constructor installs the abstract base vtable at
     * 0x503383bc.  Its +0x1c slot is the pure-virtual `User::Panic`
     * placeholder: the concrete timer implementation (the mask-ROM/HAL
     * object) overrides it with the hardware tick/time getter.  Copy the
     * base vtable and substitute a zero-return getter so the kernel's own
     * 0x5032b024 runs instead of hitting the pure-virtual panic. */
    int override_vt = ctor_ok && (!mode || strcmp(mode, "ctor") != 0);
    if (override_vt) {
        uint32_t vt = obj + 0x100u, code = 0xffff0a00u;
        for (int i = 0; i < 64; i++)
            nk_w32(c, vt + 4u * (uint32_t)i,
                   nk_r32(c, 0x503383bcu + 4u * (uint32_t)i));
        nk_w32(c, code + 0, 0xe3a00000u);   /* mov r0,#0 */
        nk_w32(c, code + 4, 0xe12fff1eu);   /* bx lr     */
        nk_w32(c, vt + 0x1c, code);
        for (uint32_t off = 0x20; off <= 0x2c; off += 4) nk_w32(c, vt + off, code);
        nk_w32(c, obj + 0x00, vt);
        nk_code_range_add(ip, code, code + 8);
        printf("timerq: HAL override vtable %#010x (base 0x503383bc, "
               "+0x1c -> %#010x)\n", vt, code);
    }

    if (!ctor_ok) {
        /* Zero-return vtable stand-in: every virtual call returns 0.  The
         * object still has the timer-queue field layout inferred from
         * constructor 0x5032aff8 (vtable at +0, refcount +4, flags +0xc,
         * TDblQue at +0x10, element size 4). */
        uint32_t vt = obj + 0x100u, code = 0xffff0a00u;
        nk_w32(c, code + 0, 0xe3a00000u);   /* mov r0,#0 */
        nk_w32(c, code + 4, 0xe12fff1eu);   /* bx lr     */
        for (int i = 0; i < 64; i++) nk_w32(c, vt + 4u * (uint32_t)i, code);
        nk_w32(c, obj + 0x00, vt);
        nk_w32(c, obj + 0x04, 1);
        nk_w32(c, obj + 0x0c, 0);
        nk_w32(c, obj + 0x10, obj + 0x10);
        nk_w32(c, obj + 0x14, obj + 0x10);
        nk_w32(c, obj + 0x18, 4);
        nk_code_range_add(ip, code, code + 8);
        printf("timerq: stub object %#010x (vtable %#010x)\n", obj, vt);
    }

    nk_w32(c, 0x80001c34u, obj);
    printf("timerq: [0x80001c34] = %#010x -> vtable+0xc = %#010x\n",
           obj, nk_r32(c, nk_r32(c, obj) + 0x0c));
    if (env_ulong("NK_HANDOFF_ARM", 0)) {
        ip->pc_hook3_addr = 0x50318398u;
        ip->pc_hook3 = handoff_arm_hook;
        printf("handoff arm: re-arm [0x%08x] before the start hand-off\n",
               HANDOFF_PENDING);
    }
    if (env_ulong("NK_HAL_TICK", 0)) {
        /* Intercept the +0x1c getter before its zero-return body runs. */
        ip->pc_hook2_addr = 0xffff0a00u;
        ip->pc_hook2 = hal_tick_hook;
        printf("timerq: HAL tick hook at %#010x (shift %lu)\n",
               0xffff0a00u, (unsigned long)env_ulong("NK_HAL_TICK_SHIFT", 10));
    }
}

/* ------------------------------------------------------------------ */
/* Round 33: first scheduler switch                                    */
/*                                                                     */
/* 0x503309e4 (Kern::Init2) creates the kernel's NULL thread at        */
/* 0x5032fa10: DThread object 0x80601830, name descriptor "NULL",      */
/* 0x2000-byte kernel stack, entry 0x5031f144 (the literal at          */
/* 0x5032faf4 passed as the thread function).  It then publishes a     */
/* TRequestStatus at [0x80001784] and calls EUser K=1208              */
/* (0x50398644 -> `svc #0x4d`).  Kernel service table entry 0x4d is    */
/* 0x503244e4: `current_thread->[0x5c]->vtable[0x20]`, i.e. Wait() on  */
/* the request semaphore that 0x503311c8 installs at thread+0x5c       */
/* (DThread vtable 0x503385b4; +0x5c is created by DObject-style       */
/* constructor 0x50320ac0).  Without a scheduler the wait can never    */
/* return and Init2 panics KERN 6 at 0x50330aa8.                       */
/*                                                                     */
/* This model performs the switch the kernel's own scheduler would:    */
/*   - the caller's context is saved at the `svc #0x4d` call gate;     */
/*   - the NULL thread is started on a 0x2000-byte kernel stack with   */
/*     its real entry point (0x5031f144);                              */
/*   - the first switch goes through the kernel's observable hand-off  */
/*     (0x50318398, reached from DThread vtable+0x20 0x50321088): it   */
/*     publishes the new current thread, clears [0x80001784] and       */
/*     completes the startup TRequestStatus (writes 0), which is what  */
/*     lets the supervisor leave WaitForAnyRequest;                    */
/*   - the hand-off wakes the supervisor, which preempts the NULL      */
/*     thread at the next instruction boundary (higher priority);      */
/*     the NULL thread stays runnable and resumes when scheduled.      */
/* The stack itself is harness-owned: the kernel-allocated stack is not */
/* recorded in a field this boot has recovered yet.                     */
/*                                                                     */
/* Known conflict: B7e's current-thread hook still overwrites +0x5c     */
/* with its TLS stand-in whenever a thread is published, which replaces */
/* the request semaphore this round identified.  Round 33 does not      */
/* execute the real Wait for the NULL thread, so the switch works; the  */
/* next round must stop clobbering a live +0x5c.                        */
/* ------------------------------------------------------------------ */
#define SCHED_CURRENT     0x800017d4u  /* kernel current DThread*        */
#define SCHED_PENDING     0x80001784u  /* startup TRequestStatus* slot   */
#define SCHED_NULL_GLOBAL 0x80000400u  /* [..] = DThread made at 0x5032fa10 */
#define SCHED_NULL_ENTRY  0x5031f144u  /* thread function argument       */
#define SCHED_STACK_BASE  0x80540000u
#define SCHED_STACK_SIZE  0x2000u
#define SCHED_SLOTS       4
#define SCHED_WAIT_SWI    0x4du

typedef struct sched_thread {
    uint32_t thread;
    uint32_t r[16];
    uint32_t cpsr;
    uint32_t resume_pc;      /* instruction after the blocked call gate */
    uint32_t status;         /* TRequestStatus* observed at the wait    */
    uint32_t calls_lr[64];   /* per-thread interpreter shadow stack     */
    uint8_t  calls_thumb[64];
    int      calls_n;
    int      state;          /* 0 free, 1 ready, 2 running, 3 blocked   */
    int      started;
} sched_thread;

static int      b7e_live;      /* keep kernel-created +0x18/+0x5c/+0x64 */

static sched_thread sched_slot_tab[SCHED_SLOTS];
static int      sched_on;
static int      sched_defer;    /* let the start hand-off return before preempt */
static uint32_t sched_arm_pc;
static unsigned long sched_arm_insns;
static int      sched_log = 8;
static unsigned sched_switches;
static unsigned sched_blocks;
static int      sched_startup_done;

static sched_thread* sched_slot(uint32_t t, int create) {
    for (int i = 0; i < SCHED_SLOTS; i++)
        if (sched_slot_tab[i].thread == t) return &sched_slot_tab[i];
    if (!create) return NULL;
    for (int i = 0; i < SCHED_SLOTS; i++)
        if (sched_slot_tab[i].thread == 0) {
            sched_slot_tab[i].thread = t;
            sched_slot_tab[i].state = 1;
            return &sched_slot_tab[i];
        }
    return NULL;
}

static void sched_save_calls(nk_interp_t* ip, sched_thread* s) {
    s->calls_n = ip->calls_n;
    for (int i = 0; i < s->calls_n; i++) {
        s->calls_lr[i] = ip->calls[i].lr;
        s->calls_thumb[i] = ip->calls[i].thumb;
    }
}

static void sched_load_calls(nk_interp_t* ip, sched_thread* s) {
    ip->calls_n = s->calls_n;
    for (int i = 0; i < s->calls_n; i++) {
        ip->calls[i].lr = s->calls_lr[i];
        ip->calls[i].thumb = s->calls_thumb[i];
    }
}

static void importmap_revert(nk_cpu_t* c);

/* "auto" honours the entry bit, "thumb" forces Thumb, anything else forces
 * ARM (the pre-round-93 behaviour that the legacy tests pin). */
static int sched_mode_thumb(int entry_bit, const char* mode) {
    if (mode[0] == 'a' && mode[1] == 'u') return entry_bit;
    if (mode[0] == 't') return 1;
    return 0;
}

static uint32_t sched_supervisor;
static int      sched_need_yield;

static void sched_resume(nk_cpu_t* c, nk_interp_t* ip, sched_thread* s) {
    memcpy(c->r, s->r, sizeof s->r);
    c->cpsr = s->cpsr;
    c->r[15] = s->r[15] & ~1u;
    {
        const char* sm = env_str("NK_SCHED_MODE", "auto");
        int t = sched_mode_thumb((int)(s->r[15] & 1u), sm);
        if (t) c->cpsr |= NK_CPSR_T; else c->cpsr &= ~NK_CPSR_T;
    }
    sched_load_calls(ip, s);
    s->state = 2;
    nk_w32(c, SCHED_CURRENT, s->thread);
}

/* The kernel wakes the supervisor when the NULL thread's start hand-off
 * completes its request.  On a real scheduler the higher-priority supervisor
 * then preempts the NULL thread at the next instruction boundary; this hook
 * implements exactly that, saving the NULL thread mid-startup so it can be
 * resumed when the supervisor next blocks. */
static int sched_yield_hook(nk_cpu_t* c, nk_interp_t* ip) {
    if (sched_on && env_ulong("NK_SCHED_EXIT", 0) &&
        (c->r[15] & ~1u) == 0xdead0000u) {
        uint32_t t = nk_r32(c, SCHED_CURRENT);
        sched_thread* cur = sched_slot(t, 0);
        sched_thread* sup = sched_slot(sched_supervisor, 0);
        if (cur && sup && cur != sup) {
            cur->state = 0;              /* thread returned; retire it */
            sched_resume(c, ip, sup);
            sched_switches++;
            if (sched_log-- > 0)
                printf("sched: thread %#010x returned; resume supervisor "
                       "%#010x pc %#010x (insns=%lu)\n",
                       cur->thread, sup->thread, c->r[15], ip->st.insns);
            return 1;
        }
    }
    /* Round 34: a blocked thread is runnable again as soon as its pending
     * TRequestStatus is completed, whoever completes it.  With the kernel's
     * own request semaphore and CObjectIx preserved, the NULL thread's
     * StartThread hand-off writes 0 straight into the supervisor's status and
     * never touches the harness dummy page, so the old dummy-only wake missed
     * it and the next hand-off panicked PLAT 0x73.  Poll the saved status at
     * every instruction boundary; it is one word in frozen stack memory. */
    if (sched_on && b7e_live && sched_supervisor) {
        sched_thread* sup = sched_slot(sched_supervisor, 0);
        if (sup && sup->state == 3 && sup->status &&
            nk_r32(c, sup->status & ~3u) != 0x80000001u) {
            sup->state = 1;
            sched_need_yield = 1;
            if (sched_log-- > 0)
                printf("sched: supervisor status %#010x completed; "
                       "runnable again (insns=%lu)\n",
                       sup->status, ip->st.insns);
        }
    }
    if (!sched_need_yield) return 0;
    if (sched_defer) {
        /* Round 35: the start hand-off runs 0x50318398 -> Open semaphore ->
         * back to 0x5033130c.  Preempting at 0x503183bc freezes it before the
         * supervisor's next request can be consumed, so the two threads
         * deadlock.  Let it reach the return site (or time out after 2000
         * instructions) before switching. */
        if (!sched_arm_pc) {
            sched_arm_pc = 0x5033130cu;
            sched_arm_insns = ip->st.insns;
        }
        if (c->r[15] != sched_arm_pc &&
            ip->st.insns - sched_arm_insns < 2000)
            return 0;
        sched_arm_pc = 0;
    }
    sched_need_yield = 0;
    /* Round 96: once an application thread has been dispatched, the
     * bring-up supervisor must not steal the CPU back - on this boot it
     * never issues another svc #0x4d, so the app thread would be starved
     * after ~1,500 instructions.  NK_SCHED_NO_PREEMPT=1 keeps the app
     * thread running until it blocks by itself. */
    if (env_ulong("NK_SCHED_NO_PREEMPT", 0) && sched_switches >= 1) return 0;
    if (!sched_on || !sched_supervisor) return 0;
    uint32_t t = nk_r32(c, SCHED_CURRENT);
    sched_thread* cur = sched_slot(t, 0);
    sched_thread* sup = sched_slot(sched_supervisor, 0);
    if (!cur || !sup || cur == sup || sup->state != 1) return 0;
    memcpy(cur->r, c->r, sizeof cur->r);
    cur->cpsr = c->cpsr;
    cur->started = 1;
    cur->state = 1;                 /* runnable, preempted mid-startup */
    sched_save_calls(ip, cur);
    sched_resume(c, ip, sup);
    sched_switches++;
    if (sched_log-- > 0)
        printf("sched: preempt %#010x -> supervisor %#010x at pc %#010x "
               "(its wait returns 0, insns=%lu)\n", cur->thread, sup->thread,
               c->r[15], ip->st.insns);
    return 1;
}

/* The kernel's thread-start hand-off consumes one pending TRequestStatus at
 * [0x80001784] (0x50318398 reads it, clears the slot and writes 0 to the
 * status).  EUser's `RThread::Resume` wrapper (0x50399898 -> svc #0x76 ->
 * Kern::StartThread 0x503312d4) calls that path once per thread it starts,
 * so a boot that has more than one thread needs a fresh pending request for
 * every call.  Keep the harness hand-off page armed: when the guest consumes
 * it, put KRequestPending back and re-publish the slot.  The value write must
 * bypass the watch (nk_w32 would re-enter this hook). */
static uint32_t sched_dummy;
static unsigned sched_handoffs;

static void sched_handoff_hook(nk_cpu_t* c, uint32_t addr, uint32_t value) {
    (void)value;
    if (!sched_on || !sched_dummy || addr != sched_dummy) return;
    boot_time_raw_w32(c, sched_dummy, 0x80000001u);   /* KRequestPending */
    nk_w32(c, SCHED_PENDING, sched_dummy);
    sched_handoffs++;
    /* The hand-off completed a request; if a higher-priority thread is now
     * ready, let it run at the next instruction boundary. */
    if (sched_supervisor && nk_r32(c, SCHED_CURRENT) != sched_supervisor)
        sched_need_yield = 1;
    if (sched_log-- > 0)
        printf("sched: thread-start hand-off consumed; re-armed %#010x\n",
               sched_dummy);
}

static int sched_swi_hook(nk_cpu_t* c, nk_interp_t* ip, uint32_t imm,
                          uint32_t pc) {
    (void)pc;
    if (!sched_on || (imm & 0x1ffu) != SCHED_WAIT_SWI) return 0;
    /* Only the kernel-start wait (BL at 0x50330a94) is the scheduled block.
     * Earlier EUser code also executes `svc #0x4d` from its own wait loop
     * (return address 0x5039865c); those keep the historical inline model. */
    {
        static uint32_t sched_lr;
        if (!sched_lr) sched_lr = (uint32_t)env_ulong("NK_SCHED_LR", 0x50330a98u);
        if ((c->r[14] & ~1u) != sched_lr) return 0;
    }
    uint32_t t = nk_r32(c, SCHED_CURRENT);
    if (!t) return 0;
    sched_thread* cur = sched_slot(t, 1);
    if (!cur) return 0;
    if (!sched_supervisor) sched_supervisor = t;

    /* Save the caller.  LR is the return address of the BL that entered the
     * EUser stub; the stub is a tail branch to the SVC instruction, so the
     * executive call resumes there once the thread is running again. */
    memcpy(cur->r, c->r, sizeof cur->r);
    cur->cpsr = c->cpsr;
    cur->resume_pc = c->r[14];
    cur->r[15] = cur->resume_pc & ~1u;   /* resume after the call gate */
    cur->status = nk_r32(c, SCHED_PENDING);
    cur->started = 1;
    sched_save_calls(ip, cur);
    if (cur->calls_n > 0) cur->calls_n--;  /* the call gate consumes its BL */
    cur->state = 3;
    sched_blocks++;
    if (sched_log-- > 0)
        printf("sched: thread %#010x blocks on svc #0x%02x (status %#010x, "
               "resume %#010x, insns=%lu)\n", t, imm & 0x1ffu, cur->status,
               cur->resume_pc, ip->st.insns);

    /* Pick the next thread: the kernel's NULL thread is the only other one
     * this boot has created. */
    uint32_t nt = nk_r32(c, SCHED_NULL_GLOBAL);
    sched_thread* next = NULL;
    if (nt && nt != t) {
        sched_thread* n = sched_slot(nt, 1);
        if (n && n->state != 3) next = n;
    }
    if (!next) {
        for (int i = 0; i < SCHED_SLOTS && !next; i++)
            if (sched_slot_tab[i].thread && sched_slot_tab[i].thread != t &&
                sched_slot_tab[i].state == 1)
                next = &sched_slot_tab[i];
    }
    if (!next) {
        if (sched_log-- > 0)
            printf("sched: no runnable thread; %#010x stays blocked\n", t);
        return 0;
    }

    if (!next->started) {
        uint32_t base = (uint32_t)env_ulong("NK_SCHED_STACK", SCHED_STACK_BASE);
        uint32_t ssize = (uint32_t)env_ulong("NK_SCHED_STACK_SIZE", SCHED_STACK_SIZE);
        uint32_t extra = (uint32_t)env_ulong("NK_SCHED_STACK_EXTRA", 0);
        if (ssize < 0x1000u) ssize = 0x1000u;
        if (!nk_page_ptr(c, base)) {
            if (nk_alloc_ram(c, base, ssize + extra) != 0) {
                printf("sched: cannot map NULL-thread stack %#010x\n", base);
                return 0;
            }
        }
        {
            uint32_t fill = (uint32_t)env_ulong("NK_SCHED_STACK_FILL", 0);
            for (uint32_t o = 0; o < ssize + extra; o += 4)
                nk_w32(c, base + o, fill);
        }
        memset(next->r, 0, sizeof next->r);
        next->r[0] = (uint32_t)env_ulong("NK_SCHED_R0", 0);
        next->r[13] = base + ssize - 0x10u;
        next->r[14] = 0xdead0000u;
        next->r[15] = (uint32_t)env_ulong("NK_SCHED_ENTRY", SCHED_NULL_ENTRY);
        /* Kernel threads run in SVC mode; keep the caller's IRQ mask.  The
         * entry address carries the Thumb bit in bit 0 (E32 iEntryPoint is
         * always odd for Thumb images), so honour it: starting a Thumb image
         * in ARM mode executes the first instructions as garbage and the
         * resulting register state (r4=0, r5=0) sends the image into a null
         * call.  Round 93 fixes that for the fake thread and the first real
         * switch. */
        {
            /* NK_SCHED_MODE pins the instruction set: "auto" (default)
             * honours iEntryPoint bit 0, "arm"/"thumb" force a mode so that
             * pre-round-93 tests can still reproduce their historical
             * frontier. */
            const char* sm = env_str("NK_SCHED_MODE", "auto");
            int t = sched_mode_thumb((int)(next->r[15] & 1u), sm);
            next->cpsr = (cur->cpsr & 0x000000c0u) | 0x40000013u |
                         (t ? NK_CPSR_T : 0u);
        }
        if (getenv("NK_IMPORTMAP_REVERT") || getenv("NK_IMPORTMAP_APP") ||
            getenv("NK_EUSER_ROTATE"))
            importmap_revert(c);
        /* Round 102: the kernel's own boot cannot run without the HLE
         * allocator (it panics at 12,595 instructions when the allocator is
         * disabled from the start), but an application thread can use the
         * kernel's real RHeap object.  NK_ALLOC_HLE_KERNEL_ONLY=1 hands the
         * heap back to the guest once an application thread is dispatched. */
        if (getenv("NK_ALLOC_HLE_KERNEL_ONLY")) {
            ip->alloc_hle = 0;
            printf("alloc hle: disabled for the application thread\n");
        }
        /* The kernel's resume path clears the suspend bits before a thread
         * runs; the direct switch bypasses it, so clear them here. */
        nk_w32(c, next->thread + 0x20u,
               nk_r32(c, next->thread + 0x20u) & ~0xcu);
        next->calls_n = 0;
        next->started = 1;
        next->state = 1;
        printf("sched: first switch -> NULL thread %#010x, entry %#010x, "
               "stack %#010x..%#010x (insns=%lu)\n", next->thread, next->r[15],
               base, base + ssize, ip->st.insns);
    }

    /* Kernel hand-off (0x50318398): the first switch publishes the new
     * current thread and completes the startup request at [0x80001784]. */
    if (!sched_startup_done) {
        uint32_t st = nk_r32(c, SCHED_PENDING);
        if (st) nk_w32(c, st & ~3u, 0);
        nk_w32(c, SCHED_PENDING, 0);
        sched_startup_done = 1;
        cur->state = 1;          /* the waiting supervisor is runnable again */
        cur->r[0] = 0;
        /* The kernel's start hand-off (0x50318398, DThread vtable+0x20) is
         * also what the NULL thread itself executes on its way up: it reads
         * [0x80001784], completes that TRequestStatus and publishes the new
         * current thread.  Re-arm the slot with a pending status owned by the
         * harness stack so the guest path runs instead of panicking 0x73
         * ("no thread-start request").  The supervisor's own request has just
         * been completed above, exactly like the kernel hand-off does. */
        uint32_t dummy = 0x80530000u;        /* harness hand-off page */
        if (!nk_page_ptr(c, dummy)) {
            if (nk_alloc_ram(c, dummy, 0x1000u) == 0)
                for (uint32_t o = 0; o < 0x1000u; o += 4) nk_w32(c, dummy + o, 0);
        }
        sched_dummy = dummy;
        nk_w32(c, dummy, 0x80000001u);       /* KRequestPending */
        nk_w32(c, SCHED_PENDING, dummy);
        nk_dbg_watch_write2(dummy, sched_handoff_hook);
        if (sched_log-- > 0)
            printf("sched: startup request %#010x completed, supervisor "
                   "%#010x ready; hand-off re-armed at %#010x\n",
                   st, cur->thread, dummy);
    }

    sched_resume(c, ip, next);
    sched_switches++;
    if (env_ulong("NK_SCHED_AUTOCOMPLETE", 0) && cur->status) {
        /* Round 79: the harness has no server to complete a request.  Mark
         * the blocked thread's status complete and make it runnable again so
         * the wait loop can make progress; the server thread then runs its
         * next handshake step. */
        boot_time_raw_w32(c, cur->status & ~3u, 0);
        cur->state = 1;
        if (sched_log-- > 0)
            printf("sched: auto-complete status %#010x for thread %#010x\n",
                   cur->status, cur->thread);
    }
    if (sched_log-- > 0)
        printf("sched: switch #%u -> thread %#010x pc %#010x sp %#010x "
               "cpsr %#010x (insns=%lu)\n", sched_switches, next->thread, c->r[15],
               c->r[13], c->cpsr, ip->st.insns);
    return 1;
}

/* ------------------------------------------------------------------ */
/* B7e boot-state stand-in: initial thread -> process -> object index  */
/*                                                                     */
/* A cold boot lets the mask ROM build the first DThread/DProcess       */
/* before the kernel's E32 entry runs.  Booting the E32 entry directly  */
/* skips that: [0x800017d4] starts as zero and the kernel later         */
/* publishes a bare thread with a null process.                        */
/*                                                                     */
/* Round 19 called the resulting stop "RHeap::Alloc with a null heap".  */
/* The code at 0x50380270 is not the heap allocator: it indexes an      */
/* object array ([this+0x18] is an array, [this+0x14] the element size, */
/* [this] the base) and the caller 0x50318410 is the handle-to-object   */
/* path that reads [thread+0x18] -> [process+0x38].  That matches       */
/* CObjectIx::At (SDK EUser ordinal 109), so the missing boot state is  */
/* the process and its object index, not the heap.                      */
/*                                                                     */
/* NK_B7E=1 installs a coherent graph the moment the kernel writes its  */
/* current-thread global: thread -> process, process -> CObjectIx, and  */
/* the object index -> an array whose element fetch returns the process */
/* object.  A separate guest bump allocator remains available for code  */
/* that really allocates.  This is an explicit bring-up stand-in.       */
/* ------------------------------------------------------------------ */

#define B7E_ZERO_STUB  0xffff0300u   /* mov r0,#0; bx lr                  */
#define B7E_HAL_STUB   0xffff0600u   /* HAL map/channel, see b7e_install() */
#define B7E_HAL_REQ    0xffff0800u   /* stand-in device Request(), id 0xd  */
#define B7E_ALLOC_STUB 0xffff0200u   /* bump allocator, see b7e_install() */
#define B7E_ALLOC_LIT  0xffff0240u   /* -> guest bump cursor              */
#define B7E_AT_STUB    0xffff0400u   /* CObjectIx element fetch            */
#define B7E_THREAD     0x80003000u
#define B7E_PROCESS     0x80003200u
#define B7E_OBJIDX      0x80003300u  /* what the old code mislabelled heap */
#define B7E_ALLOC       0x80003400u
#define B7E_VT_PROCESS  0x80003500u
#define B7E_VT_ALLOC    0x80003600u
#define B7E_ARRAY       0x80003700u
#define B7E_VT_ARRAY    0x80003800u
#define B7E_CURSOR      0x80003900u
#define B7E_CUR_OBJ     0x80003910u   /* last published current thread      */
#define B7E_HAL         0x80003a00u   /* stand-in kernel HAL object         */
#define B7E_HAL_CHAN    0x80003a40u   /* object returned by HAL map/channel */
#define B7E_VT_HAL      0x80003c00u   /* its vtable (>= 0x108 bytes)        */
#define B7E_TLS         0x80003f00u   /* thread-local object [thread+0x5c]  */
#define B7E_VT_TLS      0x80003e00u
#define B7E_ONE_STUB    0xffff0500u   /* mov r0,#1; bx lr                  */
#define B7E_WAIT_STUB   0xffff0c00u   /* complete [r5], return 0           */
#define B7E_START_STUB  0xffff0e00u   /* complete [r3], return 0           */
#define B7E_VT_ENTRIES  64

/* Round 25: the user-side runtime normally installs a CTrapCleanup before it
 * calls any code that can leave.  Booting the kernel E32 entry directly skips
 * that startup, so EUser's CleanupStack::PushL panics with USER-CBase 69
 * (EClnNoTrapHandlerInstalled).  Build the real objects instead of a no-op
 * handler: a TCleanupTrapHandler whose vtable entries are EUser's own
 * TCleanupTrapHandler::Trap/UnTrap/Leave, and a CCleanup with one level
 * marker.  The vtable addresses are read from the packed image
 * (0x503b3518 -> Trap 0x50383c38, UnTrap 0x50383c40, Leave 0x50383c48). */
#define B7E_TRAP_BASE   0x80004100u   /* per-thread trap/cleanup slots     */
#define B7E_TRAP_STRIDE 0x100u
#define B7E_TRAP_SLOTS  4
#define B7E_TRAPH_OFF   0x00u         /* TCleanupTrapHandler               */
#define B7E_CLEAN_OFF   0x40u         /* CCleanup                          */
#define B7E_CLBASE_OFF  0x80u         /* TCleanupStackItem[8]              */
#define B7E_CLTOP_OFF   0xc0u
#define B7E_TRAP_VT     0x503b3518u
#define B7E_CLEAN_VT    0x503b36a4u

static int      b7e_enabled;
static int      b7e_trapclean;
static int      b7e_installs;
static uint32_t b7e_heap_cur, b7e_heap_end;
static uint32_t b7e_current_thread;
static uint32_t b7e_trap_owner[B7E_TRAP_SLOTS];
/* Round 32: the kernel's real DThread lands in the bring-up heap
 * (NK_ALLOC_BASE, 0x80600000 by default), not inside the 3 MiB kernel-RAM
 * window.  The old 0x80400000 bound treated that pointer as transient and
 * re-published the stack-allocated bootstrap SThread at 0x802ffd00 instead:
 * a later EUser TFullName buffer on the boot stack then overwrote the live
 * thread (+0x38 iFrame / +0x3c iTrapHandler), so TTrap::UnTrap popped a ROM
 * text address.  Follow the heap bound the harness actually mapped. */
static uint32_t b7e_valid_lo = NK_RAM_BASE;
static uint32_t b7e_valid_hi = 0x80a00000u;

static int b7e_valid_ptr(uint32_t v) {
    return v >= b7e_valid_lo && v < b7e_valid_hi;
}

/* A live kernel object starts with a vtable pointer in kernel text.  This is
 * what distinguishes a real DProcess/CObjectIx/request semaphore from a
 * harness stand-in (whose first word is a data address or zero). */
static int b7e_live_object(nk_cpu_t* c, uint32_t v) {
    if (!b7e_valid_ptr(v)) return 0;
    uint32_t vt = nk_r32(c, v);
    return vt >= 0x50000000u && vt < 0x52000000u;
}

static void b7e_fill_vtable(nk_cpu_t* c, uint32_t vt, uint32_t stub) {
    for (int i = 0; i < B7E_VT_ENTRIES; i++)
        nk_w32(c, vt + 4u * (uint32_t)i, stub);
}

/* The kernel later replaces the provisional thread->process pointer with a
 * real DProcess allocated from the bring-up heap.  That process starts with a
 * null +0x38 (its CObjectIx), so every handle lookup would call
 * CObjectIx::At with this=0.  Follow the thread's process field and attach
 * the stand-in object index to whatever DProcess the kernel installs. */
static void b7e_process_hook(nk_cpu_t* c, uint32_t addr, uint32_t value) {
    if (!b7e_enabled) return;
    if (!b7e_valid_ptr(value)) {
        /* The kernel clears the process field while tearing down a thread.
         * Keep the live thread attached: the direct E32-entry boot has no
         * scheduler startup to recreate the graph. */
        nk_w32(c, addr, B7E_PROCESS);
        return;
    }
    /* Round 34: the kernel builds a real DProcess (and, in it, a real
     * CObjectIx) once the executive starts creating threads.  Only fill in
     * the handle index when the process has none: replacing a live index
     * makes CObjectIx::Remove/Close call a null vtable later. */
    if (b7e_live && b7e_valid_ptr(nk_r32(c, value + 0x38))) {
        if (b7e_installs <= 8)
            printf("B7e: process %#010x keeps live object index %#010x\n",
                   value, nk_r32(c, value + 0x38));
        return;
    }
    nk_w32(c, value + 0x38, B7E_OBJIDX);
    if (b7e_installs <= 8)
        printf("B7e: process %#010x -> object index %#010x\n",
               value, B7E_OBJIDX);
}

/* Build one real CTrapCleanup graph for a thread.  The startup that normally
 * calls CTrapCleanup::New() before user code is skipped by the direct E32
 * entry, so CleanupStack::PushL sees iTrapHandler == NULL and panics 69.
 * The handler's vtable is EUser's own TCleanupTrapHandler vtable, so Trap/
 * UnTrap/Leave run the real CCleanup level/pop code.  One level marker is
 * present because the skipped startup enters the initial TRAP before it calls
 * any code that can leave.  Slots are per thread: every published thread gets
 * its own handler and cleanup stack. */
static uint32_t b7e_trap_slot(uint32_t t) {
    for (int i = 0; i < B7E_TRAP_SLOTS; i++)
        if (b7e_trap_owner[i] == t)
            return B7E_TRAP_BASE + (uint32_t)i * B7E_TRAP_STRIDE;
    for (int i = 0; i < B7E_TRAP_SLOTS; i++)
        if (b7e_trap_owner[i] == 0) {
            uint32_t base = B7E_TRAP_BASE + (uint32_t)i * B7E_TRAP_STRIDE;
            b7e_trap_owner[i] = t;
            return base;
        }
    return 0;
}

/* [0x80000408] is the kernel's scheduler alias for the thread being
 * published/closed.  The direct E32-entry boot never runs the mask-ROM code
 * that seeds it, and the close path restores it to 0 when there was no
 * previous thread.  Keep it pointing at a live DThread so SysGetProcess/
 * thread-create bookkeeping can call its vtable. */
static void b7e_alias_hook(nk_cpu_t* c, uint32_t addr, uint32_t value) {
    if (!b7e_enabled || value) return;
    if (b7e_current_thread)
        boot_time_raw_w32(c, addr, b7e_current_thread);
}

static void b7e_thread_hook(nk_cpu_t* c, uint32_t addr, uint32_t value) {
    (void)addr;
    if (!b7e_enabled) return;
    if (!b7e_valid_ptr(value)) {
        /* A scheduler transient clears the current-thread slot before the
         * next switch.  The E32-entry boot has no real scheduler startup, so
         * a handle lookup in that window would dereference a null process.
         * Keep the last live thread published. */
        if (b7e_current_thread)
            nk_w32(c, 0x800017d4u, b7e_current_thread);
        return;
    }
    uint32_t t = value & ~3u;
    b7e_current_thread = t;
    /* Only the kernel's scheduler publishes current-thread pointers here.
     * Re-install on every switch so the graph survives a hand-off. */
    {
        uint32_t p = nk_r32(c, t + 0x18);
        uint32_t s = nk_r32(c, t + 0x5c);
        uint32_t h = nk_r32(c, t + 0x64);
        /* Round 34: a thread the kernel fully constructed already points at
         * its DProcess (+0x18), request semaphore (+0x5c) and CObjectIx
         * (+0x64).  Overwriting those with harness stand-ins is what made
         * CObjectIx::Remove call a null vtable at round 33's frontier.  Keep
         * real objects; fill in only missing ones. */
        if (b7e_live && b7e_live_object(c, p)) {
            if (b7e_installs <= 8)
                printf("B7e: thread %#010x keeps live process %#010x\n", t, p);
            if (!b7e_valid_ptr(nk_r32(c, p + 0x38)))
                nk_w32(c, p + 0x38, B7E_OBJIDX);
        } else {
            nk_w32(c, t + 0x18, B7E_PROCESS);
            p = B7E_PROCESS;
        }
        if (!(b7e_live && b7e_live_object(c, s)))
            nk_w32(c, t + 0x5c, B7E_TLS);
        else if (b7e_installs <= 8)
            printf("B7e: thread %#010x keeps request semaphore %#010x\n", t, s);
        if (!(b7e_live && b7e_live_object(c, h)))
            nk_w32(c, t + 0x64, B7E_OBJIDX);
        else if (b7e_installs <= 8)
            printf("B7e: thread %#010x keeps object index %#010x\n", t, h);
        /* The kernel's thread-create/teardown path uses [0x80000408] as the
         * thread it is publishing; the direct E32-entry boot never runs the
         * mask-ROM code that seeds it.  Keep the two scheduler aliases in
         * sync with the current thread/process. */
        if (b7e_live) {
            nk_w32(c, 0x80000408u, t);
            nk_w32(c, 0x80000404u, p);
        }
    }
    if (b7e_trapclean) {
        uint32_t base = b7e_trap_slot(t);
        if (base) {
            uint32_t handler = base + B7E_TRAPH_OFF;
            uint32_t clean = base + B7E_CLEAN_OFF;
            uint32_t clbase = base + B7E_CLBASE_OFF;
            uint32_t cltop = base + B7E_CLTOP_OFF;
            /* TCleanupTrapHandler: vptr + iCleanup. */
            nk_w32(c, handler + 0x00, B7E_TRAP_VT);
            nk_w32(c, handler + 0x04, clean);
            /* CCleanup: vptr + iBase/iTop/iNext. */
            nk_w32(c, clean + 0x00, B7E_CLEAN_VT);
            nk_w32(c, clean + 0x04, clbase);
            nk_w32(c, clean + 0x08, cltop);
            nk_w32(c, clean + 0x0c, clbase + 8);
            /* One TRAP level is already active: {operation=0, count=1}. */
            nk_w32(c, clbase + 0x00, 0);
            nk_w32(c, clbase + 0x04, 1);
            nk_w32(c, t + 0x3c, handler);   /* SThread::iTrapHandler   */
            /* Round 107: `svc 0x74` (0x50318804) returns [thread+0x58] and
             * `svc 0x75` (0x50318814) stores it back; that is the cleanup
             * stack pointer CleanupStack::PushL uses.  B7e built the CCleanup
             * graph but never published it at +0x58, so PushL saw a null
             * cleanup stack and panicked 0x2c. */
            if (!env_ulong("NK_NO_CLEANUP58", 0))
                nk_w32(c, t + 0x58, clean); /* SThread::iCleanup        */
            nk_w32(c, t + 0x38, 0);         /* SThread::iFrame         */
            /* Round 98: the kernel's UnTrap service (svc 0x73, 0x503187e8)
             * returns [thread+0x38] and pops the chain through [frame+0x40].
             * EUser then reads [frame+0x44] and [frame+0x48] and, when
             * [frame+0x48] is zero, restores a whole context with
             * `ldm r5, {r4..fp, sp, lr}` and branches through the saved LR.
             * With no frame installed (thread+0x38 == 0) that "restore"
             * reads address 0 and jumps to 0x2c.  Give the thread one
             * initial frame whose saved LR is the exit sentinel, which is
             * exactly the state the runtime would establish for a thread
             * whose outermost TRAP is the thread entry. */
            /* Round 98: the kernel's `get heap` service (svc 0x6c,
             * 0x503187b8) returns [current_thread+0x34].  B7e leaves that
             * field zero, so guest code that allocates through the thread
             * heap passes a null allocator to RHeap and, in the HLE model,
             * also loses the base used for descriptor arithmetic.
             * NK_THREAD_HEAP=<addr> publishes a heap pointer for the thread. */
            if (env_ulong("NK_THREAD_HEAP", 0)) {
                nk_w32(c, t + 0x34, (uint32_t)env_ulong("NK_THREAD_HEAP", 0));
                if (b7e_installs <= 4)
                    printf("B7e: thread %#010x heap %#010x\n", t,
                           (uint32_t)env_ulong("NK_THREAD_HEAP", 0));
            }
            if (env_ulong("NK_TRAP_FRAME", 0)) {
                uint32_t frame = base + 0x100u;
                for (uint32_t o = 0; o < 0x4cu; o += 4) nk_w32(c, frame + o, 0);
                nk_w32(c, frame + 0x24, 0xdead0000u);   /* saved LR: exit   */
                nk_w32(c, frame + 0x20, c->r[13]);      /* saved SP         */
                nk_w32(c, frame + 0x40, 0);             /* no outer frame   */
                nk_w32(c, frame + 0x48, 0);             /* no outer handler */
                nk_w32(c, t + 0x38, frame);             /* SThread::iFrame  */
                if (b7e_installs <= 4)
                    printf("B7e: thread %#010x initial trap frame %#010x "
                           "(exit through 0xdead0000)\n", t, frame);
            }
            if (b7e_installs <= 4)
                printf("B7e: thread %#010x trap handler %#010x, cleanup %#010x\n",
                       t, handler, clean);
        } else if (b7e_installs <= 4) {
            printf("B7e: no free trap/cleanup slot for thread %#010x\n", t);
        }
    }
    /* Watch the process field for the kernel's later, real DProcess. */
    nk_dbg_watch_write3(t + 0x18, b7e_process_hook);
    /* The handle path treats the result as a CObject: it needs a vtable at
     * [0].  Keep the harness object rather than the live scheduler block. */
    nk_w32(c, B7E_CUR_OBJ, B7E_THREAD);
    b7e_installs++;
    if (b7e_installs <= 4)
        printf("B7e: current thread %#010x -> process %#010x, objidx %#010x\n",
               t, B7E_PROCESS, B7E_OBJIDX);
}

static void b7e_install(nk_cpu_t* c, nk_interp_t* ip,
                        uint32_t heap_base, uint32_t heap_size) {
    if (heap_size < 0x4000u) heap_size = 0x4000u;
    /* The kernel's real DThread/DProcess are allocated from this heap, so a
     * pointer there is live, not a scheduler transient. */
    b7e_valid_hi = heap_base + heap_size;
    if (b7e_valid_hi < 0x80400000u) b7e_valid_hi = 0x80400000u;
    b7e_valid_hi = (uint32_t)env_ulong("NK_B7E_VALID_HI", b7e_valid_hi);
    b7e_trapclean = (int)env_ulong("NK_TRAPCLEAN", 0);
    b7e_live = (int)env_ulong("NK_B7E_LIVE", 0);
    /* RHeap::Alloc treats word 0 of the heap object as a base added to the
     * allocator's result, and its caller rejects results >= 0x50000000.
     * The allocator therefore returns an *offset*; the bump cursor is
     * relative to the heap base. */
    b7e_heap_cur = 0;
    b7e_heap_end = heap_size & ~0xfu;

    /* Zero-return vtable target. */
    nk_w32(c, B7E_ZERO_STUB, 0xe3a00000u);       /* mov r0,#0 */
    nk_w32(c, B7E_ZERO_STUB + 4, 0xe12fff1eu);   /* bx lr     */
    /* HAL map/channel stand-in.  The extension loader invokes an in-kernel
     * extension constructor before it registers the real HAL object; the
     * constructor calls [0x800003ac]->vtable[0x108] twice:
     *   r1=1 -> 0 is success (the map/create call)
     *   r1=0 -> a live channel object (DObject*) the driver dereferences
     * A bare integer handle is not enough for the second call: the RTC
     * driver stores it and later reads its vtable.  Return a real guest
     * object whose vtable is the HAL stub table. */
    if (b7e_live) {
        /* Round 34: Kern::Init3's startup loop asks vtable+0x108 for object
         * id 3 and retries until it gets a live DObject*; the old r1!=0
         * zero return made that loop permanent.  Keep r1=1 as the
         * map/create success code and hand back the stand-in device object
         * for every other id (0 = channel, 3 = the object Init3 waits for). */
        nk_w32(c, B7E_HAL_STUB + 0x00, 0xe3510001u); /* cmp r1,#1 */
        nk_w32(c, B7E_HAL_STUB + 0x04, 0x159f0008u); /* ldrne r0,[pc,#8] */
        nk_w32(c, B7E_HAL_STUB + 0x08, 0x03a00000u); /* moveq r0,#0 */
        nk_w32(c, B7E_HAL_STUB + 0x0c, 0xe12fff1eu); /* bx lr */
    } else {
        nk_w32(c, B7E_HAL_STUB + 0x00, 0xe3510000u); /* cmp r1,#0 */
        nk_w32(c, B7E_HAL_STUB + 0x04, 0x059f0008u); /* ldreq r0,[pc,#8] */
        nk_w32(c, B7E_HAL_STUB + 0x08, 0x13a00000u); /* movne r0,#0 */
        nk_w32(c, B7E_HAL_STUB + 0x0c, 0xe12fff1eu); /* bx lr */
    }
    nk_w32(c, B7E_HAL_STUB + 0x14, B7E_HAL_CHAN);
    nk_w32(c, B7E_ONE_STUB, 0xe3a00001u);        /* mov r0,#1 */
    nk_w32(c, B7E_ONE_STUB + 4, 0xe12fff1eu);    /* bx lr     */
    /* App wait HLE: the EUser WaitForAnyRequest wrapper keeps its
     * TRequestStatus in r5.  Complete that status and return 0 so the
     * wrapper's "still pending?" loop exits.  Opt-in (NK_WAIT_HLE=1). */
    nk_w32(c, B7E_WAIT_STUB, 0xe3a00000u);       /* mov r0,#0 */
    nk_w32(c, B7E_WAIT_STUB + 4, 0xe5850000u);   /* str r0,[r5] */
    nk_w32(c, B7E_WAIT_STUB + 8, 0xe12fff1eu);   /* bx lr     */
    /* Round 62: complete the thread-start request passed in r3.  The app
     * (SplashScreen) calls Kern::StartThread (SVC 0x76) through the EUser
     * rendezvous wrapper and then polls the status.  The bring-up thread
     * object has no real DThread hand-off, so vtable+0x20 used to return
     * without completing [r3]; the app spun forever.  This opt-in HLE
     * completes the request so the app can proceed to its next frontier. */
    nk_w32(c, B7E_START_STUB, 0xe3a00000u);      /* mov r0,#0 */
    nk_w32(c, B7E_START_STUB + 4, 0xe5830000u);  /* str r0,[r3] */
    nk_w32(c, B7E_START_STUB + 8, 0xe12fff1eu);  /* bx lr     */
    /* Round 34: Kern::Init3 gets object 3 from the HAL and issues Request
     * 0xd, then polls [0x800004cc] until it is non-zero.  On the real phone
     * the device driver completes that request (its DFC/ISR calls the
     * kernel export at 0x50336284, which stores the owner).  The stand-in
     * device has no driver behind it, so complete the request here: set the
     * gate and return 1.  This is an explicit HAL HLE, not guest code. */
    nk_w32(c, B7E_HAL_REQ + 0x00, 0xe3a03001u);  /* mov r3,#1           */
    nk_w32(c, B7E_HAL_REQ + 0x04, 0xe59f2008u);  /* ldr r2,[pc,#8]      */
    nk_w32(c, B7E_HAL_REQ + 0x08, 0xe5823000u);  /* str r3,[r2]         */
    nk_w32(c, B7E_HAL_REQ + 0x0c, 0xe3a00001u);  /* mov r0,#1           */
    nk_w32(c, B7E_HAL_REQ + 0x10, 0xe12fff1eu);  /* bx lr               */
    nk_w32(c, B7E_HAL_REQ + 0x14, 0x800004ccu);  /* literal             */
    nk_code_range_add(ip, B7E_HAL_REQ, B7E_HAL_REQ + 0x18);
    nk_code_range_add(ip, B7E_ZERO_STUB, B7E_ZERO_STUB + 8);
    nk_code_range_add(ip, B7E_ONE_STUB, B7E_ONE_STUB + 8);
    nk_code_range_add(ip, B7E_WAIT_STUB, B7E_WAIT_STUB + 12);
    nk_code_range_add(ip, B7E_START_STUB, B7E_START_STUB + 12);
    nk_code_range_add(ip, B7E_HAL_STUB, B7E_HAL_STUB + 0x18);
    nk_code_range_add(ip, B7E_ALLOC_STUB, B7E_ALLOC_STUB + 0x20);
    nk_code_range_add(ip, B7E_AT_STUB, B7E_AT_STUB + 0x20);

    /* RAllocator-style bump allocator (r0 = TAny** aResult, r2 = aSize).
     * The result word is an offset; the caller adds its base at [heap+0]. */
    nk_w32(c, B7E_ALLOC_STUB + 0x00, 0xe59f3028u);  /* ldr r3,[pc,#0x28] */
    nk_w32(c, B7E_ALLOC_STUB + 0x04, 0xe593c000u);  /* ldr r12,[r3]      */
    nk_w32(c, B7E_ALLOC_STUB + 0x08, 0xe282200fu);  /* add r2,r2,#15     */
    nk_w32(c, B7E_ALLOC_STUB + 0x0c, 0xe3c2200fu);  /* bic r2,r2,#15     */
    nk_w32(c, B7E_ALLOC_STUB + 0x10, 0xe082200cu);  /* add r2,r12,r2     */
    nk_w32(c, B7E_ALLOC_STUB + 0x14, 0xe5832000u);  /* str r2,[r3]       */
    nk_w32(c, B7E_ALLOC_STUB + 0x18, 0xe580c000u);  /* str r12,[r0]      */
    nk_w32(c, B7E_ALLOC_STUB + 0x1c, 0xe12fff1eu);  /* bx lr             */
    nk_w32(c, B7E_ALLOC_LIT, B7E_CURSOR);
    nk_w32(c, B7E_CURSOR, b7e_heap_cur);

    /* CObjectIx element fetch -> the live current-thread object.  The real
     * At() calls this through an array vtable slot with r0 = TDes8* aResult:
     * it must receive a *descriptor*, not a bare pointer, because the caller
     * then calls TDesC8::Ptr() (0x5038891c) on it.  A TPtrC8 header plus the
     * object pointer makes Ptr() return the live object. */
    nk_w32(c, B7E_AT_STUB + 0x00, 0xe59f2010u);  /* ldr r2,[pc,#0x10]   */
    nk_w32(c, B7E_AT_STUB + 0x04, 0xe5802000u);  /* str r2,[r0]         */
    nk_w32(c, B7E_AT_STUB + 0x08, 0xe59f100cu);  /* ldr r1,[pc,#0xc]    */
    nk_w32(c, B7E_AT_STUB + 0x0c, 0xe5911000u);  /* ldr r1,[r1]         */
    nk_w32(c, B7E_AT_STUB + 0x10, 0xe5801004u);  /* str r1,[r0,#4]      */
    nk_w32(c, B7E_AT_STUB + 0x14, 0xe12fff1eu);  /* bx lr               */
    nk_w32(c, B7E_AT_STUB + 0x18, 0x10000004u);  /* TPtrC8, length 4    */
    nk_w32(c, B7E_AT_STUB + 0x1c, B7E_CUR_OBJ);  /* literal             */
    /* Return the harness CObject (B7E_THREAD), not the live scheduler
     * pointer: the caller treats the result as a CObject and reads its
     * vtable at [0].  The live 0x802ffd00 stack block has no vtable. */
    nk_w32(c, B7E_CUR_OBJ, B7E_THREAD);

    b7e_fill_vtable(c, B7E_VT_PROCESS, B7E_ZERO_STUB);
    b7e_fill_vtable(c, B7E_VT_ALLOC, B7E_ZERO_STUB);
    b7e_fill_vtable(c, B7E_VT_ARRAY, B7E_ZERO_STUB);
    nk_w32(c, B7E_VT_ALLOC + 0x14, B7E_ALLOC_STUB);
    nk_w32(c, B7E_VT_ARRAY + 0x14, B7E_AT_STUB);

    nk_w32(c, B7E_PROCESS, B7E_VT_PROCESS);
    nk_w32(c, B7E_PROCESS + 0x38, B7E_OBJIDX);

    /* CObjectIx: [0] base, [0xc] count/base, [0x14] element size,
     * [0x18] the array object. */
    nk_w32(c, B7E_OBJIDX + 0x00, 0);
    nk_w32(c, B7E_OBJIDX + 0x0c, 0);
    nk_w32(c, B7E_OBJIDX + 0x14, 4);
    nk_w32(c, B7E_OBJIDX + 0x18, B7E_ARRAY);
    nk_w32(c, B7E_ARRAY, B7E_VT_ARRAY);

    nk_w32(c, B7E_ALLOC, B7E_VT_ALLOC);
    nk_w32(c, B7E_ALLOC + 0x00, heap_base);   /* base added to offset  */
    nk_w32(c, B7E_ALLOC + 0x14, 1);           /* element size          */

    nk_w32(c, B7E_THREAD, 0x80003040u);       /* thread vtable         */
    nk_w32(c, B7E_THREAD + 0x14, 1);
    b7e_fill_vtable(c, 0x80003040u, B7E_ZERO_STUB);
    nk_w32(c, 0x80003040u + 0x20,
           env_ulong("NK_START_HLE", 0) ? B7E_START_STUB : B7E_ZERO_STUB);
    if (env_ulong("NK_START_HLE", 0))
        printf("thread-start HLE: bring-up DThread vtable+0x20 completes [r3] "
               "via stub %#010x\n", B7E_START_STUB);

    /* Kernel HAL stand-in.  The extension loader invokes an in-kernel
     * extension constructor before it registers the real HAL object; the
     * constructor calls [0x800003ac]->vtable[0x108] twice:
     *   r1=1 -> 0 is success, r1=0 -> nonzero is the channel handle.
     * A zero vtable would leave the image and die at pc=0. */
    for (int i = 0; i < 128; i++)
        nk_w32(c, B7E_VT_HAL + 4u * i, B7E_ZERO_STUB);
    nk_w32(c, B7E_VT_HAL + 0x108u, B7E_HAL_STUB);  /* HAL map/channel */
    if (b7e_live)
        nk_w32(c, B7E_VT_HAL + 0x48u, B7E_HAL_REQ); /* device Request */
    nk_w32(c, B7E_HAL, B7E_VT_HAL);
    /* The channel handle call (r1=0) must return a dereferenceable object. */
    nk_w32(c, B7E_HAL_CHAN, B7E_VT_HAL);
    nk_w32(c, 0x800003acu, B7E_HAL);          /* Kern::TheKernel/HAL global */

    /* The thread object at [thread+0x5c] is dereferenced through vtable+0x24
     * when the scheduler completes a request on the current thread.  A zero
     * return is treated as failure and raises USER-EXEC 3, so report success. */
    b7e_fill_vtable(c, B7E_VT_TLS, B7E_ZERO_STUB);
    nk_w32(c, B7E_VT_TLS + 0x24, B7E_ONE_STUB);
    if (env_ulong("NK_WAIT_HLE", 0))
        nk_w32(c, B7E_VT_TLS + 0x20, B7E_WAIT_STUB);
    nk_w32(c, B7E_TLS, B7E_VT_TLS);

    printf("B7e boot state: thread %#010x, process %#010x, objidx %#010x, "
           "bump %#010x..%#010x, live pointers %#010x..%#010x\n",
           B7E_THREAD, B7E_PROCESS, B7E_OBJIDX,
           heap_base + b7e_heap_cur, heap_base + b7e_heap_end,
           b7e_valid_lo, b7e_valid_hi);
}

/* ------------------------------------------------------------------ */
/* EKA1 ROM image loader                                               */
/*                                                                     */
/* The packed flash stores each ROM image as one record:                */
/*   TRomImageHeader (0x64)                                            */
/*   .text            iTextSize          -> iCodeAddress               */
/*   .rdata           (not relocated)                                  */
/*   .data            iDataSize          -> iDataAddress / RAM base    */
/*   .edata           iExportDirCount*4  -> iExportDir                 */
/*   TDllRefTable     (if iDllRefTable)                                */
/* The record ends immediately before the next TRomImageHeader, so the */
/* sections are located backwards from there instead of from the        */
/* packed file offset (which is unrelated to the runtime address).      */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t*  rom;
    long      len;
    nk_cpu_t* cpu;
    nk_interp_t* ip;
    long      loaded[32];             /* header file offsets already loaded */
    int       nloaded;
} rom_loader_t;

static int is_e32_header(const uint8_t* rom, long len, long o) {
    /* Packed records are only 2-byte aligned; the ROM build removed the
     * linker's 4-byte padding, so a header can start at 2 mod 4. */
    if (o < 0 || o + 0x70 > len || (o & 1)) return 0;
    uint32_t uid1 = u32(rom + o);
    if (uid1 != 0x10000079u && uid1 != 0x1000007au) return 0;
    uint32_t uid2 = u32(rom + o + 4);
    uint32_t uid3 = u32(rom + o + 8);
    uint32_t entry = u32(rom + o + 0x10);
    uint32_t code = u32(rom + o + 0x14);
    uint32_t csize = u32(rom + o + 0x1c);
    uint32_t text = u32(rom + o + 0x20);
    if (uid2 < 0x10000000u || uid2 > 0x10200000u) return 0;
    if (uid3 == 0) return 0;
    if (entry < 0x50000000u || entry >= 0x52000000u) return 0;
    if (code < 0x50000000u || code >= 0x52000000u) return 0;
    if (csize < 0x40u || csize > 0x1000000u) return 0;
    if (text == 0 || text > csize) return 0;
    return 1;
}

static long next_e32_header(const uint8_t* rom, long len, long after) {
    for (long o = (after + 1) & ~1L; o + 0x70 <= len; o += 2)
        if (is_e32_header(rom, len, o)) return o;
    return len;
}

static long header_for_code(const uint8_t* rom, long len, uint32_t code) {
    for (long o = 0; o + 0x70 <= len; o += 2) {
        if (!is_e32_header(rom, len, o)) continue;
        if (u32(rom + o + 0x14) == code) return o;
    }
    return -1;
}

static int load_image(rom_loader_t* L, long hdr, int depth) {
    const uint8_t* rom = L->rom;
    long len = L->len;
    for (int i = 0; i < L->nloaded; i++)
        if (L->loaded[i] == hdr) return 0;
    if (L->nloaded >= 32) return 0;
    L->loaded[L->nloaded++] = hdr;

    uint32_t uid3 = u32(rom + hdr + 0x08);
    uint32_t code = u32(rom + hdr + 0x14);
    uint32_t data_addr = u32(rom + hdr + 0x18);
    uint32_t text_size = u32(rom + hdr + 0x20);
    uint32_t data_size = u32(rom + hdr + 0x24);
    uint32_t bss_size = u32(rom + hdr + 0x28);
    uint32_t dll_addr = u32(rom + hdr + 0x38);
    uint32_t exp_count = u32(rom + hdr + 0x3c);
    uint32_t exp_addr = u32(rom + hdr + 0x40);
    uint32_t ram_base = u32(rom + hdr + 0x58);

    long next = next_e32_header(rom, len, hdr + 0x64);
    if (next <= hdr + 0x64) next = len;

    long dll_off = next, dll_size = 0;
    if (dll_addr && next - 4 >= hdr && u32(rom + next - 4) == 0xffffffffu) {
        for (unsigned c = 1; c <= 32; c++) {
            long start = next - 4 - (long)c * 8 - 4;
            if (start < hdr + 0x64) break;
            uint32_t w = u32(rom + start);
            if ((w >> 16) == c) {             /* {u16 flags; u16 count} */
                dll_off = start;
                dll_size = next - start;
                break;
            }
        }
    }
    long exp_off = next - dll_size - (long)exp_count * 4;
    long data_off = exp_off - (long)data_size;

    printf("image uid3 %#010x @%#lx: text %#x->%#010x, data %#x->%#010x, "
           "exp %u->%#010x (file %#lx), dllref %s (file %#lx, %#lx bytes)\n",
           uid3, hdr, text_size, code, data_size, data_addr,
           exp_count, exp_addr, exp_off, dll_addr ? "yes" : "none",
           dll_off, dll_size);

    if (exp_off < hdr + 0x64 || exp_off + (long)exp_count * 4 > len) {
        fprintf(stderr, "  bad section layout; skipping\n");
        return -1;
    }
    nk_poke(L->cpu, code, rom + hdr + 0x64, text_size);
    if (L->ip) nk_code_range_add(L->ip, code, code + text_size);
    if (data_size && data_addr)
        nk_poke(L->cpu, data_addr, rom + data_off, data_size);
    if (data_size && ram_base)
        nk_poke(L->cpu, ram_base, rom + data_off, data_size);
    if (bss_size && ram_base)
        for (uint32_t i = 0; i < bss_size; i++)
            nk_w8(L->cpu, ram_base + data_size + i, 0);
    if (exp_count && exp_addr) {
        nk_poke(L->cpu, exp_addr, rom + exp_off, exp_count * 4);
        /* Export entries are absolute post-link addresses; when the ROM
         * builder's interworking veneer is missing, they point a few bytes
         * into the function.  Snap each in-image export to its prologue so
         * the import stubs land on real entry points. */
        unsigned fixed = 0;
        for (uint32_t i = 0; i < exp_count; i++) {
            uint32_t v = nk_r32(L->cpu, exp_addr + i * 4);
            if (v < code || v >= code + text_size) continue;
            uint32_t s = nk_snap_entry(L->cpu, v);
            if (s != v) {
                if (fixed < 6)
                    printf("  export[%u] %#010x -> %#010x\n", i, v, s);
                nk_w32(L->cpu, exp_addr + i * 4, s);
                fixed++;
            }
        }
        if (fixed) printf("  snapped %u export entries\n", fixed);
    }
    if (dll_size)
        nk_poke(L->cpu, dll_addr, rom + dll_off, (uint32_t)dll_size);

    /* Load every referenced DLL (the entries are 8 bytes; the first word is
     * the referenced image's code address). */
    if (dll_size >= 4 && depth < 4) {
        uint32_t count = u32(rom + dll_off) >> 16;
        for (uint32_t i = 0; i < count && 4 + i * 8 + 4 <= (uint32_t)dll_size; i++) {
            uint32_t ref = u32(rom + dll_off + 4 + i * 8);
            long rh = header_for_code(rom, len, ref);
            if (rh >= 0) load_image(L, rh, depth + 1);
            else fprintf(stderr, "  dllref %#010x: no matching image\n", ref);
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* flat runtime-image loader (out/6600_runtime.bin)                    */
/*                                                                     */
/* `recompiler/romimage.py build` places every plausible ROM image and */
/* the ROMFS directories at their runtime addresses.  Headers sit at   */
/* code-0x64, so the loader can recover data/RAM placement without the */
/* packed-record tables.  Call repair stays conservative by default:   */
/* only the kernel and the DLLs named by its TDllRefTable are declared */
/* executable (NK_RANGE_ALL=1 additionally accepts every image).       */
/* ------------------------------------------------------------------ */

#define NK_MAX_IMAGES 1024

typedef struct {
    uint32_t uid3, entry, code, text, data, dsize, bss, ram, hdr_va;
    uint32_t edata, exp_count;
} rom_image_t;

static uint32_t g_kernel_code;

/* ---- flat-image import binding ------------------------------------- *
 *
 * A ROM image imports through a two-instruction stub:
 *     ldr ip, [pc]      ; e59fc000
 *     ldr pc, [ip]      ; e59cf000
 *     .word <slot>      ; exporting image's export-table entry
 *
 * The slot itself is authoritative: a valid export already holds the bound
 * code address, so a flat image normally needs no work.  The remaining cases
 * are export-table holes (`0xffffffff`): 6600's ELocl.dll leaves ordinal 20
 * unimplemented while the kernel's locale initialiser still calls it.  Such a
 * slot can only be bound by an explicit bring-up override (NK_IMPORTMAP),
 * which keeps the workaround visible instead of silently returning 0.
 */

typedef struct {
    uint32_t slot, target;
    int thumb;
} import_override_t;

/* Round 27 relocates every kernel EUser import (236 slots) instead of a
 * handful, so the table must hold the whole map. */
#define NK_MAX_IMPORT_OVERRIDES 512

static int load_import_overrides(const char* path, import_override_t* out,
                                 int max) {
    FILE* f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open import map %s\n", path); return 0; }
    char line[256];
    int n = 0;
    while (n < max && fgets(line, sizeof line, f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '\n' || *p == '#' ||
            (p[0] == '/' && p[1] == '/')) continue;
        char* end = NULL;
        unsigned long slot = strtoul(p, &end, 0);
        if (end == p) continue;
        p = end;
        while (*p == ' ' || *p == '\t') p++;
        unsigned long target;
        if (p[0] == 'z' || p[0] == 'Z') {
            target = 0xffff0100u;          /* synthesized zero-return stub */
        } else {
            target = strtoul(p, &end, 0);
            if (end == p) continue;
        }
        out[n].slot = (uint32_t)slot;
        out[n].target = (uint32_t)target;
        out[n].thumb = 0;
        n++;
    }
    fclose(f);
    printf("import map %s: %d slot overrides\n", path, n);
    return n;
}

static int flat_has_override(const import_override_t* ov, int n, uint32_t slot,
                             uint32_t* target) {
    for (int i = 0; i < n; i++) {
        if (ov[i].slot == slot) { *target = ov[i].target; return 1; }
    }
    return 0;
}

/* Does `v` point at executable code in the flat image?  Both ROM images and
 * the synthesized high-vector stub page count. */
static int flat_in_code(const rom_image_t* imgs, int nimg, uint32_t v) {
    v &= ~1u;
    for (int i = 0; i < nimg; i++)
        if (v >= imgs[i].code && v < imgs[i].code + imgs[i].text) return 1;
    if (v >= NK_HIGH_VECTORS && v < NK_HIGH_VECTORS + 0x10000u) return 1;
    return 0;
}

static int flat_slot_owner(const rom_image_t* imgs, int nimg, uint32_t slot,
                           uint32_t* uid3, uint32_t* ordinal) {
    for (int i = 0; i < nimg; i++) {
        if (imgs[i].edata && slot >= imgs[i].edata &&
            slot < imgs[i].edata + imgs[i].exp_count * 4u) {
            *uid3 = imgs[i].uid3;
            *ordinal = (slot - imgs[i].edata) / 4u;
            return 1;
        }
    }
    return 0;
}

/* Round 95: NK_IMPORTMAP rebinds EUser export-table slots, and EUser's
 * export table doubles as the import slot table for every ROM image.  A map
 * built for the kernel therefore also rewrites the slots an application
 * imports, so an app thread called the wrong EUser function with its own
 * arguments (EFile passed pointers where lengths were expected).  Record the
 * original values while patching and restore them when an app thread starts. */
#define NK_MAP_REVERT_MAX 2048
static uint32_t g_map_revert_addr[NK_MAP_REVERT_MAX];
static uint32_t g_map_revert_old[NK_MAP_REVERT_MAX];
static int      g_map_revert_n;
static int      g_map_revert_done;

static void importmap_revert(nk_cpu_t* c);

/* Round 99: a few EUser export slots must keep the kernel-time rebind even
 * for an application thread.  The handle -> object lookup is the first one:
 * the object index at 0x80600e98 is built by the kernel (constructor
 * 0x50384d44 installs vtable 0x503b36f8, iCount=1 at +0x10, and leaves the
 * entry array at +0x14 null until something is registered).  The ROM's
 * At (0x50380270) dereferences that null array and jumps to 0x3a, while the
 * kernel build's variant (0x5038e4b4) reads a count that is zero and returns
 * 0 safely.  NK_IMPORTMAP_NO_REVERT=<hex,...> lists slots that keep the
 * kernel-time value. */
static int importmap_keep_slot(uint32_t slot) {
    const char* list = getenv("NK_IMPORTMAP_NO_REVERT");
    if (!list) return 0;
    while (*list) {
        char* end = NULL;
        unsigned long v = strtoul(list, &end, 0);
        if (end == list) break;
        if ((uint32_t)v == slot) return 1;
        list = end;
        while (*list == ',' || *list == ' ' || *list == '\t') list++;
    }
    return 0;
}

static void importmap_revert(nk_cpu_t* c) {
    if (g_map_revert_done) return;
    g_map_revert_done = 1;
    if (g_map_revert_n) {
        for (int i = 0; i < g_map_revert_n; i++)
            nk_w32(c, g_map_revert_addr[i], g_map_revert_old[i]);
        printf("importmap: reverted %d kernel-time rebinds for the app thread\n",
               g_map_revert_n);
    }
    /* Round 104: the ROM's EUser export table is shifted by three relative
     * to the .def that the ROM's applications were linked against.  Evidence:
     * every application calls slot 0x503b37c4 (table entry 12) with a single
     * pointer argument, but entry 12 holds 0x503988a8, a three-argument heap
     * grow.  Three entries lower, entry 9 = 0x5037fca0, is exactly a
     * one-argument CleanupStack::PushL (it takes r0, resolves the thread's
     * cleanup stack and panics 0x2c/0x30 on null).  The kernel map encodes the
     * same K -> K-3 rule, so NK_EUSER_ROTATE=<n> shifts the whole table. */
    {
        uint32_t rot = (uint32_t)env_ulong("NK_EUSER_ROTATE", 0);
        if (rot) {
            uint32_t edata = (uint32_t)env_ulong("NK_EUSER_EDATA", 0x503b3794u);
            uint32_t n = (uint32_t)env_ulong("NK_EUSER_EXPORTS", 1788u);
            if (n > 2048) n = 2048;
            uint32_t from = (uint32_t)env_ulong("NK_EUSER_ROTATE_FROM", 6);
            static uint32_t tmp[2048];
            for (uint32_t i = 0; i < n; i++) tmp[i] = nk_r32(c, edata + 4 * i);
            for (uint32_t i = from; i < n && i >= rot; i++)
                nk_w32(c, edata + 4 * i, tmp[i - rot]);
            printf("euser: rotated export entries %u..%u by %u\n", from, n - 1,
                   rot);
        }
    }
    /* Round 103: an application that was linked against a different EUser
     * .def revision needs its own rebinds, applied after the kernel-time ones
     * are reverted.  NK_IMPORTMAP_APP=<file> uses the same "<slot> <target>"
     * format as NK_IMPORTMAP. */
    const char* app = getenv("NK_IMPORTMAP_APP");
    if (app) {
        import_override_t ov[NK_MAX_IMPORT_OVERRIDES];
        int n = load_import_overrides(app, ov, NK_MAX_IMPORT_OVERRIDES);
        int applied = 0;
        for (int i = 0; i < n; i++) {
            uint32_t old = nk_r32(c, ov[i].slot);
            nk_w32(c, ov[i].slot, ov[i].target);
            if (old != ov[i].target) applied++;
        }
        printf("importmap: applied %d application rebinds from %s\n",
               applied, app);
    }
}

static void bind_flat_imports(nk_cpu_t* cpu, nk_interp_t* ip,
                              const rom_image_t* imgs, int nimg,
                              const uint8_t* flat, long len) {
    import_override_t ov[NK_MAX_IMPORT_OVERRIDES];
    int nov = 0;
    const char* map = getenv("NK_IMPORTMAP");
    if (map) nov = load_import_overrides(map, ov, NK_MAX_IMPORT_OVERRIDES);
    int zero_stub = 0;
    int total = 0, bound = 0, patched = 0, unresolved = 0, logged = 0;

    for (int i = 0; i < nimg; i++) {
        uint32_t code = imgs[i].code, size = imgs[i].text;
        if (code < NK_FLASH_BASE || code + size > NK_FLASH_BASE + (uint32_t)len)
            continue;
        const uint8_t* t = flat + (code - NK_FLASH_BASE);
        for (uint32_t o = 0; o + 12 <= size; o += 4) {
            uint32_t w0 = u32(t + o), w1 = u32(t + o + 4);
            if (w1 != 0xe59cf000u || (w0 & 0xfffff000u) != 0xe59fc000u)
                continue;
            uint32_t slot = u32(t + o + 8 + (w0 & 0xfffu));
            uint32_t owner, ord;
            if (!flat_slot_owner(imgs, nimg, slot, &owner, &ord)) continue;
            total++;
            uint32_t v = nk_r32(cpu, slot);
            uint32_t target;
            if (flat_has_override(ov, nov, slot, &target)) {
                /* An explicit override wins even for a slot that already
                 * holds a code address.  The EKA1 ROM links a few import
                 * slots against a different EUser .def revision than the
                 * EUser image in the same ROM; those slots need a rebind to
                 * the function the call site actually uses. */
                if (target == 0xffff0100u && !zero_stub) {
                    /* mov r0,#0 ; bx lr */
                    nk_w32(cpu, target, 0xe3a00000u);
                    nk_w32(cpu, target + 4, 0xe12fff1eu);
                    nk_code_range_add(ip, target, target + 8);
                    zero_stub = 1;
                }
                if (getenv("NK_IMPORTMAP_REVERT") &&
                    g_map_revert_n < NK_MAP_REVERT_MAX &&
                    v != target &&
                    !importmap_keep_slot(slot)) {
                    g_map_revert_addr[g_map_revert_n] = slot;
                    g_map_revert_old[g_map_revert_n] = v;
                    g_map_revert_n++;
                }
                nk_w32(cpu, slot, target);
                patched++;
                if (patched <= 64)
                    printf("  import rebind: %#010x (uid %#010x ord %u) "
                           "%#010x -> %#010x\n", slot, owner, ord, v, target);
                continue;
            }
            if (flat_in_code(imgs, nimg, v)) { bound++; continue; }
            {
                unresolved++;
                if (logged++ < 12)
                    printf("  import unresolved: slot %#010x (uid %#010x "
                           "ord %u) = %#010x, stub %#010x\n",
                           slot, owner, ord, v, code + o);
            }
        }
    }
    printf("imports: %d stubs (%d bound, %d patched, %d unresolved)\n",
           total, bound, patched, unresolved);
    if (unresolved)
        printf("  hint: NK_IMPORTMAP=config/imports-6600.txt binds export-table "
               "holes for bring-up\n");
}

static uint32_t rom_image_prepare(nk_cpu_t* cpu, nk_interp_t* ip,
                                  const uint8_t* img, long len, int verbose) {
    static rom_image_t images[NK_MAX_IMAGES];
    int nimg = 0;
    uint32_t kernel_entry = 0, kernel_hdr = 0;
    g_kernel_code = 0;

    /* Packed records are only 2-byte aligned (the ROM build removed the
     * linker's 4-byte padding), so headers can sit at 2 mod 4.  Scanning by 4
     * used to miss those images entirely. */
    for (uint32_t h = NK_FLASH_BASE;
         h + 0x64 < NK_FLASH_BASE + (uint32_t)len && nimg < NK_MAX_IMAGES; h += 2) {
        const uint8_t* p = img + (h - NK_FLASH_BASE);
        uint32_t uid1 = u32(p);
        if (uid1 != 0x10000079u && uid1 != 0x1000007au) continue;
        uint32_t uid3 = u32(p + 0x08);
        uint32_t entry = u32(p + 0x10);
        uint32_t code = u32(p + 0x14);
        uint32_t data = u32(p + 0x18);
        uint32_t csize = u32(p + 0x1c);
        uint32_t tsize = u32(p + 0x20);
        uint32_t dsize = u32(p + 0x24);
        uint32_t bss = u32(p + 0x28);
        uint32_t ram = u32(p + 0x58);
        if (code != h + 0x64) continue;
        if (code < NK_FLASH_BASE || tsize == 0 ||
            code + tsize > NK_FLASH_BASE + (uint32_t)len) continue;
        if (csize < tsize || dsize > 0x1000000 || bss > 0x1000000) continue;
        rom_image_t* ri = &images[nimg++];
        ri->uid3 = uid3; ri->entry = entry; ri->code = code; ri->text = tsize;
        ri->data = data; ri->dsize = dsize; ri->bss = bss; ri->ram = ram;
        ri->edata = u32(p + 0x40);
        ri->exp_count = u32(p + 0x3c);
        ri->hdr_va = h;
        /* Copy .data/.bss into RAM only for images whose RAM window is the
         * 6600 kernel window.  Other images carry placeholder bases such as
         * 0x00400000 (unmapped here); writing there would only fill the MMIO
         * log with noise. */
        if (ram >= NK_RAM_BASE && ram < NK_RAM_BASE + NK_RAM_SIZE) {
            if (data >= NK_FLASH_BASE && data + dsize <= NK_FLASH_BASE + (uint32_t)len) {
                for (uint32_t i = 0; i < dsize; i++)
                    nk_w8(cpu, ram + i, img[data - NK_FLASH_BASE + i]);
                for (uint32_t i = 0; i < bss; i++)
                    nk_w8(cpu, ram + dsize + i, 0);
            }
        }
        if (uid3 == 0x100058e8u) {
            kernel_entry = entry; kernel_hdr = h; g_kernel_code = code;
        }
    }

    /* Executable ranges: boot block + kernel + the kernel's direct DLL refs. */
    int ranges = 0;
    if (ip) {
        nk_code_range_add(ip, NK_FLASH_BASE, NK_FLASH_BASE + 0x10000);
        ranges = 1;
        int all = getenv("NK_RANGE_ALL") != NULL;
        uint32_t refs[32];
        int nrefs = 0;
        if (kernel_hdr) {
            const uint8_t* kp = img + (kernel_hdr - NK_FLASH_BASE);
            uint32_t dll = u32(kp + 0x38);
            if (dll >= NK_FLASH_BASE && dll + 8 <= NK_FLASH_BASE + (uint32_t)len) {
                const uint8_t* dp = img + (dll - NK_FLASH_BASE);
                uint32_t count = u32(dp) >> 16;
                if (count > 32) count = 32;
                for (uint32_t i = 0; i < count; i++) {
                    uint32_t ref = u32(dp + 4 + i * 8);
                    if (nrefs < 32) refs[nrefs++] = ref;
                }
            }
        }
        for (int i = 0; i < nimg; i++) {
            int keep = all;
            for (int r = 0; r < nrefs && !keep; r++)
                if (images[i].code == refs[r]) keep = 1;
            if (images[i].code == (kernel_hdr ? kernel_hdr + 0x64 : 0)) keep = 1;
            if (keep && nk_code_range_add(ip, images[i].code,
                                          images[i].code + images[i].text))
                ranges++;
        }
    }

    /* Resolve the import stubs of the images that are actually executable.
     * A flat image already has every real export bound; only export-table
     * holes need the explicit NK_IMPORTMAP override. */
    if (ip)
        bind_flat_imports(cpu, ip, images, nimg, img, len);
    if (verbose)
        printf("runtime image: %d images, %d code ranges"
               " (NK_RANGE_ALL=1 to accept every image)\n", nimg, ranges);
    if (verbose) {
        for (int i = 0; i < nimg; i++)
            if (images[i].uid3 == 0x100058e8u || i < 3)
                printf("  uid3 %#010x @ %#010x: text %#x, entry %#010x, "
                       "ram %#010x (+%#x data, +%#x bss)\n",
                       images[i].uid3, images[i].code, images[i].text,
                       images[i].entry, images[i].ram, images[i].dsize,
                       images[i].bss);
    }
    return kernel_entry;
}

int main(int argc, char** argv) {
    const char* rom_path = argc > 1 ? argv[1] : "6600_mcu.bin";
    const char* kern_path = argc > 2 ? argv[2] : "fw/6600_kernel.bin";
    const char* rom_image = NULL;
    long e32 = -1;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--e32") && i + 1 < argc) e32 = strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--rom-image") && i + 1 < argc) rom_image = argv[++i];
    }

    long rom_len = 0;
    uint8_t* rom = read_file(rom_path, &rom_len);
    if (!rom) return 1;

    nk_cpu_t cpu;
    memset(&cpu, 0, sizeof cpu);
    if (nk_mem_init(&cpu) != 0) { fprintf(stderr, "mem init failed\n"); return 1; }

    /* Sparse map: ROM at its link address, RAM, high vectors. */
    if (!cpu.pages) return 1;
    uint32_t rom_pages = (uint32_t)((rom_len + NK_PAGE_MASK) & ~NK_PAGE_MASK);
    uint8_t* rom_copy = (uint8_t*)calloc(1, rom_pages);
    memcpy(rom_copy, rom, (size_t)rom_len);
    if (nk_map_region(&cpu, NK_FLASH_BASE, rom_pages, rom_copy) != 0) return 1;
    /* The EKA1 header's kern_limit (0x80300000) bounds *kernel data*, not the
     * physical RAM the boot loader may use for its page tables, heap and
     * super page.  NK_RAM_EXTRA lets a mask-ROM stand-in model more RAM. */
    uint32_t ram_size = NK_RAM_SIZE +
        (uint32_t)env_ulong("NK_RAM_EXTRA", 0);
    if (nk_alloc_ram(&cpu, NK_RAM_BASE, ram_size) != 0) return 1;
    nk_set_stack_ram_top(NK_RAM_BASE + ram_size);
    /* The EKA1 kernel entry runs before the MMU remaps RAM to 0x80000000;
     * its early literal pools contain physical data offsets (0x0004_6564,
     * 0x0004_6fca), so the bootstrap view needs RAM at 0x00000000 too. */
    if (!getenv("NK_NO_LOW_RAM") &&
        nk_alloc_ram(&cpu, 0x00000000u, ram_size) != 0) return 1;
    /* The EKA1 kernel uses memory directly below the RAM base for its
     * exception stack / super page (SP starts at 0x7ffffc58 and descends).
     * Model a 1 MiB window so the early stack does not fall through to the
     * MMIO log; the real page-table/super-page setup is still a frontier. */
    if (!getenv("NK_NO_SUPER_PAGE") &&
        nk_alloc_ram(&cpu, 0x7ff00000u, 0x100000) != 0) return 1;
    if (nk_alloc_ram(&cpu, NK_HIGH_VECTORS, 0x10000) != 0) return 1;
    /* Bring-up heap for the callmap's NK_HLE_ALLOC entries.  Keep it above
     * the RAM window when NK_RAM_EXTRA extends RAM past 0x80400000. */
    uint32_t hle_heap = NK_RAM_BASE + ram_size;
    if (hle_heap < 0x80400000u) hle_heap = 0x80400000u;
    if (nk_alloc_ram(&cpu, hle_heap, 0x400000u) != 0) return 1;

    if (env_ulong("NK_SUPERPAGE", 0)) {
        uint32_t sb = (uint32_t)env_ulong("NK_SUPERPAGE_BASE", 0x40000000u);
        uint32_t total = (uint32_t)env_ulong("NK_SUPERPAGE_TOTAL", ram_size);
        install_super_page(&cpu, sb, total);
    }

    nk_interp_t ip;
    nk_interp_init(&ip);

    uint32_t entry = 0, code_base = 0;
    uint32_t code_off_in_file = 0;
    long code_len = 0;
    uint8_t* code_img = NULL;
    int thumb_entry = 1;

    if (rom_image) {
        /* Replace the packed flash mapping with the flat runtime image. */
        long ilen = 0;
        uint8_t* img = read_file(rom_image, &ilen);
        if (!img) return 1;
        long n = ilen < rom_len ? ilen : rom_len;
        memcpy(rom_copy, img, (size_t)n);
        if ((unsigned long)n < rom_pages) memset(rom_copy + n, 0, rom_pages - (size_t)n);
        free(img);
        entry = rom_image_prepare(&cpu, &ip, rom_copy, rom_len, 1);
        if (!entry) { fprintf(stderr, "no kernel in %s\n", rom_image); return 1; }
        /* Round 63: app-side EUser import rebinds.  Keep these separate from
         * the kernel map: the kernel K-3 relocation patches shared EUser
         * export slots, while app slots were linked against the ROM's own
         * EUser order.  NK_APP_IMPORTMAP only rewrites the slots named in the
         * file, after the flat image is loaded and before the run. */
        {
            const char* appmap = getenv("NK_APP_IMPORTMAP");
            if (appmap) {
                static import_override_t appov[NK_MAX_IMPORT_OVERRIDES];
                int na = load_import_overrides(appmap, appov,
                                               NK_MAX_IMPORT_OVERRIDES);
                for (int i = 0; i < na; i++) {
                    uint32_t oldv = nk_r32(&cpu, appov[i].slot);
                    nk_w32(&cpu, appov[i].slot, appov[i].target);
                    printf("app import rebind: %#010x %#010x -> %#010x\n",
                           appov[i].slot, oldv, appov[i].target);
                }
            }
        }
        /* The E32Image entry carries the interworking bit: odd = Thumb.
         * The old bring-up forced Thumb because it was executing the 6-byte
         * page tag at the start of the packed record; the real kernel entry
         * (+0x54) is ARM code (`push {r4,r5,r6,lr}`). */
        thumb_entry = (entry & 1u) ? 1 : 0;
        if (getenv("NK_ENTRY_ARM")) thumb_entry = 0;
        if (getenv("NK_ENTRY_THUMB")) thumb_entry = 1;
        uint32_t btr = (uint32_t)env_ulong("NK_BOOTTABLE_RAM", 0);
        if (btr) install_boot_table_ram(&cpu, btr);
        if (getenv("NK_KERNEL_VECTORS") && g_kernel_code) {
            const uint8_t* v = rom_copy + (g_kernel_code - NK_FLASH_BASE);
            nk_poke(&cpu, 0x00000000u, v, 0x64);
            nk_poke(&cpu, NK_HIGH_VECTORS, v, 0x64);
            printf("kernel vectors: 0x64 bytes from %#010x -> 0x0 / %#010x\n",
                   g_kernel_code, NK_HIGH_VECTORS);
            /* The mask ROM runs the kernel with CP15.V=1 (high vectors); the
             * kernel then installs its real vector code at 0xffff0000 via
             * Kern::InitVectors.  Low memory is boot-bank scratch and is
             * overwritten by the kernel, so exceptions must use this page. */
            cpu.cp15_c1 |= 0x2000u;
            printf("cp15 c1 V=1: exception vectors at %#010x\n", NK_HIGH_VECTORS);
        }
        printf("runtime image %s: entry %#010x (%s)\n",
               rom_image, entry, thumb_entry ? "Thumb" : "ARM");
    } else if (e32 >= 0) {
        /* EKA1 TRomImageHeader: entry 0x10, code 0x14, code_size 0x1c.
         * Every serialized EKA1 header in this ROM is 0x64 bytes. */
        if ((unsigned long)e32 + 0x64 > (unsigned long)rom_len) {
            fprintf(stderr, "E32 header %#lx outside the ROM\n", e32);
            return 1;
        }
        entry     = u32(rom + e32 + 0x10);
        code_base = u32(rom + e32 + 0x14);
        uint32_t code_size = u32(rom + e32 + 0x1c);
        /* Every EKA1 TRomImageHeader serialized in this ROM is 0x64 bytes
         * (rom_image_header_file_size(EKA1) in the Symbian/eka2l1 headers).
         * Earlier bring-up used 0x6c for the kernel because of two extra
         * words at +0x64; those words are the first 8 bytes of text, and the
         * extra 8-byte shift is what made real ARM code decode as Thumb-2. */
        uint32_t hdr_size = (uint32_t)env_ulong("NK_E32_HDR", 0x64);
        code_off_in_file = (uint32_t)e32 + hdr_size;
        code_len = (long)code_size;
        code_img = rom + code_off_in_file;
        thumb_entry = entry & 1;
        if (u32(rom + e32 + 0x08) == 0x100058e8u) thumb_entry = 1; /* kernel text is Thumb */
        if (getenv("NK_ENTRY_ARM")) thumb_entry = 0;
        if (getenv("NK_ENTRY_THUMB")) thumb_entry = 1;
        printf("E32 image @ file %#lx: entry %#010x code %#010x size %#x "
               "(hdr %#x, %s)\n", e32, entry, code_base, code_size, hdr_size,
               thumb_entry ? "Thumb" : "ARM");
        if (getenv("NK_E32_SECTIONS")) {
            rom_loader_t L;
            memset(&L, 0, sizeof L);
            L.rom = rom;
            L.len = rom_len;
            L.cpu = &cpu;
            L.ip = &ip;
            if (load_image(&L, e32, 0) != 0) return 1;
            code_img = NULL;             /* sections are already in guest memory */
            code_len = 0;
        }
    } else {
        code_img = read_file(kern_path, &code_len);
        if (!code_img) return 1;
        code_base = (uint32_t)env_ulong("NK_KERNEL_CODE", 0x50310000);
        entry = (uint32_t)env_ulong("NK_KERNEL_ENTRY", 0x50310054);
        thumb_entry = (entry & 1u) ? 1 : 0;   /* page-header-free kernel is ARM */
        if (getenv("NK_ENTRY_ARM")) thumb_entry = 0;
        if (getenv("NK_ENTRY_THUMB")) thumb_entry = 1;
        nk_code_range_add(&ip, code_base, code_base + (uint32_t)code_len);
        printf("kernel blob %s: %ld bytes -> %#010x, entry %#010x (%s)\n",
               kern_path, code_len, code_base, entry, thumb_entry ? "Thumb" : "ARM");
    }
    if (code_img) {
        uint32_t load_len = (uint32_t)code_len;
        uint32_t text_shift = (uint32_t)env_ulong("NK_TEXT_SHIFT", 0);
        if (text_shift + load_len > (uint32_t)code_len) text_shift = 0;
        nk_poke(&cpu, code_base, code_img + text_shift, load_len);
    }

    /* The UPP mask ROM can execute the first ROM bank through the low
     * physical alias (address 0).  The secondary loader's jump tables are
     * 0-based offsets (e.g. 0x2908 -> 0x50002908 when executing at
     * 0x50000000, which is wrong), so the loader only works when its code is
     * reachable at address 0.  Copy the first 64 KiB there for comparison. */
    if (getenv("NK_LOW_ROM")) {
        /* NK_LOW_ROM_IMAGE replaces the verbatim first 64 KiB with an
         * already-unpacked (linked) view, e.g. recompiler/bootbank.py.  The
         * boot bank is stored as fragments linked for different bases, so the
         * flash copy is not executable at its linked addresses. */
        const char* low_path = getenv("NK_LOW_ROM_IMAGE");
        const uint8_t* low_src = rom_copy;
        long low_len = rom_len;
        uint8_t* low_buf = NULL;
        if (low_path) {
            low_buf = read_file(low_path, &low_len);
            if (!low_buf) { fprintf(stderr, "cannot read %s\n", low_path); return 1; }
            low_src = low_buf;
            printf("low ROM image: %s (%ld bytes)\n", low_path, low_len);
        }
        uint32_t n = (uint32_t)env_ulong("NK_LOW_ROM_SIZE", 0x10000);
        if ((long)n > low_len) n = (uint32_t)low_len;
        nk_poke(&cpu, 0x00000000u, low_src, n);
        nk_code_range_add(&ip, 0x00000000u, n);
        free(low_buf);
        /* The mask ROM's high-vector page is a copy of the boot bank's
         * exception vectors.  Without it, the loader's exception path
         * executes zero pages at 0xffff0000. */
        uint32_t hv = n < 0x40u ? n : 0x40u;
        nk_poke(&cpu, NK_HIGH_VECTORS, rom_copy, hv);
        nk_code_range_add(&ip, NK_HIGH_VECTORS, hv);
        printf("low ROM alias: %u bytes at 0x00000000, %u high-vector bytes\n",
               n, hv);
    }

    /* The UPP mask ROM leaves a boot-region table (count + 0x10-byte
     * segments) in RAM and passes its address in fp/r11.  The secondary
     * loader copies that table to the super page and uses it for address
     * translation.  Installing one from a file keeps the stand-in explicit
     * keeps the table format and the boot state independent. */
    const char* regions = getenv("NK_REGIONS");
    if (regions) {
        char path[512];
        snprintf(path, sizeof path, "%s", regions);
        uint32_t at = 0x80000000u;
        char* atmark = strrchr(path, '@');
        if (atmark) {
            *atmark++ = '\0';
            at = (uint32_t)strtoul(atmark, NULL, 0);
        }
        long rlen = 0;
        uint8_t* rbuf = read_file(path, &rlen);
        if (!rbuf) return 1;
        nk_poke(&cpu, at, rbuf, (uint32_t)rlen);
        printf("boot-region table %s: %ld bytes at %#010x (%u entries)\n",
               path, rlen, at, rlen >= 4 ? u32(rbuf) : 0);
        free(rbuf);
    }

    uint32_t entry_override = (uint32_t)env_ulong("NK_ENTRY", 0);
    if (entry_override) {
        entry = entry_override;
        thumb_entry = (entry_override & 1) ? 1 : 0;
        printf("entry override: %#010x (%s)\n", entry, thumb_entry ? "Thumb" : "ARM");
    }

    /* Legacy round-18/19 stand-in for the scheduler's current-thread pointer.
     * The E32 entry calls into EUser, whose executive-call stubs dereference
     * [0x800017d4].  On a real cold boot the mask ROM/kernel startup creates
     * the initial thread before that; jumping straight to the E32 entry skips
     * it.  Round 20 showed that process+0x38 is a CObjectIx, not a heap, so
     * this is kept only for tools/test_imports.sh's pinned import frontier;
     * NK_B7E is the corrected graph. */
    if (getenv("NK_FAKE_THREAD")) {
        uint32_t obj = 0x80003000u, vt = 0x80003040u;
        uint32_t obj2 = 0x80003100u, vt2 = 0x80003140u;
        /* The kernel's operator new reads the current thread's process
         * ([thread+0x18]) and that process's heap ([process+0x38]); the
         * 0x40000000 branch uses [thread+0x64] directly.  Give both paths a
         * non-null heap object so NK_ALLOC_HLE can serve the allocation. */
        uint32_t proc = 0x80003200u;
        uint32_t heap = 0x80003300u;
        nk_w32(&cpu, 0x800017d4u, obj);
        nk_w32(&cpu, obj, vt);
        nk_w32(&cpu, obj + 0x14, 1);
        nk_w32(&cpu, obj + 0x18, proc);          /* thread -> process */
        nk_w32(&cpu, obj + 0x5c, obj2);          /* thread-local object */
        nk_w32(&cpu, obj + 0x64, heap);          /* kernel-heap path */
        nk_w32(&cpu, proc + 0x38, heap);         /* process -> heap */
        nk_w32(&cpu, heap + 0x14, 1);            /* element size */
        nk_w32(&cpu, vt + 0x20, 0x50312e90u);  /* mov r0,#0; bx lr */
        nk_w32(&cpu, obj2, vt2);
        nk_w32(&cpu, vt2 + 0x20, 0x50312e90u);
        nk_w32(&cpu, vt2 + 0x28, 0x50312e90u);
        printf("fake current thread: [%#010x] = %#010x, vtable %#010x, "
               "process %#010x, process+0x38 %#010x\n",
               0x800017d4u, obj, vt, proc, heap);
    }

    /* B7e: the mask-ROM/scheduler startup that creates the first process and
     * heap is not part of the E32 entry path.  Install a coherent
     * thread -> process -> heap graph and follow every current-thread update. */
    if (env_ulong("NK_B7E", 0)) {
        uint32_t base = (uint32_t)env_ulong("NK_B7E_HEAP", hle_heap);
        uint32_t size = (uint32_t)env_ulong("NK_B7E_SIZE", 0x400000u);
        b7e_enabled = 1;
        b7e_install(&cpu, &ip, base, size);
        /* Install the hook before the initial publish so the fake current
         * thread also gets +0x18/+0x5c/+0x64; otherwise the first executive
         * call reads a null request semaphore.  NK_B7E_LATE_HOOK=1 keeps the
         * historical (buggy) order for the round-39/40 controls. */
        if (env_ulong("NK_B7E_LATE_HOOK", 0)) {
            nk_w32(&cpu, 0x800017d4u, B7E_THREAD);
            nk_dbg_watch_write(0x800017d4u, b7e_thread_hook);
        } else {
            nk_dbg_watch_write(0x800017d4u, b7e_thread_hook);
            nk_w32(&cpu, 0x800017d4u, B7E_THREAD);
        }
        if (b7e_live)
            nk_dbg_watch_write4(0x80000408u, b7e_alias_hook);
        printf("B7e: watching [%#010x] for current-thread updates\n",
               0x800017d4u);
    }

    /* Round 28: the real mask ROM leaves the kernel's ROM-image hand-off in
     * the super page and gives the ROMFS directory a writable RAM copy. */
    if (env_ulong("NK_BOOT_HANDOFF", 0))
        install_boot_handoff(&cpu);
    /* Round 29: the kernel's system-time init (0x5031380c) reads a 64-bit
     * TTime at 0x50000084, four bytes after the TRomHeader iTime at
     * 0x50000080.  The mask ROM's hand-off page supplies that value; source
     * it from the header's iTime.  This overlaps the header's iRomBase word,
     * which the kernel never reads at runtime. */
    if (env_ulong("NK_SYSTEM_TIME", 0)) {
        uint32_t lo = nk_r32(&cpu, 0x50000080u);
        uint32_t hi = nk_r32(&cpu, 0x50000084u);
        nk_w32(&cpu, 0x50000084u, lo);
        nk_w32(&cpu, 0x50000088u, hi);
        printf("system time handoff: [0x50000084] = %#010x%08x "
               "(from TRomHeader iTime)\n", hi, lo);
    }
    {
        uint32_t primary_ram = (uint32_t)env_ulong("NK_PRIMARY_RAM", 0);
        if (primary_ram) install_primary_ram(&cpu, primary_ram);
    }

    /* Some extension records carry a nested image with no export table; the
     * EKA1 extension loader still calls export 1 after the image entry. */
    install_extension_stub(&cpu, &ip);

    /* Round 28: the HAL timer channel (+0x5c) is the first HAL service the
     * boot path uses.  The fake HAL's vtable is zero-return, so the kernel
     * divides 1,000,000 by zero.  NK_HAL_TIMER_HZ installs an explicit
     * constant-return stub; 4 is the round-27 probe value, not recovered
     * firmware state. */
    if (env_ulong("NK_B7E", 0)) {
        uint32_t hz = (uint32_t)env_ulong("NK_HAL_TIMER_HZ", 0);
        if (hz) {
            const uint32_t stub = 0xffff0700u;
            nk_w32(&cpu, stub + 0, 0xe59f0000u);  /* ldr r0,[pc,#0] */
            nk_w32(&cpu, stub + 4, 0xe12fff1eu);  /* bx lr         */
            nk_w32(&cpu, stub + 8, hz);
            nk_w32(&cpu, B7E_VT_HAL + 0x5cu, stub);
            nk_code_range_add(&ip, stub, stub + 12u);
            printf("HAL timer frequency: vtable+0x5c -> stub %#010x = %u Hz\n",
                   stub, hz);
        }
    }

    /* NK_POKE=addr:value[,addr:value...]: explicit bring-up writes.  Used to
     * probe missing boot descriptors without rebuilding a harness per try. */
    const char* poke = getenv("NK_POKE");
    if (poke) {
        const char* p = poke;
        while (*p) {
            char* end = NULL;
            uint32_t addr = (uint32_t)strtoul(p, &end, 0);
            if (!end || *end != ':') break;
            uint32_t value = (uint32_t)strtoul(end + 1, &end, 0);
            nk_w32(&cpu, addr, value);
            printf("poke %#010x = %#010x\n", addr, value);
            if (!end || *end != ',') break;
            p = end + 1;
        }
    }

    /* NK_PATCH=addr:word[,addr:word...]: code patches that survive the
     * kernel's own .bss/memory initialisation (NK_POKE cannot touch .bss). */
    const char* patch = getenv("NK_PATCH");
    if (patch) {
        const char* p = patch;
        while (*p) {
            char* end = NULL;
            uint32_t addr = (uint32_t)strtoul(p, &end, 0);
            if (!end || *end != ':') break;
            uint32_t value = (uint32_t)strtoul(end + 1, &end, 0);
            nk_w32(&cpu, addr, value);
            printf("patch %#010x = %#010x\n", addr, value);
            if (!end || *end != ',') break;
            p = end + 1;
        }
    }

    const char* sp_env = getenv("NK_SP");
    cpu.r[13] = sp_env ? (uint32_t)strtoul(sp_env, NULL, 0) : 0x80300000u;
    cpu.r[0] = (uint32_t)env_ulong("NK_R0", 0);
    cpu.r[1] = (uint32_t)env_ulong("NK_R1", 0);
    cpu.r[2] = (uint32_t)env_ulong("NK_R2", 0);
    /* Mask-ROM stand-in: the UPP boot ROM enters the secondary loader with
     * r11 (fp), r10 (sl) and the other callee-saved registers already set.
     * NK_Rn makes those entry conditions reproducible, e.g.
     *   NK_ENTRY=0x500003bc NK_R11=0x80000000 NK_R10=0x...
     *   ./out/boot_kernel ... --rom-image out/6600_runtime.bin
     * The existing NK_R0/NK_R1/NK_R2 names keep working. */
    for (int i = 0; i <= 12; i++) {
        char name[16];
        snprintf(name, sizeof name, "NK_R%d", i);
        cpu.r[i] = (uint32_t)env_ulong(name, cpu.r[i]);
    }
    /* Stand in for the mask-ROM/bootstrap caller: the kernel entry returns to
     * a sentinel so a completed entry is reported as a clean return instead of
     * "pc left the image". */
    cpu.r[14] = (uint32_t)env_ulong("NK_LR", 0xdead0000u);
    cpu.cpsr = 0x400000d3u | (thumb_entry ? NK_CPSR_T : 0);  /* SVC, IRQ/FIQ off */
    /* NK_CPSR overrides the reset CPSR (bring-up: the mask ROM may hand the
     * kernel an I=0 SVC context; the round-30 IRQ path needs it). */
    {
        const char* cs = getenv("NK_CPSR");
        if (cs) {
            cpu.cpsr = (uint32_t)strtoul(cs, NULL, 0);
            /* The entry mode is authoritative: a Thumb NK_ENTRY must not be
             * decoded as ARM just because NK_CPSR omitted the T bit. */
            if (thumb_entry) cpu.cpsr |= NK_CPSR_T;
            else             cpu.cpsr &= ~NK_CPSR_T;
            printf("cpsr override: %#010x%s\n", cpu.cpsr,
                   thumb_entry ? " (Thumb entry)" : "");
        }
    }
    cpu.r[15] = entry & ~1u;
    /* The IRQ path needs the banked r13/r14 + SPSR model.  Enabling the timer
     * implies it: an IRQ taken without banks would reuse the SVC stack. */
    int need_banks = (int)(env_ulong("NK_BANKED", 0) || env_ulong("NK_TIMER", 0));
    if (need_banks) {
        /* The mask-ROM startup gives each ARM mode its own stack.  The kernel
         * switches to UND/SVC/ABT while dispatching executive calls; without
         * banks those writes all land on the SVC stack.  These tops are a
         * bring-up stand-in, not recovered firmware state. */
        uint32_t top = 0x80300000u;
        if (b7e_live) {
            /* Round 34: the supervisor's SVC stack legitimately grows past
             * 0x30 KiB during Kern::Init2/Init3.  With the historical layout
             * the exception banks sat *below* the SVC top, so an IRQ at
             * sp=0x802f3fec pushed its frame over the interrupted function's
             * saved LR and the return popped PC=6.  In the live-object model
             * put the exception stacks low in the 3 MiB window; the SVC stack
             * then has ~1 MiB of private room below 0x80300000. */
            nk_bank_init(&cpu, NK_MODE_SVC, top, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_UND, 0x80140000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_ABT, 0x80180000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_IRQ, 0x801c0000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_FIQ, 0x80200000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_USR, 0x80240000u, cpu.r[14]);
            printf("banked mode stacks: svc=%#010x und=%#010x abt=%#010x "
                   "irq=%#010x fiq=%#010x usr=%#010x\n",
                   top, 0x80140000u, 0x80180000u, 0x801c0000u,
                   0x80200000u, 0x80240000u);
        } else {
            nk_bank_init(&cpu, NK_MODE_SVC, top, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_UND, top - 0x4000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_ABT, top - 0x8000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_IRQ, top - 0xc000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_FIQ, top - 0x10000u, cpu.r[14]);
            nk_bank_init(&cpu, NK_MODE_USR, top - 0x14000u, cpu.r[14]);
            printf("banked mode stacks: svc=%#010x und=%#010x abt=%#010x "
                   "irq=%#010x fiq=%#010x usr=%#010x\n",
                   top, top - 0x4000u, top - 0x8000u, top - 0xc000u,
                   top - 0x10000u, top - 0x14000u);
        }
    }

    /* Direct user-mode entry: the USR bank must start at the app's NK_SP,
     * not at the harness's fixed per-mode top.  Otherwise the first SVC
     * return to USR mode restores the wrong SP and loses the app frame. */
    if ((cpu.cpsr & 0x1fu) == 0x10u) {
        nk_bank_init(&cpu, NK_MODE_USR, cpu.r[13], cpu.r[14]);
        printf("app USR stack: %#010x\n", cpu.r[13]);
    }

    ip.budget = (long)env_ulong("NK_BUDGET", 2000000);
    ip.infer_mode = (int)env_ulong("NK_INFER", 1);
    ip.infer_calls = (int)env_ulong("NK_CALL_INFER", 0);
    ip.call_policy = (int)env_ulong("NK_CALL_POLICY", 0);
    ip.snap_window = (uint32_t)env_ulong("NK_SNAP_WINDOW", 0x40);
    ip.snap_window_thumb = (uint32_t)env_ulong("NK_SNAP_WINDOW_THUMB", ip.snap_window);
    ip.snap_window_arm = (uint32_t)env_ulong("NK_SNAP_WINDOW_ARM", ip.snap_window);
    ip.snap_nofast = (int)env_ulong("NK_SNAP_NOFAST", 0);
    ip.call_fixup_log = (int)env_ulong("NK_FIXUP_LOG", 16);
    ip.iat_fake_return = (int)env_ulong("NK_IAT_FAKE", 0);
    ip.iat_log = (int)env_ulong("NK_IAT_LOG", 16);
    ip.stop_on_swi = (int)env_ulong("NK_STOP_ON_SWI", 0);
    ip.recover = (int)env_ulong("NK_RECOVER", 0);
    ip.recover_max = (int)env_ulong("NK_RECOVER_MAX", 256);
    ip.recover_log = (int)env_ulong("NK_RECOVER_LOG", 16);
    ip.watch_pc = (uint32_t)env_ulong("NK_WATCH", 0);
    ip.watch_hits = (int)env_ulong("NK_WATCH_HITS", 1);
    ip.watch_log = (int)env_ulong("NK_WATCH_LOG", 16);
    ip.watch_mem_reg = -1;
    const char* watch_mem = getenv("NK_WATCH_MEM");
    if (watch_mem) {
        /* NK_WATCH_MEM=r7:0x40 — dump guest memory at a register when the
         * watch fires.  Debug-only; the register stays in the harness. */
        char regname[8] = {0};
        unsigned len = 0x40;
        if (sscanf(watch_mem, "%7[^:]:%x", regname, &len) >= 1 &&
            regname[0] == 'r') {
            int reg = atoi(regname + 1);
            if (reg >= 0 && reg < 16) {
                ip.watch_mem_reg = reg;
                ip.watch_mem_len = len;
            }
        }
    }
    g_ww_addr = (uint32_t)env_ulong("NK_WRITE_WATCH", 0);
    g_ww_max = (long)env_ulong("NK_WRITE_WATCH_MAX", 8);
    if (g_ww_addr) {
        if (g_ww_max <= 0) g_ww_max = 0;
        nk_dbg_watch_write4(g_ww_addr, debug_write_hook);
        printf("write watch: %#010x (max %ld stores)\n", g_ww_addr, g_ww_max);
    }
    if (env_ulong("NK_BOOT_TIME", 0)) {
        /* The guest writes the TInt64 with one 64-bit store; watch the high
         * word so the correction runs after both words have landed. */
        nk_dbg_watch_write2(NK_BOOT_TIME_GLOBAL + 4u, boot_time_hook);
        printf("boot time: %#010x <- ROM header iTime %#010x:%#010x\n",
               NK_BOOT_TIME_GLOBAL, nk_r32(&cpu, 0x50000080u),
               nk_r32(&cpu, 0x50000084u));
    }
    ip.stop_selfb = (int)env_ulong("NK_STOP_SELFB", 1);
    ip.swi_direct = (int)env_ulong("NK_SWI_DIRECT", 0);
    ip.swi_table = (uint32_t)env_ulong("NK_SWI_TABLE", 0x50314aec);
    ip.swi_log = (int)env_ulong("NK_SWI_LOG", 16);
    ip.banked = need_banks;
    {
        const char* st = getenv("NK_STUB_PC");
        if (st) {
            const char* p = st;
            while (*p && ip.stub_n < 16) {
                char* end = NULL;
                unsigned long v = strtoul(p, &end, 0);
                if (end == p) break;
                ip.stub_pc[ip.stub_n++] = (uint32_t)v & ~1u;
                p = end;
                while (*p == ',' || *p == ' ' || *p == '\t') p++;
            }
            printf("stub pc: %d address(es) return 0\n", ip.stub_n);
        }
    }
    {
        const char* sr = getenv("NK_SWI_RET");
        if (sr) {
            char* end = NULL;
            unsigned long idx = strtoul(sr, &end, 0);
            if (end && (*end == ':' || *end == '=')) {
                ip.swi_ret_idx = (uint32_t)(idx & 0x1ffu);
                ip.swi_ret_value = (uint32_t)strtoul(end + 1, NULL, 0);
                printf("swi ret: svc %#lx -> %#x\n", idx & 0x1ffu,
                       ip.swi_ret_value);
            }
        }
    }
    ip.irq_log = (int)env_ulong("NK_IRQ_LOG", 0);
    const char* complete = getenv("NK_SWI_COMPLETE");
    if (complete) {
        const char* p = complete;
        while (*p) {
            char* end = NULL;
            unsigned long v = strtoul(p, &end, 0);
            if (end == p) break;
            if (v < 512) ip.swi_complete[v >> 6] |= 1ull << (v & 63);
            p = end;
            while (*p == ',' || *p == ' ' || *p == '\t') p++;
        }
        printf("SWI completion HLE: %s\n", complete);
    }
    ip.spin_max = (uint32_t)env_ulong("NK_SPIN", 0) ?
        (uint32_t)env_ulong("NK_SPIN_MAX", 20000) : 0;
    ip.require_code = (int)env_ulong("NK_CODE_ONLY", 1);
    ip.allow_low_alias = getenv("NK_LOW_ROM") ? 1 : 0;
    const char* callmap = getenv("NK_CALLMAP");
    if (callmap) load_callmap(&ip, callmap);
    ip.hle_heap = (uint32_t)env_ulong("NK_HLE_HEAP", hle_heap);
    ip.hle_heap_end = (uint32_t)env_ulong("NK_HLE_HEAP_END",
                                          (unsigned long)hle_heap + 0x400000u);
    /* Bring-up RHeap::Alloc: the scheduler startup that would create the
     * current thread's heap is skipped by a direct E32-entry boot.  Serve
     * allocations from the harness heap and log the first few. */
    if (env_ulong("NK_ALLOC_HLE", 0)) {
        ip.alloc_hle = 1;
        ip.alloc_pc = (uint32_t)env_ulong("NK_ALLOC_PC", 0x5038e2ecu);
        ip.realloc_pc = (uint32_t)env_ulong("NK_REALLOC_PC", 0x5039c630u);
        ip.alloc_trace = (int)env_ulong("NK_ALLOC_TRACE", 0);
        ip.alloc_clamp = (uint32_t)env_ulong("NK_ALLOC_CLAMP", 0);
        ip.free_pc = (uint32_t)env_ulong("NK_FREE_PC", 0x5038e3d8u);
        ip.alloc_cur = (uint32_t)env_ulong("NK_ALLOC_BASE", hle_heap);
        ip.alloc_base = ip.alloc_cur;
        ip.alloc_end = (uint32_t)env_ulong(
            "NK_ALLOC_END", (unsigned long)hle_heap + 0x400000u);
        ip.alloc_log = (int)env_ulong("NK_ALLOC_LOG", 8);
        printf("HLE allocator: bump heap %#010x..%#010x, RHeap::Alloc at "
               "%#010x, ReAlloc %#010x, Free %#010x\n",
               ip.alloc_cur, ip.alloc_end, ip.alloc_pc, ip.realloc_pc,
               ip.free_pc);
    }
    if (env_ulong("NK_SWI_EXCEPTION", 0)) ip.swi_exception = 1;
    if (getenv("NK_TRACE")) ip.trace = 1;
    ip.trace_limit = (long)env_ulong("NK_TRACE_N", 64);
    ip.trace_from = (uint32_t)env_ulong("NK_TRACE_FROM", 0);
    ip.trace_after = (unsigned long)env_ulong("NK_TRACE_AFTER", 0);
    ip.return_pc = (uint32_t)env_ulong("NK_STOP_PC", cpu.r[14]);
    ip.return_thumb = (uint8_t)thumb_entry;

    /* Round 31: inject the mask-ROM/HAL timer-queue singleton at the exact
     * instruction after the first timer IRQ wakes Kern::Init1.  The default
     * mode calls the kernel's own constructor (export 451); NK_TIMERQ_MODE=
     * stub falls back to a zero-return vtable. */
    if (env_ulong("NK_MEMCOPY_CLAMP", 0)) {
        /* pc_hook (1) is reserved for the timerq injection, so the clamp
         * lives on hook 2. */
        ip.pc_hook2_addr = 0x5038cfe0u;
        ip.pc_hook2 = memcopy_clamp_hook;
        printf("memcopy clamp: wild copies at 0x5038cfe0 are zeroed\n");
    }
    if (env_ulong("NK_SUPERVISOR_OBJECT_FIX", 0)) {
        ip.pc_hook4_addr = 0x503ce696u;
        ip.pc_hook4 = supervisor_object_hook;
        printf("supervisor object fix: [this+0x14] -> B7e vtable at 0x503ce696\n");
    }
    if (env_ulong("NK_TIMERQ", 0)) {
        ip.pc_hook_addr = 0x5031ef40u;
        ip.pc_hook = timerq_pc_hook;
        printf("timerq: will inject [0x80001c34] before %#010x\n",
               ip.pc_hook_addr);
    }

    /* Round 33: model `svc #0x4d` (WaitForAnyRequest) as a block plus a
     * context switch to the kernel's NULL thread.  It runs before the
     * generic SWI dispatch, so NK_SWI_COMPLETE=0x4d must not be set. */
    if (env_ulong("NK_SCHED_FAKE", 0)) {
        /* Round 78: pre-create the thread the app's StartThread owns so the
         * scheduler's next-thread search finds it.  The first switch uses
         * NK_SCHED_ENTRY / NK_SCHED_STACK to initialise it. */
        uint32_t ft = 0x80004600u;
        sched_slot(ft, 1);
        nk_w32(&cpu, 0x80000400u, ft);
        nk_w32(&cpu, ft + 0x00, 0x80003040u);
        nk_w32(&cpu, ft + 0x14, 1);
        nk_w32(&cpu, ft + 0x18, 0x80003200u);
        nk_w32(&cpu, ft + 0x5c, 0x80003f00u);
        nk_w32(&cpu, ft + 0x64, 0x80003300u);
        printf("sched: fake thread %#010x pre-created for entry %#010x\n",
               ft, (uint32_t)env_ulong("NK_SCHED_ENTRY", 0));
    }
    if (env_ulong("NK_SCHED", 0)) {
        sched_on = 1;
        sched_defer = (int)env_ulong("NK_SCHED_DEFER", 0);
        ip.swi_hook = sched_swi_hook;
        ip.yield_hook = sched_yield_hook;
        /* The inline NK_SWI_COMPLETE model stays for every other call site;
         * sched_swi_hook claims only the kernel-start wait. */
        sched_log = (int)env_ulong("NK_SCHED_LOG", 8);
        printf("sched: wait-any-request switch model on (svc #0x%02x, "
               "NULL thread [%#010x], entry %#010x)\n",
               SCHED_WAIT_SWI, SCHED_NULL_GLOBAL,
               (uint32_t)env_ulong("NK_SCHED_ENTRY", SCHED_NULL_ENTRY));
    }

    /* Direct app entry: a real process starts with a zeroed user stack.  The
     * harness stack may still contain B7e/timerq setup words, which can be
     * mistaken for descriptor headers by EUser formatting code. */
    if (env_ulong("NK_APP_STACK_CLEAR", 0)) {
        uint32_t base = (cpu.r[13] - 0x2000u) & ~3u;
        if (!nk_page_ptr(&cpu, base))
            nk_alloc_ram(&cpu, base, 0x2000u);
        for (uint32_t o = 0; o < 0x2000u; o += 4)
            nk_w32(&cpu, base + o, 0);
        printf("app stack cleared: %#010x..%#010x\n", base, cpu.r[13]);
    }

    if (env_ulong("NK_USER_SVC_KERNEL", 0)) {
        /* EUser's user-style SVC stubs carry bit 23, which sends the kernel
         * handler down the mask-ROM user path.  Direct app entry has no
         * mask-ROM user-SVC dispatcher, so that path ends in a self-loop at
         * 0x50314f78.  Clear bit 23 so the kernel service table dispatches
         * the call instead.  Mode 1 patches only SVC 0x76 (StartThread);
         * mode 2 patches every EUser SVC stub in the 0x50392b80 table. */
        int all = (int)env_ulong("NK_USER_SVC_KERNEL", 0) >= 2;
        unsigned patched = 0;
        for (uint32_t a = 0x50392b80u; a < 0x50392bc0u; a += 4) {
            uint32_t w = nk_r32(&cpu, a);
            if ((w & 0x0f000000u) != 0x0f000000u) continue;
            if (!(w & 0x00800000u)) continue;
            if (!all && (w & 0x0fffffffu) != 0x0fc00076u) continue;
            nk_w32(&cpu, a, w & ~0x00800000u);
            patched++;
        }
        printf("user SVC kernel patch: %u SVC stubs (%s)\n", patched,
               all ? "all" : "0x76 only");
    }
    if (env_ulong("NK_USER_SVC", 0)) {
        /* The flat image binds app imports to the kernel-side EUser stub
         * table, whose `svc #N` immediates lack the bit-23 user marker.  Mark
         * them as user SVCs so the real kernel handler takes its user path. */
        unsigned patched = 0;
        for (uint32_t a = 0x50392b88u; a < 0x50393388u; a += 4) {
            uint32_t w = nk_r32(&cpu, a);
            if ((w & 0x0f000000u) == 0x0f000000u && !(w & 0x00800000u)) {
                nk_w32(&cpu, a, w | 0x00800000u);
                patched++;
            }
        }
        printf("user SVC patch: %u EUser stubs marked bit 23\n", patched);
    }
    if (env_ulong("NK_FB_MBM", 0)) {
        /* Decode SplashScreen.mbm's first bitmap from guest memory into a
         * guest RGB565 source buffer.  NK_FB_MBM=1 then lets the guest
         * EUser Mem::Copy (0x5038cfe0) write the real Nokia logo into the
         * LCD framebuffer.  See mbm_first_frame_to_rgb565 above. */
        const uint32_t src = 0x80800000u;
        if (nk_alloc_ram(&cpu, src, 0x20000u) != 0) {
            fprintf(stderr, "FB MBM: cannot map source buffer %#x\n", src);
            return 1;
        }
        mbm_frame_info info;
        int rc = mbm_first_frame_to_rgb565(&cpu, 0x509efae0u, 0xd54u,
                                           src, 0x20000u, &info);
        if (rc != 0) {
            fprintf(stderr, "FB MBM: SplashScreen.mbm decode failed rc=%d\n", rc);
            return 1;
        }
        printf("FB MBM: SplashScreen.mbm @ 0x509efae0, bitmap 0 %ux%u, "
               "EByteRLE8, %u pixels\n", info.width, info.height, info.pixels);
        printf("FB MBM: src 0x%08x, non-white %u, bbox x=%u..%u y=%u..%u, "
               "RGB565 fnv1a=0x%08x\n", src, info.nonwhite,
               info.x0, info.x1, info.y0, info.y1, info.fnv);
    }
    if (env_ulong("NK_FB_SRC", 0)) {
        /* Fill a guest source buffer with 0xff (16bpp white) for the
         * splash-background Mem::Copy pipeline test. */
        if (nk_alloc_ram(&cpu, 0x80800000u, 0x20000u) == 0) {
            for (uint32_t o = 0; o < 176u * 208u * 2u; o++)
                nk_w8(&cpu, 0x80800000u + o, 0xff);
            printf("FB source: 0x80800000, %u bytes of 0xff\n", 176u * 208u * 2u);
        }
    }
    if (env_ulong("NK_MAP_LCD", 0)) {
        /* ecust.dll's display config at 0x5033abf4 writes the LCD controller
         * base 0x59200000 and the framebuffer base 0x59800000 (base +
         * 0x600000).  Map both so guest pixel writes are captured instead of
         * disappearing into the MMIO bus. */
        if (nk_alloc_ram(&cpu, 0x59200000u, 0x10000u) == 0 &&
            nk_alloc_ram(&cpu, 0x59800000u, 0x400000u) == 0)
            printf("LCD: controller 0x59200000, framebuffer 0x59800000+0x400000\n");
    }
    if (env_ulong("NK_FIX_4A78", 0)) {
        /* EwSrv's veneer at 0x506c15ee loads a stale absolute function
         * pointer 0x4a7846c0 from its missing DLL.  Map that address and
         * point it at a zero-return stub so the call is observable instead
         * of branching to 0. */
        int m = nk_alloc_ram(&cpu, 0x4a780000u, 0x10000u);
        printf("EwSrv DLL stub: map=%d\n", m);
        if (m == 0) {
            nk_w32(&cpu, 0xffff0d00u, 0xe3a00000u);  /* mov r0,#0 */
            nk_w32(&cpu, 0xffff0d04u, 0xe12fff1eu);  /* bx lr     */
            nk_code_range_add(&ip, 0xffff0d00u, 0xffff0d08u);
            for (uint32_t o = 0; o < 0x10000u; o += 4)
                nk_w32(&cpu, 0x4a780000u + o, 0xffff0d00u);
            printf("EwSrv DLL stub page: 0x4a780000..0x4a790000\n");
            printf("EwSrv DLL stub: 0x4a7846c0 -> 0xffff0d00\n");
        }
    }
    if (env_ulong("NK_EWSRV_SNAP", 0)) {
        /* The ROM build's EwSrv export slot 0x506ce7d0 holds 0x506cbf1d,
         * two bytes before the real Thumb prologue at 0x506cbf1e.  Snap it
         * like the E32 loader's export fixup so SplashScreen can call into
         * EwSrv instead of hitting an undefined halfword. */
        nk_w32(&cpu, 0x506ce7d0u, 0x506cbf1fu);
        printf("EwSrv export snap: 0x506cbf1d -> 0x506cbf1f (Thumb +2)\n");
    }
    if (env_ulong("NK_MAP_APP_LOW", 0)) {
        /* The direct app path copies ~400 KiB to 0x600000; on the phone this
         * is a physical buffer, not MMIO.  Map it as RAM so the copy is not
         * swallowed by the MMIO bus. */
        if (nk_alloc_ram(&cpu, 0x600000u, 0x1000000u) == 0)
            printf("app low buffer: mapped 0x600000..0x1600000\n");
    }
    if (env_ulong("NK_DFC_EMPTY", 0)) {
        /* Direct app entry: the kernel's DFC queue at [0x80001c28] has not
         * been initialised by Kern::Init1.  Make it an empty TDblQue so the
         * first SVC's DFC processor returns instead of calling garbage. */
        nk_w32(&cpu, 0x80001c28u, 0x80001c28u);
        printf("dfc queue: empty at 0x80001c28\n");
    }
    if (rom_image && getenv("NK_ENTRY") && getenv("NK_IMPORTMAP"))
        printf("warning: NK_IMPORTMAP patches shared EUser export slots; "
               "direct app entries should omit it (round 62)\n");
    install_svc_hook(&cpu, &ip);
    printf("run: sp=%#010x cpsr=%#010x budget=%ld infer=%d call-infer=%d policy=%d\n",
           cpu.r[13], cpu.cpsr, ip.budget, ip.infer_mode, ip.infer_calls,
           ip.call_policy);
    nk_interp_run(&cpu, &ip);

    printf("\n--- stop: %s (%d) at %#010x ---\n",
           nk_interp_reason(&ip), ip.st.stop_reason, ip.st.stop_pc);
    printf("insns=%lu (ARM %lu / Thumb %lu), mode switches=%lu, undefined=%lu, "
           "call fixups=%lu, unbound IAT=%lu, recoveries=%lu, irqs=%lu\n",
           ip.st.insns, ip.st.arm_insns, ip.st.thumb_insns,
           ip.st.mode_switches, ip.st.undefined, ip.st.call_fixups, ip.st.iat_hits,
           ip.st.recoveries, ip.st.irqs);
    printf("mmio: %lu reads, %lu writes; timer: %s, %lu expiries\n",
           nk_mmio_reads(), nk_mmio_writes(),
           nk_bus_timer_enabled() ? "on" : "off", nk_bus_irqs());
    printf("idle flag [0x8000000c] = %#010x, cp15 c1 = %#010x\n",
           nk_r32(&cpu, 0x8000000cu), cpu.cp15_c1);
    printf("regs: r0=%#010x r1=%#010x r2=%#010x r3=%#010x sp=%#010x lr=%#010x pc=%#010x\n",
           cpu.r[0], cpu.r[1], cpu.r[2], cpu.r[3], cpu.r[13], cpu.r[14], cpu.r[15]);
    printf("regs: r4=%#010x r5=%#010x r6=%#010x r7=%#010x r8=%#010x "
           "r9=%#010x r10=%#010x r11=%#010x r12=%#010x\n",
           cpu.r[4], cpu.r[5], cpu.r[6], cpu.r[7], cpu.r[8], cpu.r[9],
           cpu.r[10], cpu.r[11], cpu.r[12]);
    printf("cpsr=%#010x\n", cpu.cpsr);
    printf("last pcs:");
    int start = ip.last_n > 16 ? ip.last_n - 16 : 0;
    for (int i = start; i < ip.last_n; i++)
        printf(" %08x", ip.last[i & 15]);
    printf("\n");
    if (getenv("NK_CALLS")) {
        printf("shadow calls (%d):", ip.calls_n);
        for (int i = 0; i < ip.calls_n; i++)
            printf(" %08x", ip.calls[i].lr);
        printf("\n");
    }
    if (sched_on) {
        printf("sched slots: pending-slot=%#010x", nk_r32(&cpu, SCHED_PENDING));
        for (int i = 0; i < SCHED_SLOTS; i++) {
            sched_thread* s = &sched_slot_tab[i];
            if (!s->thread) continue;
            printf(" [%#010x state=%d status=%#010x pc=%#010x val=%#010x]",
                   s->thread, s->state, s->status, s->r[15],
                   s->status ? nk_r32(&cpu, s->status & ~3u) : 0);
        }
        printf("\n");
    }

    if (ip.st.stop_reason == NK_STOP_UNDEFINED) {
        uint32_t pc = ip.st.stop_pc;
        uint32_t aligned = pc & ~3u;
        printf("\n--- frontier ---\n");
        printf("mode=%s pc=%#010x lr=%#010x\n",
               (cpu.cpsr & NK_CPSR_T) ? "Thumb" : "ARM", pc, cpu.r[14]);
        printf("bytes @%#010x:", pc);
        for (int i = 0; i < 16; i++) printf(" %02x", nk_r8(&cpu, pc + i));
        printf("\n");
        if (pc & 3) {
            printf("nearest 4-aligned word @%#010x = %#010x",
                   aligned, nk_r32(&cpu, aligned));
            printf("  (Thumb PC is %u bytes past it)\n", pc - aligned);
        } else {
            printf("word @%#010x = %#010x\n", pc, nk_r32(&cpu, pc));
        }
        printf("hint: a Thumb/ARM boundary with no veneer looks like this; "
               "try NK_INFER=2 to rewind the halfword and execute as ARM.\n");
    }

    /* NK_DUMP=<addr>:<len>[,<addr>:<len>...] appends the guest memory a
     * bring-up run produced (decompressed images, page tables, ...).  The
     * destination is NK_DUMP_FILE (default out/memdump.bin) and each range is
     * also described on stdout, so a loader frontier can be inspected. */
    const char* dump = getenv("NK_DUMP");
    if (dump) {
        const char* path = getenv("NK_DUMP_FILE");
        if (!path) path = "out/memdump.bin";
        FILE* f = fopen(path, "wb");
        if (!f) {
            fprintf(stderr, "cannot open %s\n", path);
        } else {
            const char* p = dump;
            while (*p) {
                char* end = NULL;
                uint32_t addr = (uint32_t)strtoul(p, &end, 0);
                if (!end || *end != ':') break;
                uint32_t len = (uint32_t)strtoul(end + 1, &end, 0);
                if (g_tick_calls)
        printf("HAL tick getter calls: %lu (last value %lu)\n",
               g_tick_calls, (unsigned long)(ip.st.insns >> 10));
    printf("dump %#010x..%#010x (%u bytes)\n", addr, addr + len, len);
                for (uint32_t i = 0; i < len; i++)
                    fputc(nk_r8(&cpu, addr + i), f);
                if (!end || *end != ',') break;
                p = end + 1;
            }
            fclose(f);
            printf("wrote %s\n", path);
        }
    }

    nk_mem_free(&cpu);
    if (e32 < 0) free(code_img);
    free(rom);
    return 0;
}
