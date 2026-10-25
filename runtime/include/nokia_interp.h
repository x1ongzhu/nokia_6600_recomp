/*
 * nokia-recomp — minimal ARMv4T interpreter (ARM + Thumb).
 *
 * P0-3 of the bring-up plan.  The interpreter is the "truth" engine while the
 * static lifter only covers the functions we have discovered: it executes
 * unlifted thunks, indirect calls and mixed ARM/Thumb code, and it is the
 * execution engine for the boot trace.
 *
 * It is also mode-aware.  The 6600 kernel image stores Thumb code that calls
 * ARM code with a plain Thumb BL (the ROM builder normally inserts interworking
 * veneers), so on a failed decode we can optionally infer the target mode and
 * keep running.  `infer_calls` additionally fixes up interworking call sites:
 * a Thumb BL into a 4-byte-aligned ARM prologue switches to ARM (snapping back
 * over the veneer that the ROM linker would have inserted).  Both are bring-up
 * aids, logged loudly, not shipping features.
 *
 * Memory goes through the same sparse page map / MMIO bus as the lifted C.
 */
#ifndef NOKIA_INTERP_H
#define NOKIA_INTERP_H

#include "nokia_cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NK_CPSR_T       0x00000020u
#define NK_CPSR_MODE    0x0000001fu
#define NK_MODE_USR     0x10u
#define NK_MODE_FIQ     0x11u
#define NK_MODE_IRQ     0x12u
#define NK_MODE_SVC     0x13u
#define NK_MODE_ABT     0x17u
#define NK_MODE_UND     0x1bu
#define NK_MODE_SYS     0x1fu

enum {
    NK_STOP_BUDGET = 0,
    NK_STOP_UNDEFINED,
    NK_STOP_RETURN,
    NK_STOP_SWI,
    NK_STOP_IAT,        /* unbound import: ldr pc,[ip] slot is null */
    NK_STOP_OUT_OF_IMAGE, /* PC left the mapped ROM/RAM windows */
    NK_STOP_SPIN,       /* tight loop with no progress (bring-up watchdog) */
    NK_STOP_SELF_BRANCH,/* `b .` / `b pc`: a firmware panic/halt loop */
    NK_STOP_HOST
};

typedef struct nk_interp_stats {
    unsigned long insns;
    unsigned long arm_insns;
    unsigned long thumb_insns;
    unsigned long mode_switches;   /* inferred ARM<->Thumb changes */
    unsigned long undefined;       /* instructions with no implementation */
    unsigned long mmio_events;     /* filled in by the boot harness if wanted */
    unsigned long call_fixups;     /* interworking calls redirected/snapped */
    unsigned long iat_hits;        /* unbound import calls observed */
    unsigned long recoveries;      /* skipped calls (bring-up recovery) */
    uint32_t      stop_pc;
    int           stop_reason;
} nk_interp_stats;

/* A recoverable call frame.  The whole caller state is snapshotted at every
 * BL/BLX so that a fault inside a callee that cannot run (truncated packed
 * text, missing veneer, unimplemented import) can be rolled back and the call
 * treated as "returned 0".  This is a bring-up aid, not part of the CPU model;
 * it lets a boot trace keep walking the caller and discover the next frontier
 * instead of stopping at the first broken callee. */
typedef struct nk_recover_frame {
    uint32_t r[15];        /* r0..r14 at the call site */
    uint32_t cpsr;
    uint32_t ret_pc;       /* address after the BL/BLX */
    uint32_t call_pc;      /* address of the BL/BLX itself */
    uint32_t target;       /* raw encoded callee target */
    uint8_t  ret_thumb;    /* caller mode */
    int      calls_n;      /* shadow mode-stack depth before the call */
} nk_recover_frame;

#define NK_CALLMAP_MAX 512
#define NK_CODE_RANGE_MAX 1024

/* A guest code range: the interpreter will only repair a call target inside
 * one of these ranges.  The packed image stores its code and data in separate
 * sections, and a stale BL target can otherwise "snap" onto a plausible
 * prologue in ROMFS/rodata. */
typedef struct nk_code_range {
    uint32_t lo;
    uint32_t hi;         /* exclusive */
} nk_code_range;

/* Sentinel targets for tiny host-side helpers (compiler runtime routines whose
 * packed text is missing or ambiguous).  The interpreter executes them
 * directly and returns to the caller. */
#define NK_HLE_DIV 0xFFFFFFFDu
#define NK_HLE_MOD 0xFFFFFFFEu
#define NK_HLE_MEMZERO 0xFFFFFFFCu
#define NK_HLE_ALLOC 0xFFFFFFFBu
#define NK_HLE_MEMCPY 0xFFFFFFFAu
#define NK_HLE_ZERO2  0xFFFFFFF9u   /* zero two words at [r0] (TTime/64-bit out) */

