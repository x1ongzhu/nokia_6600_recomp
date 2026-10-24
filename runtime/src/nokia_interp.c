/*
 * nokia-recomp — ARMv4T interpreter (ARM + Thumb) and mode inference.
 *
 * This is deliberately a *bring-up* CPU: it executes the guest image through
 * the same sparse memory / MMIO bus as the lifted C, logs the frontier, and
 * can continue past a Thumb/ARM boundary that a flat ROM copy left unlinked.
 *
 * Modelled: ARMv4T data processing, shifts, multiply/long multiply,
 * single/halfword/signed transfers, LDM/STM, B/BL/BX, MRS/MSR, SWI (logged),
 * CP15 (logged, no-op), and the full Thumb-1 set used by S60 2.0 code.
 *
 * Not modelled: exceptions, banked registers, MMU translation, the write
 * buffer, and ARMv5 instructions.  They are reported, not guessed.
 */
#include <stdio.h>
#include <string.h>

#include "nokia_interp.h"
#include "nokia_rt.h"

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static inline int thumb(nk_cpu_t* c) { return (c->cpsr & NK_CPSR_T) != 0; }

static inline void set_thumb(nk_cpu_t* c, int t) {
    if (t) c->cpsr |= NK_CPSR_T;
    else   c->cpsr &= ~NK_CPSR_T;
}

static inline uint32_t rp_arm(nk_cpu_t* c, unsigned n, uint32_t pc) {
    return n == 15 ? pc + 8 : c->r[n];
}

static int cond_true(nk_cpu_t* c, unsigned cond) {
    switch (cond) {
    case 0x0: return nk_zf(c);
    case 0x1: return !nk_zf(c);
    case 0x2: return nk_cf(c);
    case 0x3: return !nk_cf(c);
    case 0x4: return nk_nf(c);
    case 0x5: return !nk_nf(c);
    case 0x6: return nk_vf(c);
    case 0x7: return !nk_vf(c);
    case 0x8: return nk_cf(c) && !nk_zf(c);
    case 0x9: return !nk_cf(c) || nk_zf(c);
    case 0xa: return nk_nf(c) == nk_vf(c);
    case 0xb: return nk_nf(c) != nk_vf(c);
    case 0xc: return !nk_zf(c) && nk_nf(c) == nk_vf(c);
    case 0xd: return nk_zf(c) || nk_nf(c) != nk_vf(c);
    case 0xe: return 1;
    default:  return 0;
    }
}

static inline void set_nz(nk_cpu_t* c, uint32_t v) { nk_set_nz(c, v); }

static uint32_t add_flags(nk_cpu_t* c, uint32_t a, uint32_t b, uint32_t cin) {
    uint64_t u = (uint64_t)a + (uint64_t)b + (uint64_t)cin;
    uint32_t r = (uint32_t)u;
    set_nz(c, r);
    nk_setf(c, NK_FLAG_C, (uint32_t)(u >> 32));
    nk_setf(c, NK_FLAG_V, (~(a ^ b) & (a ^ r)) >> 31);
    return r;
}

static uint32_t sub_flags(nk_cpu_t* c, uint32_t a, uint32_t b, uint32_t borrow) {
    uint64_t u = (uint64_t)a - (uint64_t)b - (uint64_t)borrow;
    uint32_t r = (uint32_t)u;
    set_nz(c, r);
    nk_setf(c, NK_FLAG_C, !(u >> 63));        /* no borrow */
    nk_setf(c, NK_FLAG_V, ((a ^ b) & (a ^ r)) >> 31);
    return r;
}

/* barrel shifter: type 0 LSL, 1 LSR, 2 ASR, 3 ROR */
static uint32_t shift_val(uint32_t v, unsigned type, unsigned amt, uint32_t* carry) {
    uint32_t c = carry ? *carry : 0;
    switch (type) {
    case 0: /* LSL */
        if (amt == 0) return v;
        if (amt < 32) { c = (v >> (32 - amt)) & 1; v <<= amt; }
        else { c = (amt == 32) ? (v & 1) : 0; v = 0; }
        break;
    case 1: /* LSR */
        if (amt == 0) { c = v >> 31; v = 0; }
        else if (amt < 32) { c = (v >> (amt - 1)) & 1; v >>= amt; }
        else { c = (amt == 32) ? (v >> 31) & 1 : 0; v = 0; }
        break;
    case 2: /* ASR */
        if (amt == 0 || amt >= 32) { c = v >> 31; v = (uint32_t)((int32_t)v >> 31); }
        else { c = (v >> (amt - 1)) & 1; v = (uint32_t)((int32_t)v >> amt); }
        break;
    default: /* ROR */
        if (amt == 0) {                        /* RRX */
            uint32_t nc = v & 1;
            v = (v >> 1) | (c << 31);
            c = nc;
        } else {
            amt &= 31;
            if (amt == 0) { c = v >> 31; }
            else { v = (v >> amt) | (v << (32 - amt)); c = v >> 31; }
        }
        break;
    }
    if (carry) *carry = c;
    return v;
}

/* ARM operand 2 for data processing.  `op` is the full instruction word. */
static uint32_t arm_op2(nk_cpu_t* c, uint32_t op, uint32_t pc, uint32_t* carry) {
    if (op & (1u << 25)) {                       /* immediate */
        unsigned rot = ((op >> 8) & 0xf) * 2;
        uint32_t v = op & 0xff;
        if (rot) v = (v >> rot) | (v << (32 - rot));
        *carry = v >> 31;
        return v;
    }
    uint32_t v = rp_arm(c, op & 0xf, pc);
    unsigned type = (op >> 5) & 3;
    if (op & (1u << 4)) {                        /* register shift */
        unsigned rs = (op >> 8) & 0xf;
        unsigned amt = c->r[rs] & 0xff;
        return shift_val(v, type, amt, carry);
    }
    unsigned amt = (op >> 7) & 0x1f;
    if (amt == 0 && type != 0) amt = 32;
    return shift_val(v, type, amt, carry);
}

static int thumb_ok(uint16_t h);
static int arm_ok(uint32_t op);

static int in_code(const nk_interp_t* ip, uint32_t a) {
    for (int i = 0; i < ip->code_n; i++)
        if (a >= ip->code[i].lo && a < ip->code[i].hi) return 1;
    return ip->code_n == 0;   /* no ranges declared: preserve old behaviour */
}

static void trace_pc(nk_interp_t* ip, nk_cpu_t* c, uint32_t pc, uint32_t insn) {
    if (!ip->trace || ip->trace_limit <= 0) return;
    if (ip->st.insns >= (unsigned long)ip->trace_limit) return;
    if (ip->trace_from && pc < ip->trace_from) return;
    fprintf(stderr, "[interp] %c %08x  %08x  r0=%08x r1=%08x r2=%08x r3=%08x sp=%08x lr=%08x\n",
            thumb(c) ? 'T' : 'A', pc, insn, c->r[0], c->r[1], c->r[2], c->r[3],
            c->r[13], c->r[14]);
}

static void remember(nk_interp_t* ip, uint32_t pc) {
    ip->last[ip->last_n++ & 15] = pc;
}

/* ------------------------------------------------------------------ */
/* shadow call stack (mode restore)                                    */
/* ------------------------------------------------------------------ */

static void push_call(nk_interp_t* ip, nk_cpu_t* c, uint32_t lr,
                      uint32_t call_pc, uint32_t target) {
    if (ip->calls_n < (int)(sizeof ip->calls / sizeof ip->calls[0])) {
        if (ip->recover && ip->rec_n < (int)(sizeof ip->rec / sizeof ip->rec[0])) {
            nk_recover_frame* f = &ip->rec[ip->rec_n];
            for (int i = 0; i < 15; i++) f->r[i] = c->r[i];
            f->cpsr = c->cpsr;
            f->ret_pc = lr & ~1u;
            f->call_pc = call_pc;
            f->target = target;
            f->ret_thumb = (uint8_t)thumb(c);
            f->calls_n = ip->calls_n;
            ip->rec_n++;
        }
        ip->calls[ip->calls_n].lr = lr;
        ip->calls[ip->calls_n].thumb = (uint8_t)thumb(c);
        ip->calls_n++;
    }
}

static int pop_call(nk_interp_t* ip, uint32_t pc, int* out_thumb) {
    if (ip->calls_n > 0 && ip->calls[ip->calls_n - 1].lr == pc) {
        ip->calls_n--;
        *out_thumb = ip->calls[ip->calls_n].thumb;
        /* The recovery stack mirrors the mode stack; drop the matching
         * frame (and any stale deeper ones). */
        if (ip->rec_n > ip->calls_n) ip->rec_n = ip->calls_n;
        return 1;
    }
    return 0;
}