/* A call-site fixup: the packed image's BL target is stale, but we know the
 * real callee.  Keyed by the call-site PC (not the target) so the same stale
 * target can resolve differently at different sites. */
typedef struct nk_callmap_entry {
    uint32_t call_pc;
    uint32_t target;
    uint8_t  thumb;
} nk_callmap_entry;

/* Ring buffer of the most recent BL/BLX sites and their resolved callees.
 * The shadow call stack only shows calls that are still on the stack; when a
 * trace runs into a broken loop deep in a library the ring still shows how it
 * got there.  Used by NK_WATCH (see boot_kernel.c). */
#define NK_CALL_RING 1024
typedef struct nk_call_rec {
    uint32_t call_pc;
    uint32_t raw_target;   /* target encoded in the instruction */
    uint32_t target;       /* target after interworking repair */
    uint32_t r0, r1, r2, r3;
    uint32_t sp, lr;
    uint8_t  caller_thumb;
    uint8_t  callee_thumb;
} nk_call_rec;

typedef struct nk_interp {
    long     budget;        /* instructions to execute; <=0 means 10,000,000 */
    long     trace_limit;   /* trace this many instructions; 0 = off */
    int      trace;         /* print each executed instruction */
    int      infer_mode;    /* try the other instruction set on a bad decode */
    int      infer_calls;   /* fix Thumb/ARM mode at BL/BLX call sites */
    /* How to repair an unlinked/interworking call target:
     *   0 = snap back to the nearest prologue (default)
     *   1 = execute the target as ARM (round a 2-mod-4 target down)
     *   2 = snap forward to the next prologue
     *   3 = snap back, then forward, then ARM-at-target
     */
    int      call_policy;
    /* How far back to look for the callee's prologue.  The interesting bias is
     * mostly on Thumb->ARM calls (the ROM's missing interworking veneers),
     * while ARM->ARM calls include legitimate shared basic blocks whose
     * nearest prologue belongs to a different function.  Keep them separate. */
    uint32_t snap_window;        /* default for both */
    uint32_t snap_window_thumb;
    uint32_t snap_window_arm;
    int      snap_nofast;   /* ignore a plausible leaf/shared entry at the raw
                             * target and always snap to the nearest prologue */
    int      call_fixup_log;/* log the first N call fixups (0 = quiet) */
    int      iat_fake_return;/* unresolved imports return 0 instead of stopping */
    int      iat_log;       /* log the first N unbound imports */
    int      stop_on_swi;   /* stop at the first SWI instead of continuing */
    int      stop_selfb;    /* stop at `b .` (firmware panic/halt loop) */
    /* EKA1 executive calls are `svc #N` stubs.  The real CPU enters the
     * kernel SVC vector; the kernel then dispatches through a table of
     * service functions and returns to the caller's LR (the stub is a call
     * gate, not a normal post-SWI continuation).  Until the banked-register
     * exception model is in place, `swi_direct` models that call gate by
     * calling the table entry directly with the caller's LR still live. */
    int      swi_direct;
    uint32_t swi_table;     /* kernel 32-bit service table base (0x50314aec) */
    int      swi_log;       /* log the first N direct SWI dispatches */
    /* Banked-register / SPSR model.  Off by default so the historical traces
     * stay comparable; enable with NK_BANKED=1 when the kernel starts
     * switching modes (the round-18 UND-mode frontier needs it). */
    int      banked;
    /* Bitmask of executive-call indices that are modelled as "request
     * already complete": [r0] (a TRequestStatus*) is set to 0 and the call
     * returns immediately.  This stands in for the interrupt/DMA completion
     * path a headless boot does not have yet.  Bit i covers SWI index i. */
    uint64_t swi_complete[8];
    /* Bring-up allocator: EUser's RHeap is created by the kernel/scheduler
     * startup that a direct E32-entry boot skips.  When enabled, a call to
     * the guest RHeap::Alloc entry is served by a bump allocator over the
     * harness heap instead of walking an uninitialised heap object.  This is
     * an explicit stand-in (like NK_SWI_COMPLETE), not a heap emulation. */
    int      alloc_hle;
    uint32_t alloc_pc;      /* guest RHeap::Alloc entry (default 0x5038e2ec) */
    uint32_t realloc_pc;    /* guest RHeap1::ReAlloc1 entry */
    uint32_t free_pc;       /* guest RHeap::Free entry */
    uint32_t alloc_base;    /* first bump block header */
    uint32_t alloc_cur;     /* bump cursor, inside hle_heap */
    uint32_t alloc_end;
    unsigned long alloc_hits;
    unsigned long realloc_hits;
    unsigned long free_hits;
    int      alloc_log;     /* log the first N allocations */
    /* Bring-up recovery: when a callee faults (undefined instruction, PC
     * escape), roll back to the most recent BL/BLX and continue as if that
     * call had returned 0.  Logs the skipped call.  Off by default. */
    int      recover;
    int      recover_max;   /* stop after this many skips (default 256) */
    int      recover_log;   /* log the first N skips (default 16) */
    uint32_t trace_from;    /* only trace PCs >= this (0 = all) */
    uint32_t return_pc;     /* stop when PC reaches this address (0 = never) */
    uint8_t  return_thumb;

    nk_interp_stats st;

    /* Shadow call stack: BL/BLX pushes the return address + caller mode so a
     * return can restore the mode even though ARMv4T's LR carries no T bit. */
    struct { uint32_t lr; uint8_t thumb; } calls[64];
    int calls_n;

    nk_recover_frame rec[64];
    int rec_n;

    nk_callmap_entry callmap[NK_CALLMAP_MAX];
    int callmap_n;

    /* Executable ranges.  A call target outside every range is a data address
     * and must never be accepted as a callee. */
    nk_code_range code[NK_CODE_RANGE_MAX];
    int code_n;

    /* Bump heap used by NK_HLE_ALLOC (bring-up only). */
    uint32_t hle_heap;
    uint32_t hle_heap_end;

    uint32_t last[16];
    int last_n;

    /* Bring-up observability: recent calls and a one-shot PC watch. */
    nk_call_rec call_ring[NK_CALL_RING];
    unsigned    call_ring_n;     /* total calls recorded */
    uint32_t    watch_pc;        /* dump state the first time PC hits this */
    int         watch_hits;      /* how many times to report (-1 = every) */
    int         watch_log;       /* calls to print when the watch fires */
    int         watch_mem_reg;   /* register whose memory is dumped (-1 = off) */
    uint32_t    watch_mem_len;   /* bytes to dump around that register */

    /* Bring-up watchdog: a tight loop that keeps executing the same few
     * addresses (typically a descriptor scan with a bogus argument) is treated
     * as a fault and rolled back through the recovery frame.  spin_max is the
     * number of visits to a single PC before the loop is declared stuck;
     * 0 disables the detector. */
    uint32_t spin_max;
    uint32_t spin_tag[1024];
    uint32_t spin_cnt[1024];

    /* Reject a PC outside the ROM/low-alias/high-vector windows.  A corrupted
     * return otherwise runs the heap as Thumb code for the rest of the budget. */
    int require_code;
    /* The mask-ROM/boot path runs the first ROM bank through the low physical
     * alias (address 0).  Off by default: a stale kernel call target of 0
     * must stay a fault/skip, not start executing low RAM. */
    int allow_low_alias;
} nk_interp_t;