/* Undo the bookkeeping of a call that is being handled by an HLE stub. */
static void drop_call(nk_interp_t* ip) {
    if (ip->calls_n > 0) ip->calls_n--;
    if (ip->rec_n > ip->calls_n) ip->rec_n = ip->calls_n;
}

/* Roll back to the most recent BL/BLX and treat it as "returned 0".
 * Returns 1 when the caller was resumed, 0 when recovery is disabled or the
 * stack is empty. */
static int recover_call(nk_interp_t* ip, nk_cpu_t* c, int reason) {
    if (!ip->recover || ip->rec_n <= 0) return 0;
    if ((long)ip->st.recoveries >= (long)ip->recover_max) return 0;
    uint32_t fault_pc = c->r[15];
    nk_recover_frame* f = &ip->rec[--ip->rec_n];
    if (ip->recover_log-- > 0) {
        fprintf(stderr,
                "[interp] recover #%lu: %s at %#010x in %s call %#010x -> %#010x "
                "(depth %d, r0=%#x r1=%#x r2=%#x r3=%#x); skip to %#010x with r0=0\n",
                ip->st.recoveries + 1, nk_interp_stop_name(reason), fault_pc,
                f->ret_thumb ? "Thumb" : "ARM", f->call_pc, f->target,
                f->calls_n, f->r[0], f->r[1], f->r[2], f->r[3], f->ret_pc);
    }
    for (int i = 0; i < 15; i++) c->r[i] = f->r[i];
    c->cpsr = f->cpsr;
    c->r[0] = 0;
    c->r[15] = f->ret_pc;
    ip->calls_n = f->calls_n;
    ip->rec_n = f->calls_n;
    ip->st.recoveries++;
    ip->st.stop_reason = 0;
    ip->st.stop_pc = 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* validity checks used by mode inference                              */
/* ------------------------------------------------------------------ */

static int arm_ok(uint32_t op) {
    if (op == 0 || op == 0xffffffffu) return 0;
    unsigned cond = op >> 28;
    if (cond == 0xf) return op >= 0x0f000000u && op < 0x10000000u; /* SWI */
    unsigned cls = (op >> 26) & 3;
    switch (cls) {
    case 0: {
        if ((op & 0x0f800ff0u) == 0x01000090u) return 1;      /* swp */
        unsigned op4 = (op >> 4) & 0xf;
        if (op4 == 9) return 1;                                /* mul family */
        if ((op & 0x0fbf0fffu) == 0x010f0000u) return 1;       /* mrs */
        if ((op & 0x0db0f000u) == 0x0120f000u) return 1;       /* msr reg */
        if ((op & 0x0fb0f000u) == 0x0320f000u) return 1;       /* msr imm */
        if ((op & 0x90) == 0x90 && (op & 0x60) != 0) return 1;  /* halfword */
        return 1;                                              /* data processing */
    }
    case 1: return 1;                                          /* ldr/str */
    case 2: return 1;                                          /* ldm/stm/branch */
    default: return ((op & 0x0e000000u) == 0x0e000000u);       /* coproc */
    }
}

static int thumb_ok(uint16_t h) {
    if (h == 0) return 1;
    switch (h >> 13) {
    case 0: case 1: case 2: case 3: case 4: case 5:
    case 6: case 7: return 1;
    default: return 1;
    }
}

/* ------------------------------------------------------------------ */
/* interworking call repair (bring-up aid)                             */
/*                                                                     */
/* The packed E32Image is the compiler/linker output before the ROM     */
/* build inserts ARM<->Thumb veneers.  A Thumb BL into ARM code lands   */
/* a few bytes *inside* the callee (the size of the missing veneer), so */
/* the interpreter can snap back to the nearest ARM prologue and switch */
/* mode.  This is deliberately conservative: only a real prologue       */
/* (stmdb sp!, {..,lr} / sub sp / mov r12,sp) qualifies.               */
/* ------------------------------------------------------------------ */

static int arm_import_stub(nk_cpu_t* c, uint32_t a) {
    if (a & 3u) return 0;
    uint32_t op = nk_r32(c, a);
    if ((op & 0x0f7f0000u) != 0x051f0000u) return 0;   /* ldr r?, [pc, #imm] */
    if (((op >> 12) & 0xfu) != 12u) return 0;          /* into ip (r12) */
    uint32_t op2 = nk_r32(c, a + 4);
    return (op2 & 0x0fffffffu) == 0x059cf000u;         /* ldr pc, [ip] */
}

static int arm_strong_start(nk_cpu_t* c, uint32_t a) {
    if (a & 3u) return 0;
    uint32_t op = nk_r32(c, a);
    if (op == 0 || op == 0xffffffffu) return 0;
    if (arm_import_stub(c, a)) return 1;
    if ((op >> 28) == 0xfu) return 0;
    if ((op & 0xffff0000u) == 0xe92d0000u) return 1;   /* stmdb sp!, {...} */
    if ((op & 0xfffff000u) == 0xe24dd000u) return 1;   /* sub sp, sp, #imm */
    if (op == 0xe1a0c00du) return 1;                   /* mov r12, sp */
    return 0;
}

static int thumb_strong_start(nk_cpu_t* c, uint32_t a) {
    if (a & 1u) return 0;
    uint16_t h = nk_r16(c, a);
    if ((h & 0xff00u) == 0xb500u) return 1;            /* push {.., lr} */
    if ((h & 0xff00u) == 0xb400u) return 1;            /* push {...} */
    if ((h & 0xff00u) == 0xb000u) return 1;            /* add/sub sp */
    return 0;
}

/* Is `a` immediately after a function terminator / alignment padding?
 * A real entry point (after the missing ROM veneer) usually is.  This keeps
 * the backwards search from latching onto a `b`/`push` in the middle of a
 * function or literal pool. */
static int boundary_before(nk_cpu_t* c, uint32_t a, int thumb) {
    if (a < 8) return 0;
    if (thumb) {
        uint16_t p = nk_r16(c, a - 2);
        if (p == 0x0000u || p == 0x46c0u || p == 0x4770u) return 1;
        if ((p & 0xff00u) == 0xbd00u) return 1;        /* pop {.., pc} */
        uint32_t pw = nk_r32(c, (a - 4) & ~3u);
        if (pw == 0xe12fff1eu || pw == 0xe1a0f00eu) return 1;
        if ((pw & 0x0e000000u) == 0x0a000000u) return 1;
        return 0;
    }
    uint32_t pw = nk_r32(c, a - 4);
    if (pw == 0x00000000u || pw == 0xffffffffu) return 1;
    if (pw == 0xe12fff1eu || pw == 0xe1a0f00eu) return 1;   /* bx lr / mov pc,lr */
    if ((pw & 0xffff8000u) == 0xe8bd8000u) return 1;        /* pop {.., pc} */
    if ((pw & 0x0f000000u) == 0x0a000000u) return 1;        /* b */
    if (pw >= 0x50000000u && pw < 0x81000000u) return 1;    /* literal/pointer */
    if ((pw & 0xffff0000u) == 0xe92d0000u) return 0;
    return 0;
}

static int arm_entry_at(nk_cpu_t* c, uint32_t a) {
    return arm_strong_start(c, a) && boundary_before(c, a, 0);
}
static int thumb_entry_at(nk_cpu_t* c, uint32_t a) {
    return thumb_strong_start(c, a) && boundary_before(c, a, 1);
}

/* Search backwards from `t` for the nearest entry prologue in either mode.
 * This is the runtime stand-in for the ROM linker's veneers: the pre-link
 * image's call/export targets are biased by the missing veneer bytes. */
static int snap_call_entry(nk_interp_t* ip, nk_cpu_t* c, uint32_t t,
                           uint32_t window, uint32_t call_pc, int nofast,
                           uint32_t* out, int* out_thumb) {
    if (t & 1u) { *out = t & ~1u; *out_thumb = in_code(ip, t & ~1u); return *out_thumb; }
    if (window < 0x40u) window = 0x40u;

    int found = 0;
    uint32_t best = t;
    int best_thumb = 0;

    /* Fast path: the encoded target is already a plausible entry.
     *
     *  - a strong ARM prologue is a function entry no matter what precedes
     *    it (the previous word may be the call itself);
     *  - a valid ARM instruction preceded by a function terminator is a
     *    legitimate leaf entry (leaf functions need no prologue);
     *  - a Thumb push is a legitimate Thumb entry.
     * Without this, the backward search happily "snaps" a leaf callee back
     * into its caller, which turns a call into infinite recursion.
     *
     * NK_SNAP_NOFAST=1 skips this and always looks for a prologue, which is
     * the right behaviour when a stale call target happens to land on a
     * shared entry point inside an unrelated neighbouring function. */
    if (!nofast && in_code(ip, t) &&
        (t & 3u) == 0 && arm_ok(nk_r32(c, t)) &&
        (arm_strong_start(c, t) || boundary_before(c, t, 0))) {
        *out = t; *out_thumb = 0; return 1;
    }
    if (!nofast && in_code(ip, t) &&
        thumb_strong_start(c, t) && boundary_before(c, t, 1)) {
        *out = t; *out_thumb = 1; return 1;
    }

    /* Nearest prologue that is preceded by a function terminator.
     * Reject a candidate whose function would contain the call site: that is
     * the caller itself (the packed image's call targets can be hundreds of
     * bytes into the callee, so the window has to be wider than one function
     * for the real case, but never wide enough to jump back into the caller).
     *
     * NB: `t < call_pc` for backward calls, so the containment test only
     * matters for forward calls inside the caller's own body. */
    for (uint32_t d = 0; d <= window; d += 2) {
        uint32_t a = (t - d);
        if (a < 8) break;
        if (!in_code(ip, a)) continue;
        int contains_caller = (a <= call_pc && call_pc < t);
        if (contains_caller) continue;
        if ((a & 3u) == 0 && arm_entry_at(c, a)) {
            best = a; best_thumb = 0; found = 1; break;
        }
        if (thumb_entry_at(c, a)) {
            best = a; best_thumb = 1; found = 1; break;
        }
    }
    if (!found) return 0;
    *out = best;
    *out_thumb = best_thumb;
    return 1;
}

/* Forward variant: the packed image may keep the callee's entry *after* the
 * address encoded in the call (a reserved veneer slot that the ROM build would
 * fill in).  Used only by the bring-up call policies. */
static int snap_call_entry_fwd(nk_interp_t* ip, nk_cpu_t* c, uint32_t t,
                               uint32_t* out, int* out_thumb) {
    if (t & 1u) { *out = t & ~1u; *out_thumb = in_code(ip, t & ~1u); return *out_thumb; }
    for (uint32_t d = 0; d <= 0x40u; d += 2) {
        uint32_t a = t + d;
        if (a < t) break;
        if (!in_code(ip, a)) continue;
        if ((a & 3u) == 0 && arm_entry_at(c, a)) {
            *out = a; *out_thumb = 0; return 1;
        }
        if (thumb_entry_at(c, a)) {
            *out = a; *out_thumb = 1; return 1;
        }
    }
    return 0;
}

/* Execute the target's bytes as ARM.  Thumb BL targets that are 2 mod 4 are
 * rounded down to the enclosing ARM halfword: every ARM instruction starts on
 * a 4-byte boundary, so the extra 2 bits cannot be an ARM address. */
static int arm_at_target(nk_interp_t* ip, nk_cpu_t* c, uint32_t t, uint32_t* out) {
    uint32_t a = t & ~3u;
    if (a < 4) return 0;
    if (!in_code(ip, a)) return 0;
    if (!arm_ok(nk_r32(c, a))) return 0;
    *out = a;
    return 1;
}

int nk_callmap_add(nk_interp_t* ip, uint32_t call_pc, uint32_t target,
                   int thumb) {
    if (ip->callmap_n >= NK_CALLMAP_MAX) return 0;
    ip->callmap[ip->callmap_n].call_pc = call_pc;
    ip->callmap[ip->callmap_n].target = target;
    ip->callmap[ip->callmap_n].thumb = (uint8_t)(thumb != 0);
    ip->callmap_n++;
    return 1;
}

int nk_code_range_add(nk_interp_t* ip, uint32_t lo, uint32_t hi) {
    if (ip->code_n >= NK_CODE_RANGE_MAX || hi <= lo) return 0;
    ip->code[ip->code_n].lo = lo;
    ip->code[ip->code_n].hi = hi;
    ip->code_n++;
    return 1;
}

uint32_t nk_snap_entry(nk_cpu_t* c, uint32_t target) {    /* Export entries are absolute ARM addresses in this image; a Thumb export
     * would carry bit 0.  Keep this conservative: only an even, 4-aligned ARM
     * entry, and only a short snap (the observed export bias is 0x18). */
    if (target & 3u) return target;
    if (arm_entry_at(c, target)) return target;
    for (uint32_t d = 4; d <= 0x20u; d += 4) {
        uint32_t a = (target - d) & ~3u;
        if (arm_entry_at(c, a)) return a;
    }
    return target;
}

static void record_call(nk_interp_t* ip, nk_cpu_t* c, uint32_t call_pc,
                        uint32_t raw, uint32_t resolved, int caller_thumb) {
    nk_call_rec* r = &ip->call_ring[ip->call_ring_n % NK_CALL_RING];
    r->call_pc = call_pc;
    r->raw_target = raw;
    r->target = resolved;
    r->r0 = c->r[0];
    r->r1 = c->r[1];
    r->r2 = c->r[2];
    r->r3 = c->r[3];
    r->sp = c->r[13];
    r->lr = c->r[14];
    r->caller_thumb = (uint8_t)(caller_thumb != 0);
    r->callee_thumb = (uint8_t)(thumb(c) != 0);
    ip->call_ring_n++;
}

static void dump_call_ring(nk_interp_t* ip, int n) {
    unsigned total = ip->call_ring_n;
    if (n <= 0) n = 16;
    if ((unsigned)n > total) n = (int)total;
    if (n > NK_CALL_RING) n = NK_CALL_RING;
    fprintf(stderr, "[watch] last %d of %u calls:\n", n, total);
    for (int i = n - 1; i >= 0; i--) {
        const nk_call_rec* r = &ip->call_ring[(total - 1 - (unsigned)i) % NK_CALL_RING];
        fprintf(stderr,
                "[watch]   %#010x -> %#010x%s (%s->%s) r0=%#x r1=%#x r2=%#x r3=%#x sp=%#x\n",
                r->call_pc, r->target,
                r->target != r->raw_target ? " [fixed]" : "",
                r->caller_thumb ? "T" : "A", r->callee_thumb ? "T" : "A",
                r->r0, r->r1, r->r2, r->r3, r->sp);
    }
}

/* Bring-up watchdog.  A tight loop (a handful of PCs repeated for tens of
 * thousands of iterations) almost always means a library call received a
 * bogus descriptor or length and is scanning a 2 GiB address range.  Count
 * visits per PC in a direct-mapped table; when one PC exceeds spin_max the
 * caller rewinds through the recovery frame instead of burning the budget. */
static int spin_tick(nk_interp_t* ip, uint32_t pc) {
    if (!ip->spin_max) return 0;
    uint32_t slot = (pc >> 2) & 1023u;
    if (ip->spin_tag[slot] != pc) {
        ip->spin_tag[slot] = pc;
        ip->spin_cnt[slot] = 0;
        return 0;
    }
    if (++ip->spin_cnt[slot] < ip->spin_max) return 0;
    fprintf(stderr, "[interp] spin: %#010x visited %u times (tight loop)\n",
            pc, ip->spin_cnt[slot]);
    memset(ip->spin_tag, 0, sizeof ip->spin_tag);
    memset(ip->spin_cnt, 0, sizeof ip->spin_cnt);
    return 1;
}

/* Decide the callee mode at a call site.  Returns 1 when the target was
 * repaired (mode and/or address changed) and 0 otherwise. */
static int infer_call(nk_interp_t* ip, nk_cpu_t* c, int caller_thumb,
                      uint32_t call_pc, uint32_t* target) {
    uint32_t t = *target;
    if (!ip->infer_calls) return 0;

    /* Explicit call-site fixup: the packed image's encoded target is stale but
     * the map has the real callee.  Keyed by the call site, because the same
     * stale target can mean different things at different callers. */
    for (int i = 0; i < ip->callmap_n; i++) {
        if (ip->callmap[i].call_pc != call_pc) continue;
        uint32_t mapped = ip->callmap[i].target;
        if (mapped == NK_HLE_DIV || mapped == NK_HLE_MOD ||
            mapped == NK_HLE_MEMZERO || mapped == NK_HLE_ALLOC ||
            mapped == NK_HLE_MEMCPY) {
            uint32_t a = c->r[0], b = c->r[1];
            if (mapped == NK_HLE_ALLOC) {
                uint32_t size = (a + 7u) & ~7u;
                if (ip->hle_heap && ip->hle_heap + size <= ip->hle_heap_end) {
                    c->r[0] = ip->hle_heap;
                    ip->hle_heap += size;
                } else {
                    c->r[0] = 0;
                }
            } else if (mapped == NK_HLE_MEMZERO) {
                for (uint32_t i = 0; i < b; i++) nk_w8(c, a + i, 0);
                c->r[0] = a;
            } else if (mapped == NK_HLE_MEMCPY) {
                uint32_t src = c->r[1], len = c->r[2];
                /* Refuse absurd copies: a mis-restored descriptor can claim a
                 * Multi-MiB length and turn the trace into a host-side stall. */
                if (len > 0x01000000u) len = 0;
                for (uint32_t i = 0; i < len; i++)
                    nk_w8(c, a + i, nk_r8(c, src + i));
                c->r[0] = a;
            } else {
                c->r[0] = (b == 0) ? 0 : (mapped == NK_HLE_DIV ? a / b : a % b);
            }
            ip->st.call_fixups++;
            if (ip->call_fixup_log-- > 0) {
                if (mapped == NK_HLE_MEMZERO)
                    fprintf(stderr, "[interp] call: HLE memzero %#010x (%#x bytes)\n",
                            call_pc, b);
                else if (mapped == NK_HLE_MEMCPY)
                    fprintf(stderr, "[interp] call: HLE memcpy %#010x (%#x -> %#x, %#x bytes)\n",
                            call_pc, c->r[1], a, c->r[2]);
                else if (mapped == NK_HLE_ALLOC)
                    fprintf(stderr, "[interp] call: HLE alloc %#010x (%#x bytes -> %#010x)\n",
                            call_pc, a, c->r[0]);
                else
                    fprintf(stderr, "[interp] call: HLE %s %#010x (%u / %u -> %u)\n",
                            mapped == NK_HLE_DIV ? "div" : "mod", call_pc, a, b, c->r[0]);
            }
            return 2;                      /* handled: caller must skip the call */
        }
        *target = mapped;
        set_thumb(c, ip->callmap[i].thumb);
        ip->st.call_fixups++;
        if (ip->call_fixup_log-- > 0)
            fprintf(stderr, "[interp] call: callmap %#010x -> %#010x (%s)\n",
                    call_pc, mapped, ip->callmap[i].thumb ? "Thumb" : "ARM");
        return 1;
    }

    /* ARM import stubs are `ldr ip,[pc]; ldr pc,[ip]; .word slot`; the
     * pre-link call site points at the second instruction. */
    if ((t & 3u) == 0 && t >= 4) {
        uint32_t prev = nk_r32(c, t - 4);
        uint32_t here = nk_r32(c, t);
        if ((prev & 0x0f7f0000u) == 0x051f0000u &&
            ((prev >> 12) & 0xfu) == 12u &&
            (here & 0x0fffffffu) == 0x059cf000u) {
            *target = t - 4;
            set_thumb(c, 0);
            ip->st.call_fixups++;
            if (ip->call_fixup_log-- > 0)
                fprintf(stderr, "[interp] call: import stub %#010x -> %#010x\n",
                        t, t - 4);
            return 1;
        }
    }

    uint32_t a = t;
    int th = caller_thumb;
    int found = 0;
    const char* how = "snap-back";
    uint32_t win = caller_thumb ? ip->snap_window_thumb : ip->snap_window_arm;

    switch (ip->call_policy) {
    case 1:
        if (arm_at_target(ip, c, t, &a)) { th = 0; found = 1; how = "arm-at-target"; }
        break;
    case 2:
        if (snap_call_entry_fwd(ip, c, t, &a, &th)) { found = 1; how = "snap-fwd"; }
        break;
    case 3:
        if ((t & 3u) == 0 && in_code(ip, t) && arm_entry_at(c, t)) {
            a = t; th = 0; found = 1; how = "direct";
        } else if (snap_call_entry(ip, c, t, win, call_pc, ip->snap_nofast, &a, &th)) {
            found = 1; how = "snap-back";
        } else if (snap_call_entry_fwd(ip, c, t, &a, &th)) {
            found = 1; how = "snap-fwd";
        } else if (arm_at_target(ip, c, t, &a)) {
            th = 0; found = 1; how = "arm-at-target";
        }
        break;
    default:
        found = snap_call_entry(ip, c, t, win, call_pc, ip->snap_nofast, &a, &th);
        break;
    }
    if (!found) {
        /* A direct call to a data address cannot be repaired.  With recovery
         * enabled, skip it as a call that returned 0 instead of letting the
         * interpreter execute ROMFS/rodata until it faults. */
        uint32_t tbit = t & ~1u;
        if (ip->recover && !in_code(ip, tbit)) {
            c->r[0] = 0;
            ip->st.recoveries++;
            if (ip->recover_log-- > 0)
                fprintf(stderr,
                        "[interp] skip: call %#010x -> %#010x is outside every code range\n",
                        call_pc, t);
            return 2;
        }
        return 0;
    }
    if (a != t || th != caller_thumb) {
        *target = a;
        set_thumb(c, th);
        ip->st.call_fixups++;
        if (ip->call_fixup_log-- > 0)
            fprintf(stderr, "[interp] call: %s -> %s %s at %#010x: %#010x -> %#010x\n",
                    caller_thumb ? "Thumb" : "ARM", th ? "Thumb" : "ARM", how,
                    call_pc, t, a);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* ARM                                                                 */
/* ------------------------------------------------------------------ */

static int arm_step(nk_cpu_t* c, nk_interp_t* ip) {
    uint32_t pc = c->r[15];
    uint32_t op = nk_r32(c, pc);
    trace_pc(ip, c, pc, op);
    remember(ip, pc);
    ip->st.insns++;
    ip->st.arm_insns++;
    c->r[15] = pc + 4;

    unsigned cond = op >> 28;
    if (cond == 0xf) {
        if ((op & 0x0f000000u) == 0x0f000000u) {   /* SWI */
            uint32_t imm = op & 0x00ffffffu;
            fprintf(stderr, "[interp] SWI %#x at %#010x (r0=%#x r1=%#x)\n",
                    imm, pc, c->r[0], c->r[1]);
            if (ip->stop_on_swi) { ip->st.stop_reason = NK_STOP_SWI; ip->st.stop_pc = pc; return 1; }
            return 0;
        }
        goto undefined;
    }
    if (!cond_true(c, cond)) return 0;

    /* BX / BLX register */
    if ((op & 0x0ffffff0u) == 0x012fff10u || (op & 0x0ffffff0u) == 0x012fff30u) {
        unsigned rm = op & 0xf;
        uint32_t t = c->r[rm];
        int new_t;
        if ((op & 0x20) != 0) {                    /* BLX */
            c->r[14] = pc + 4;
            push_call(ip, c, pc + 4, pc, t);
        }
        int restored = pop_call(ip, t & ~1u, &new_t);
        set_thumb(c, restored ? new_t : (t & 1));
        c->r[15] = t & ~1u;
        return 0;
    }

    /* MRS / MSR */
    if ((op & 0x0fbf0fffu) == 0x010f0000u) {       /* MRS Rd, CPSR/SPSR */
        unsigned rd = (op >> 12) & 0xf;
        c->r[rd] = c->cpsr;
        return 0;
    }
    if ((op & 0x0fb0fff0u) == 0x0120f000u) {       /* MSR CPSR, Rm */
        unsigned mask = (op >> 16) & 0xf;
        uint32_t v = c->r[op & 0xf];
        if (mask & 8) c->cpsr = (c->cpsr & ~0xff000000u) | (v & 0xff000000u);
        if (mask & 1) c->cpsr = (c->cpsr & ~NK_CPSR_MODE) | (v & NK_CPSR_MODE);
        return 0;
    }
    if ((op & 0x0fb0f000u) == 0x0320f000u) {       /* MSR CPSR, #imm */
        unsigned rot = ((op >> 8) & 0xf) * 2;
        uint32_t v = op & 0xff;
        if (rot) v = (v >> rot) | (v << (32 - rot));
        if (op & (1u << 19)) c->cpsr = (c->cpsr & ~0xff000000u) | (v & 0xff000000u);
        if (op & (1u << 16)) c->cpsr = (c->cpsr & ~NK_CPSR_MODE) | (v & NK_CPSR_MODE);
        return 0;
    }

    unsigned cls = (op >> 26) & 3;

    /* ---- data processing / multiply / swap / halfword (bits 27-26 = 00) */
    if (cls == 0) {
        if ((op & 0x0f800ff0u) == 0x01000090u) {   /* SWP/SWPB */
            unsigned rm = op & 0xf, rd = (op >> 12) & 0xf, rn = (op >> 16) & 0xf;
            uint32_t a = c->r[rn];
            if (op & (1u << 22)) {
                uint8_t v = nk_r8(c, a);
                nk_w8(c, a, (uint8_t)c->r[rm]);
                c->r[rd] = v;
            } else {
                uint32_t v = nk_r32(c, a);
                nk_w32(c, a, c->r[rm]);
                c->r[rd] = v;
            }
            return 0;
        }

        unsigned op4 = (op >> 4) & 0xf;
        if (op4 == 9) {                             /* MUL/MLA/UMULL/... */
            int s = (op >> 20) & 1;
            unsigned rd = (op >> 12) & 0xf;
            unsigned rn = (op >> 16) & 0xf;
            unsigned rs = (op >> 8) & 0xf;
            unsigned rm = op & 0xf;
            if (op & (1u << 22)) {                 /* long multiply */
                int sign = (op & (1u << 21)) != 0;
                uint64_t p;
                if (sign) p = (uint64_t)((int64_t)(int32_t)c->r[rs] * (int64_t)(int32_t)c->r[rm]);
                else      p = (uint64_t)c->r[rs] * (uint64_t)c->r[rm];
                if (op & (1u << 21)) p += ((uint64_t)c->r[rn] << 32) | c->r[rd];
                c->r[rd] = (uint32_t)p;
                c->r[rn] = (uint32_t)(p >> 32);
                if (s) { nk_setf(c, NK_FLAG_N, c->r[rn] >> 31); nk_setf(c, NK_FLAG_Z, p == 0); }
            } else {
                uint32_t p = c->r[rs] * c->r[rm];
                if (op & (1u << 21)) p += c->r[rd]; /* MLA */
                c->r[rd] = p;
                if (s) set_nz(c, p);
            }
            return 0;
        }

        /* Halfword / signed transfer: bits 7-4 = 1xx1, bits 6-5 != 00, and
         * bit 25 = 0.  The bit-25 test is essential: extra load/store uses
         * bit 22 as its immediate flag, so `and rd, rn, #0xff` (bit 25 = 1)
         * has exactly the same bits 7-4 pattern and was decoded as LDRH/STRH
         * before this check existed. */
        if (!(op & (1u << 25)) && (op & 0x90) == 0x90 &&
            (op & 0x60) != 0) {
            unsigned pbit = (op >> 24) & 1, ubit = (op >> 23) & 1;
            unsigned ibit = (op >> 22) & 1, wbit = (op >> 21) & 1;
            unsigned lbit = (op >> 20) & 1;
            unsigned rn = (op >> 16) & 0xf, rd = (op >> 12) & 0xf;
            unsigned sh = (op >> 5) & 3;           /* 1=H, 2=SB, 3=SH */
            uint32_t off;
            if (ibit) off = ((op >> 4) & 0xf0) | (op & 0xf);
            else     off = c->r[op & 0xf];
            uint32_t base = (rn == 15) ? pc + 8 : c->r[rn];
            uint32_t addr = pbit ? (ubit ? base + off : base - off) : base;
            if (lbit) {
                if (sh == 1)      c->r[rd] = nk_r16(c, addr & ~1u);
                else if (sh == 2) c->r[rd] = (uint32_t)(int32_t)(int8_t)nk_r8(c, addr);
                else              c->r[rd] = (uint32_t)(int32_t)(int16_t)nk_r16(c, addr & ~1u);
            } else {
                nk_w16(c, addr & ~1u, (uint16_t)c->r[rd]);
            }
            if (!pbit || wbit) c->r[rn] = ubit ? base + off : base - off;
            return 0;
        }

        /* Data processing. */
        unsigned opc = (op >> 21) & 0xf;
        int s = (op >> 20) & 1;
        unsigned rn = (op >> 16) & 0xf, rd = (op >> 12) & 0xf;
        uint32_t carry = c->cpsr & (1u << NK_FLAG_C);
        uint32_t b = arm_op2(c, op, pc, &carry);
        uint32_t a = rp_arm(c, rn, pc);
        uint32_t r = 0;
        int write = 1;
        switch (opc) {
        case 0x0: r = a & b; if (s) { set_nz(c, r); nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C); } break;
        case 0x1: r = a ^ b; if (s) { set_nz(c, r); nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C); } break;
        case 0x2: r = sub_flags(c, a, b, 0); break;
        case 0x3: r = sub_flags(c, b, a, 0); break;
        case 0x4: r = add_flags(c, a, b, 0); break;
        case 0x5: r = add_flags(c, a, b, nk_cf(c)); break;
        case 0x6: r = sub_flags(c, a, b, 1 - nk_cf(c)); break;
        case 0x7: r = sub_flags(c, b, a, 1 - nk_cf(c)); break;
        case 0x8: set_nz(c, a & b); write = 0; break;
        case 0x9: set_nz(c, a ^ b); write = 0; break;
        case 0xa: (void)sub_flags(c, a, b, 0); write = 0; break;
        case 0xb: (void)add_flags(c, a, b, 0); write = 0; break;
        case 0xc: r = a | b; if (s) { set_nz(c, r); nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C); } break;
        case 0xd: r = b;     if (s) { set_nz(c, r); nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C); } break;
        case 0xe: r = a & ~b; if (s) { set_nz(c, r); nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C); } break;
        case 0xf: r = ~b;    if (s) { set_nz(c, r); nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C); } break;
        }
        if (write) {
            if (rd == 15) {
                int new_t;
                int restored = pop_call(ip, r & ~1u, &new_t);
                set_thumb(c, restored ? new_t : 0);
                c->r[15] = r & ~1u;
            } else c->r[rd] = r;
        }
        return 0;
    }

    /* ---- single data transfer (bits 27-26 = 01) ---- */
    if (cls == 1) {
        unsigned pbit = (op >> 24) & 1, ubit = (op >> 23) & 1;
        unsigned bbit = (op >> 22) & 1, wbit = (op >> 21) & 1;
        unsigned lbit = (op >> 20) & 1;
        unsigned rn = (op >> 16) & 0xf, rd = (op >> 12) & 0xf;
        uint32_t off;
        if (op & (1u << 25)) {
            uint32_t carry = 0;
            off = arm_op2(c, op & 0xfffu, pc, &carry);
        } else off = op & 0xfffu;
        /* ARM PC reads as instruction+8 for single data transfers.  c->r[15]
         * has already been advanced to pc+4 above, so don't use it directly. */
        uint32_t base = (rn == 15) ? pc + 8 : c->r[rn];
        uint32_t addr = pbit ? (ubit ? base + off : base - off) : base;
        if (lbit) {
            uint32_t v = bbit ? nk_r8(c, addr) : nk_r32(c, addr & ~3u);
            if (rd == 15) {
                /* `ldr pc, [ip]` is the EKA1 import stub.  In the packed
                 * pre-link image the IAT slot is still empty (ROM build binds
                 * it).  Report it instead of silently jumping to address 0.
                 * Restrict this to the ip register: a small value loaded from
                 * an arbitrary vtable slot (e.g. `ldr pc,[r3,#0x14]`) is a
                 * missing object, not an import. */
                if (v < 0x1000u && rn == 12 && off == 0) {
                    ip->st.iat_hits++;
                    if (ip->iat_log-- > 0)
                        fprintf(stderr, "[interp] unbound IAT slot %#010x at %#010x (caller lr=%#010x)\n",
                                addr, pc, c->r[14]);
                    if (ip->iat_fake_return) {
                        int new_t = 0;
                        (void)pop_call(ip, c->r[14] & ~1u, &new_t);
                        c->r[0] = 0;
                        set_thumb(c, new_t ? 1 : 0);
                        c->r[15] = c->r[14] & ~1u;
                        return 0;
                    }
                    ip->st.stop_reason = NK_STOP_IAT;
                    ip->st.stop_pc = pc;
                    return 1;
                }
                int new_t;
                int restored = pop_call(ip, v & ~1u, &new_t);
                set_thumb(c, restored ? new_t : (v & 1));
                c->r[15] = v & ~1u;
            } else c->r[rd] = v;
        } else {
            if (bbit) nk_w8(c, addr, (uint8_t)c->r[rd]);
            else nk_w32(c, addr & ~3u, c->r[rd]);
        }
        if (!pbit || wbit) c->r[rn] = ubit ? base + off : base - off;
        return 0;
    }

    /* ---- block transfer / branch (bits 27-26 = 10) ---- */
    if (cls == 2) {
        if (op & (1u << 25)) {                     /* B / BL */
            int32_t off = (int32_t)(op & 0x00ffffffu);
            if (off & 0x00800000) off |= (int32_t)0xff000000;
            uint32_t target = pc + 8 + ((uint32_t)off << 2);
            if (op & (1u << 24)) {
                c->r[14] = pc + 4;
                push_call(ip, c, pc + 4, pc, target);
                uint32_t raw = target;
                if (infer_call(ip, c, 0, pc, &target) == 2) {
                    record_call(ip, c, pc, raw, target, 0);
                    drop_call(ip);
                    c->r[15] = pc + 4;
                    return 0;
                }
                record_call(ip, c, pc, raw, target, 0);
            }
            c->r[15] = target;
            return 0;
        }
        unsigned pbit = (op >> 24) & 1, ubit = (op >> 23) & 1;
        unsigned wbit = (op >> 21) & 1, lbit = (op >> 20) & 1;
        unsigned rn = (op >> 16) & 0xf;
        uint32_t list = op & 0xffffu;
        unsigned n = 0;
        for (unsigned i = 0; i < 16; i++) if (list & (1u << i)) n++;
        if (!n) return 0;
        uint32_t base = c->r[rn];
        uint32_t start = ubit ? (pbit ? base + 4 : base)
                              : (pbit ? base - 4 * n : base - 4 * n + 4);
        uint32_t addr = start;
        int pc_loaded = 0; uint32_t pc_val = 0;
        for (unsigned i = 0; i < 16; i++) {
            if (!(list & (1u << i))) continue;
            if (lbit) {
                uint32_t v = nk_r32(c, addr);
                if (i == 15) { pc_loaded = 1; pc_val = v; }
                else c->r[i] = v;
            } else nk_w32(c, addr, c->r[i]);
            addr += 4;
        }
        if (wbit) c->r[rn] = ubit ? base + 4 * n : base - 4 * n;
        if (lbit && pc_loaded) {
            int new_t;
            int restored = pop_call(ip, pc_val & ~1u, &new_t);
            set_thumb(c, restored ? new_t : (pc_val & 1));
            c->r[15] = pc_val & ~1u;
        }
        return 0;
    }

    /* ---- coprocessor / CP15 / SWI (bits 27-26 = 11) ---- */
    if (cls == 3) {
        if (((op >> 8) & 0xf) == 0xf && (op & 0x0e000000u) == 0x0e000000u) {
            fprintf(stderr, "[interp] CP15 %s c%d at %#010x\n",
                    (op & (1u << 20)) ? "MRC" : "MCR", (op >> 16) & 0xf, pc);
            return 0;
        }
        /* SWI with cond != 1111 (rare but legal). */
        if ((op & 0x0f000000u) == 0x0f000000u) {
            fprintf(stderr, "[interp] SWI %#x at %#010x\n", op & 0xffffff, pc);
            return 0;
        }
        goto undefined;
    }

undefined:
    ip->st.undefined++;
    ip->st.stop_reason = NK_STOP_UNDEFINED;
    ip->st.stop_pc = pc;
    fprintf(stderr, "[interp] undefined ARM %08x at %#010x\n", op, pc);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Thumb                                                               */
/* ------------------------------------------------------------------ */

static int thumb_step(nk_cpu_t* c, nk_interp_t* ip) {
    uint32_t pc = c->r[15];
    uint16_t h = nk_r16(c, pc);
    trace_pc(ip, c, pc, h);
    remember(ip, pc);
    ip->st.insns++;
    ip->st.thumb_insns++;
    c->r[15] = pc + 2;

    /* 000xx: shift by immediate (00000-00101 low group) / add-sub */
    if ((h & 0xe000) == 0x0000) {
        if ((h & 0x1800) == 0x1800) {              /* 00011: add/sub rd, rs, #imm3/Rn */
            unsigned i = (h >> 10) & 1, sub = (h >> 9) & 1;
            unsigned opn = (h >> 6) & 7;
            unsigned rs = (h >> 3) & 7, rd = h & 7;
            /* bit 10 = 1 selects the 3-bit immediate; 0 selects register Rn. */
            uint32_t a = c->r[rs], b = i ? opn : c->r[opn];
            c->r[rd] = sub ? sub_flags(c, a, b, 0) : add_flags(c, a, b, 0);
            return 0;
        }
        unsigned type = (h >> 11) & 3;             /* 0 LSL, 1 LSR, 2 ASR */
        unsigned amt = (h >> 6) & 0x1f;
        unsigned rs = (h >> 3) & 7, rd = h & 7;
        if (type == 3) { c->r[15] = pc + 2; goto undef; }
        if (type != 0 && amt == 0) amt = 32;
        uint32_t carry = c->cpsr & (1u << NK_FLAG_C);
        uint32_t r = shift_val(c->r[rs], type, amt, &carry);
        c->r[rd] = r;
        set_nz(c, r);
        nk_setf(c, NK_FLAG_C, carry >> NK_FLAG_C);
        return 0;
    }

    /* 001xx: MOV/CMP/ADD/SUB Rd, #imm8 */
    if ((h & 0xe000) == 0x2000) {
        unsigned opc = (h >> 11) & 3;
        unsigned rd = (h >> 8) & 7;
        uint32_t imm = h & 0xff;
        switch (opc) {
        case 0: c->r[rd] = imm; set_nz(c, imm); break;
        case 1: (void)sub_flags(c, c->r[rd], imm, 0); break;
        case 2: c->r[rd] = add_flags(c, c->r[rd], imm, 0); break;
        case 3: c->r[rd] = sub_flags(c, c->r[rd], imm, 0); break;
        }
        return 0;
    }

    /* 010000: ALU Rd, Rs */
    if ((h & 0xfc00) == 0x4000) {
        unsigned opc = (h >> 6) & 0xf;
        unsigned rs = (h >> 3) & 7, rd = h & 7;
        uint32_t a = c->r[rd], b = c->r[rs], r = 0;
        switch (opc) {
        case 0x0: r = a & b; c->r[rd] = r; set_nz(c, r); break;
        case 0x1: r = a ^ b; c->r[rd] = r; set_nz(c, r); break;
        case 0x2: { uint32_t cy = c->cpsr & (1u << NK_FLAG_C); r = shift_val(a, 0, b & 0xff, &cy); c->r[rd] = r; set_nz(c, r); nk_setf(c, NK_FLAG_C, cy >> NK_FLAG_C); break; }
        case 0x3: { uint32_t cy = c->cpsr & (1u << NK_FLAG_C); r = shift_val(a, 1, b & 0xff, &cy); c->r[rd] = r; set_nz(c, r); nk_setf(c, NK_FLAG_C, cy >> NK_FLAG_C); break; }
        case 0x4: { uint32_t cy = c->cpsr & (1u << NK_FLAG_C); r = shift_val(a, 2, b & 0xff, &cy); c->r[rd] = r; set_nz(c, r); nk_setf(c, NK_FLAG_C, cy >> NK_FLAG_C); break; }
        case 0x5: c->r[rd] = add_flags(c, a, b, nk_cf(c)); break;
        case 0x6: c->r[rd] = sub_flags(c, a, b, 1 - nk_cf(c)); break;
        case 0x7: { uint32_t cy = c->cpsr & (1u << NK_FLAG_C); r = shift_val(a, 3, b & 0xff, &cy); c->r[rd] = r; set_nz(c, r); nk_setf(c, NK_FLAG_C, cy >> NK_FLAG_C); break; }
        case 0x8: set_nz(c, a & b); break;
        case 0x9: c->r[rd] = sub_flags(c, 0, b, 0); break;
        case 0xa: (void)sub_flags(c, a, b, 0); break;
        case 0xb: (void)add_flags(c, a, b, 0); break;
        case 0xc: r = a | b; c->r[rd] = r; set_nz(c, r); break;
        case 0xd: r = a * b; c->r[rd] = r; set_nz(c, r); break;
        case 0xe: r = a & ~b; c->r[rd] = r; set_nz(c, r); break;
        case 0xf: r = ~b; c->r[rd] = r; set_nz(c, r); break;
        }
        return 0;
    }

    /* 010001: high-register ops / BX / BLX */
    if ((h & 0xfc00) == 0x4400) {
        unsigned opc = (h >> 8) & 3;
        if (opc == 3) {
            unsigned rm = (h >> 3) & 0xf;
            uint32_t t = c->r[rm];
            if (h & 0x0080) {                      /* BLX register */
                c->r[14] = (pc + 2) | 1;
                push_call(ip, c, pc + 2, pc, t);
            }
            int new_t;
            int restored = pop_call(ip, t & ~1u, &new_t);
            set_thumb(c, restored ? new_t : (t & 1));
            c->r[15] = t & ~1u;
            return 0;
        }
        unsigned rd = (h & 7) | ((h >> 4) & 8);
        unsigned rm = (h >> 3) & 0xf;
        uint32_t b = (rm == 15) ? pc + 4 : c->r[rm];
        switch (opc) {
        case 0: {
            uint32_t r = c->r[rd] + b;
            if (rd == 15) {
                int new_t;
                int restored = pop_call(ip, r & ~1u, &new_t);
                set_thumb(c, restored ? new_t : (r & 1));
                c->r[15] = r & ~1u;
            } else c->r[rd] = r;
            break;
        }
        case 1: (void)sub_flags(c, c->r[rd], b, 0); break;
        case 2:
            if (rd == 15) {
                int new_t;
                int restored = pop_call(ip, b & ~1u, &new_t);
                set_thumb(c, restored ? new_t : (b & 1));
                c->r[15] = b & ~1u;
            } else c->r[rd] = b;
            break;
        }
        return 0;
    }

    /* 01001: LDR Rd, [PC, #imm8*4] */
    if ((h & 0xf800) == 0x4800) {
        unsigned rd = (h >> 8) & 7;
        uint32_t addr = ((pc + 4) & ~3u) + ((h & 0xff) << 2);
        c->r[rd] = nk_r32(c, addr);
        return 0;
    }

    /* 0101: load/store register offset */
    if ((h & 0xf000) == 0x5000) {
        unsigned rb = (h >> 3) & 7, rd = h & 7, ro = (h >> 6) & 7;
        uint32_t addr = c->r[rb] + c->r[ro];
        switch (h & 0xf200) {
        case 0x0000: nk_w32(c, addr & ~3u, c->r[rd]); break;
        case 0x0800: c->r[rd] = nk_r32(c, addr & ~3u); break;
        case 0x0200: nk_w16(c, addr & ~1u, (uint16_t)c->r[rd]); break;
        case 0x0a00: c->r[rd] = nk_r16(c, addr & ~1u); break;
        case 0x0400: nk_w8(c, addr, (uint8_t)c->r[rd]); break;
        case 0x0c00: c->r[rd] = nk_r8(c, addr); break;
        case 0x0600: c->r[rd] = (uint32_t)(int32_t)(int8_t)nk_r8(c, addr); break;
        case 0x0e00: c->r[rd] = (uint32_t)(int32_t)(int16_t)nk_r16(c, addr & ~1u); break;
        }
        return 0;
    }

    /* 0110: word immediate; 0111: byte immediate; 1000: halfword immediate */
    if ((h & 0xe000) == 0x6000) {
        unsigned byte = (h >> 12) & 1;
        unsigned load = (h >> 11) & 1;
        unsigned imm5 = (h >> 6) & 0x1f;
        unsigned rb = (h >> 3) & 7, rd = h & 7;
        if (byte) {
            uint32_t addr = c->r[rb] + imm5;
            if (load) c->r[rd] = nk_r8(c, addr);
            else nk_w8(c, addr, (uint8_t)c->r[rd]);
        } else {
            uint32_t addr = c->r[rb] + (imm5 << 2);
            if (load) c->r[rd] = nk_r32(c, addr & ~3u);
            else nk_w32(c, addr & ~3u, c->r[rd]);
        }
        return 0;
    }
    if ((h & 0xf000) == 0x8000) {
        unsigned load = (h >> 11) & 1;
        unsigned imm5 = (h >> 6) & 0x1f;
        unsigned rb = (h >> 3) & 7, rd = h & 7;
        uint32_t addr = c->r[rb] + (imm5 << 1);
        if (load) c->r[rd] = nk_r16(c, addr & ~1u);
        else nk_w16(c, addr & ~1u, (uint16_t)c->r[rd]);
        return 0;
    }

    /* 1001: SP-relative load/store */
    if ((h & 0xf000) == 0x9000) {
        unsigned load = (h >> 11) & 1, rd = (h >> 8) & 7;
        uint32_t addr = c->r[13] + ((h & 0xff) << 2);
        if (load) c->r[rd] = nk_r32(c, addr & ~3u);
        else nk_w32(c, addr & ~3u, c->r[rd]);
        return 0;
    }

    /* 1010: ADD Rd, PC/SP, #imm */
    if ((h & 0xf000) == 0xa000) {
        unsigned sp = (h >> 11) & 1, rd = (h >> 8) & 7;
        uint32_t base = sp ? c->r[13] : ((pc + 4) & ~3u);
        c->r[rd] = base + ((h & 0xff) << 2);
        return 0;
    }

    /* 1011: add/sub SP, push/pop */
    if ((h & 0xf000) == 0xb000) {
        if ((h & 0xff00) == 0xb000) {
            uint32_t imm = (h & 0x7f) << 2;
            if (h & 0x80) c->r[13] -= imm; else c->r[13] += imm;
            return 0;
        }
        unsigned pop = (h >> 11) & 1;
        unsigned extra = (h >> 8) & 1;             /* LR for push, PC for pop */
        unsigned list = h & 0xff;
        unsigned n = 0;
        for (unsigned i = 0; i < 8; i++) if (list & (1u << i)) n++;
        if (extra) n++;
        if (!pop) {
            c->r[13] -= 4 * n;
            uint32_t addr = c->r[13];
            for (unsigned i = 0; i < 8; i++)
                if (list & (1u << i)) { nk_w32(c, addr, c->r[i]); addr += 4; }
            if (extra) nk_w32(c, addr, c->r[14]);
        } else {
            uint32_t addr = c->r[13];
            for (unsigned i = 0; i < 8; i++)
                if (list & (1u << i)) { c->r[i] = nk_r32(c, addr); addr += 4; }
            if (extra) {
                uint32_t t = nk_r32(c, addr);
                c->r[13] = addr + 4;
                int new_t;
                int restored = pop_call(ip, t & ~1u, &new_t);
                set_thumb(c, restored ? new_t : (t & 1));
                c->r[15] = t & ~1u;
                return 0;
            }
            c->r[13] = addr;
        }
        return 0;
    }

    /* 1100: LDMIA/STMIA */
    if ((h & 0xf000) == 0xc000) {
        unsigned load = (h >> 11) & 1, rb = (h >> 8) & 7;
        unsigned list = h & 0xff;
        uint32_t addr = c->r[rb];
        for (unsigned i = 0; i < 8; i++) {
            if (!(list & (1u << i))) continue;
            if (load) c->r[i] = nk_r32(c, addr);
            else nk_w32(c, addr, c->r[i]);
            addr += 4;
        }
        if (!load && !(list & (1u << rb))) c->r[rb] = addr;
        return 0;
    }

    /* 1101: conditional branch / SWI */
    if ((h & 0xf000) == 0xd000) {
        unsigned cc = (h >> 8) & 0xf;
        if (cc == 0xf) {                           /* SWI */
            fprintf(stderr, "[interp] SWI %u at %#010x (r0=%#x r1=%#x)\n",
                    h & 0xff, pc, c->r[0], c->r[1]);
            if (ip->stop_on_swi) { ip->st.stop_reason = NK_STOP_SWI; ip->st.stop_pc = pc; return 1; }
            return 0;
        }
        if (cc == 0xe) {                           /* B */
            int32_t off = (int32_t)(h & 0x7ff);
            if (off & 0x400) off |= (int32_t)0xfffff800;
            c->r[15] = pc + 4 + ((uint32_t)off << 1);
            return 0;
        }
        if (cond_true(c, cc)) {
            int32_t off = (int32_t)(h & 0xff);
            if (off & 0x80) off |= (int32_t)0xffffff00;
            c->r[15] = pc + 4 + ((uint32_t)off << 1);
        }
        return 0;
    }

    /* 11100: unconditional B */
    if ((h & 0xf800) == 0xe000) {
        int32_t off = (int32_t)(h & 0x7ff);
        if (off & 0x400) off |= (int32_t)0xfffff800;
        c->r[15] = pc + 4 + ((uint32_t)off << 1);
        return 0;
    }

    /* 1111x: BL / BLX */
    if ((h & 0xf800) == 0xf000) {
        uint16_t h2 = nk_r16(c, pc + 2);
        uint32_t s = (h >> 10) & 1;
        uint32_t j1 = (h2 >> 13) & 1, j2 = (h2 >> 11) & 1;
        uint32_t i1 = (~(j1 ^ s)) & 1, i2 = (~(j2 ^ s)) & 1;
        int32_t off = (int32_t)((s << 24) | (i1 << 23) | (i2 << 22) |
                                ((uint32_t)(h & 0x3ff) << 12) |
                                ((uint32_t)(h2 & 0x7ff) << 1));
        if (off & 0x01000000) off |= (int32_t)0xfe000000;
        int blx = (h2 & 0xf800) == 0xe800;
        uint32_t base = blx ? ((pc + 4) & ~3u) : (pc + 4);
        uint32_t target = base + (uint32_t)off;
        /* Thumb BL is a 4-byte instruction: the return address is pc+4
         * (with the Thumb bit set), not pc+2.  pc+2 only applies to the
         * 2-byte BLX register form handled above. */
        c->r[14] = (pc + 4) | 1;
        push_call(ip, c, pc + 4, pc, target);
        uint32_t raw = target;
        if (blx) {                                 /* BLX (ARMv5) */
            set_thumb(c, 0);
            c->r[15] = target & ~3u;
            record_call(ip, c, pc, raw, target & ~3u, 1);
        } else {
            if (infer_call(ip, c, 1, pc, &target) == 2) {
                record_call(ip, c, pc, raw, target, 1);
                drop_call(ip);
                c->r[15] = pc + 4;
                return 0;
            }
            c->r[15] = target;
            record_call(ip, c, pc, raw, target, 1);
        }
        return 0;
    }

undef:
    ip->st.undefined++;
    ip->st.stop_reason = NK_STOP_UNDEFINED;
    ip->st.stop_pc = pc;
    fprintf(stderr, "[interp] undefined Thumb %04x at %#010x\n", h, pc);
    return 1;
}