void        nk_interp_init(nk_interp_t* ip);
int         nk_interp_run(nk_cpu_t* c, nk_interp_t* ip);
/* Initialise one ARM mode bank (USR/FIQ/IRQ/SVC/ABT/UND).  Used by the
 * boot harness to provide the mode stacks a mask-ROM startup would set up. */
void        nk_bank_init(nk_cpu_t* c, uint32_t mode, uint32_t sp, uint32_t lr);
int         nk_interp_call(nk_cpu_t* c, uint32_t target);
/* Add a call-site fixup (used by the boot harness to load config/callmap-*.txt). */
int         nk_callmap_add(nk_interp_t* ip, uint32_t call_pc, uint32_t target,
                           int thumb);
/* Declare an executable address range.  Call repair will not leave it. */
int         nk_code_range_add(nk_interp_t* ip, uint32_t lo, uint32_t hi);
const char* nk_interp_reason(const nk_interp_t* ip);
const char* nk_interp_stop_name(int reason);

/* Copy a host buffer into guest memory through the page map / MMIO bus. */
void nk_poke(nk_cpu_t* c, uint32_t addr, const void* src, uint32_t len);

/* Bring-up linker aid: if `target` is not an ARM function prologue but a
 * prologue exists a few bytes before it (the missing interworking veneer),
 * return that prologue; otherwise return `target`.  Thumb (odd) targets are
 * returned unchanged. */
uint32_t nk_snap_entry(nk_cpu_t* c, uint32_t target);

#ifdef __cplusplus
}
#endif
#endif /* NOKIA_INTERP_H */