/* ------------------------------------------------------------------ */
/* driver                                                              */
/* ------------------------------------------------------------------ */

void nk_interp_init(nk_interp_t* ip) {
    memset(ip, 0, sizeof *ip);
    ip->budget = 10000000;
    ip->trace_limit = 0;
    ip->infer_mode = 1;
    ip->snap_window = 0x40;
    ip->snap_window_thumb = 0x40;
    ip->snap_window_arm = 0x40;
    ip->snap_nofast = 0;
    ip->recover = 0;
    ip->recover_max = 256;
    ip->recover_log = 16;
    ip->watch_hits = 1;
    ip->watch_log = 16;
    ip->require_code = 0;      /* selftests execute tiny snippets in RAM */
}

/* The 6600 executes code from ROM (0x50000000), the pre-MMU low alias
 * (0x00000000, first 3 MiB) and the high vectors (0xffff0000).  RAM at
 * 0x80000000 holds data and stacks only; a PC there after a bad return is
 * data being executed as code.  The dispatcher uses this to turn that into
 * a recovery instead of spending millions of instructions in the heap. */
static int pc_in_code_space(uint32_t pc, int allow_low_alias) {
    pc &= ~1u;
    return (pc >= 0x50000000u && pc < 0x51000000u) ||
           (allow_low_alias && pc < 0x00300000u) ||
           (pc >= 0xffff0000u && pc < 0xffff1000u);
}

int nk_interp_run(nk_cpu_t* c, nk_interp_t* ip) {
    if (ip->budget <= 0) ip->budget = 10000000;
    while (ip->budget-- > 0) {
        if (ip->watch_pc && ip->watch_hits != 0 &&
            (c->r[15] & ~1u) == (ip->watch_pc & ~1u)) {
            fprintf(stderr,
                    "[watch] pc=%#010x thumb=%d r0=%#x r1=%#x r2=%#x r3=%#x "
                    "sp=%#x lr=%#x cpsr=%#x\n",
                    c->r[15], thumb(c), c->r[0], c->r[1], c->r[2], c->r[3],
                    c->r[13], c->r[14], c->cpsr);
            dump_call_ring(ip, ip->watch_log);
            if (ip->watch_hits > 0) ip->watch_hits--;
        }
        if (spin_tick(ip, c->r[15])) {
            if (recover_call(ip, c, NK_STOP_SPIN)) continue;
            ip->st.stop_reason = NK_STOP_SPIN;
            ip->st.stop_pc = c->r[15];
            break;
        }
        if (ip->return_pc &&
            (c->r[15] & ~1u) == (ip->return_pc & ~1u)) {
            ip->st.stop_reason = NK_STOP_RETURN;
            ip->st.stop_pc = c->r[15];
            set_thumb(c, ip->return_thumb);
            return 1;
        }
        /* The 6600 maps ROM at 0x50000000, RAM at 0x80000000 and high
         * vectors at 0xffff0000.  A PC below 1 GiB normally means a corrupted
         * return/frame; the exception is the pre-MMU low alias
         * (0x00000000..0x002fffff), where the mask ROM executes the boot
         * bank.  Keep the guard for every other low address. */
        if (c->r[15] < 0x40000000u &&
            !pc_in_code_space(c->r[15], ip->allow_low_alias)) {
            ip->st.stop_reason = NK_STOP_OUT_OF_IMAGE;
            ip->st.stop_pc = c->r[15];
            if (recover_call(ip, c, NK_STOP_OUT_OF_IMAGE)) continue;
            return 1;
        }
        if (ip->require_code &&
            !pc_in_code_space(c->r[15], ip->allow_low_alias)) {
            ip->st.stop_reason = NK_STOP_OUT_OF_IMAGE;
            ip->st.stop_pc = c->r[15];
            if (recover_call(ip, c, NK_STOP_OUT_OF_IMAGE)) continue;
            return 1;
        }
        int was_thumb = thumb(c);
        int r = was_thumb ? thumb_step(c, ip) : arm_step(c, ip);
        if (r) {
            if (ip->infer_mode && ip->st.stop_reason == NK_STOP_UNDEFINED) {
                uint32_t pc = ip->st.stop_pc;
                c->r[15] = pc;
                if (was_thumb) {
                    if ((pc & 3) == 0) {
                        uint32_t op = nk_r32(c, pc);
                        if (arm_ok(op)) {
                            set_thumb(c, 0);
                            ip->st.mode_switches++;
                            ip->st.stop_reason = 0;
                            ip->st.undefined--;
                            fprintf(stderr, "[interp] infer: Thumb -> ARM at %#010x\n", pc);
                            continue;
                        }
                    } else if (ip->infer_mode >= 2 && (pc & 3) == 2) {
                        /* No veneer at all: the Thumb stream ran one 2-byte
                         * instruction into what is really an ARM instruction.
                         * Rewind to the halfword boundary and re-execute as ARM. */
                        uint32_t a = pc - 2;
                        uint32_t op = nk_r32(c, a);
                        if (arm_ok(op)) {
                            set_thumb(c, 0);
                            c->r[15] = a;
                            ip->st.mode_switches++;
                            ip->st.stop_reason = 0;
                            ip->st.undefined--;
                            fprintf(stderr, "[interp] infer: rewind Thumb -> ARM at %#010x\n", a);
                            continue;
                        }
                    }
                } else {
                    if ((pc & 1) == 0 && thumb_ok(nk_r16(c, pc))) {
                        set_thumb(c, 1);
                        ip->st.mode_switches++;
                        ip->st.stop_reason = 0;
                        ip->st.undefined--;
                        fprintf(stderr, "[interp] infer: ARM -> Thumb at %#010x\n", pc);
                        continue;
                    }
                }
            }
            if (ip->recover && ip->st.stop_reason != NK_STOP_RETURN &&
                recover_call(ip, c, ip->st.stop_reason))
                continue;
            break;
        }
    }
    if (ip->budget < 0) ip->budget = 0;
    if (ip->st.stop_reason == 0) {
        ip->st.stop_reason = NK_STOP_BUDGET;
        ip->st.stop_pc = c->r[15];
    }
    return ip->st.stop_reason != NK_STOP_BUDGET;
}

int nk_interp_call(nk_cpu_t* c, uint32_t target) {
    nk_interp_t ip;
    nk_interp_init(&ip);
    ip.budget = 2000000;
    ip.return_pc = c->r[14];
    ip.return_thumb = (uint8_t)thumb(c);
    set_thumb(c, target & 1);
    c->r[15] = target & ~1u;
    return nk_interp_run(c, &ip);
}

const char* nk_interp_stop_name(int reason) {
    switch (reason) {
    case NK_STOP_BUDGET:    return "budget";
    case NK_STOP_UNDEFINED: return "undefined instruction";
    case NK_STOP_RETURN:    return "returned";
    case NK_STOP_SWI:       return "swi";
    case NK_STOP_IAT:       return "unbound import (IAT)";
    case NK_STOP_OUT_OF_IMAGE: return "pc left the image";
    case NK_STOP_SPIN:      return "spin loop";
    default:                return "host";
    }
}

const char* nk_interp_reason(const nk_interp_t* ip) {
    return nk_interp_stop_name(ip->st.stop_reason);
}

void nk_poke(nk_cpu_t* c, uint32_t addr, const void* src, uint32_t len) {
    const uint8_t* p = (const uint8_t*)src;
    for (uint32_t i = 0; i < len; i++) nk_w8(c, addr + i, p[i]);
}
