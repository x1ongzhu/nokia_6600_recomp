/*
 * interp_selftest — hand-encoded ARMv4T instructions through the interpreter.
 *
 * No firmware and no lifter: this isolates the CPU core (ARM and Thumb decode,
 * flags, branches, push/pop, multiply) so a regression is obvious.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nokia_rt.h"
#include "nokia_interp.h"

#define TRAP 0x90000000u

/* The low-alias test opts in; every other test keeps the normal guard. */
static int g_allow_low_alias;

static int run(nk_cpu_t* c, uint32_t pc, int thumb) {
    c->r[13] = 0x80010000u;
    c->r[14] = TRAP;
    c->cpsr = 0x400000d3u | (thumb ? NK_CPSR_T : 0);
    c->r[15] = pc;
    nk_interp_t ip;
    nk_interp_init(&ip);
    ip.return_pc = TRAP;
    ip.return_thumb = (uint8_t)thumb;
    ip.budget = 64;
    ip.allow_low_alias = g_allow_low_alias;
    ip.stop_selfb = 1;
    nk_interp_run(c, &ip);
    return ip.st.stop_reason;
}

static void poke32(nk_cpu_t* c, uint32_t a, uint32_t w) { nk_w32(c, a, w); }

/* Same as run(), for tests that need a longer straight-line budget. */
static int run_budget(nk_cpu_t* c, uint32_t pc, int thumb, long budget) {
    c->r[13] = 0x80010000u;
    c->r[14] = TRAP;
    c->cpsr = 0x400000d3u | (thumb ? NK_CPSR_T : 0);
    c->r[15] = pc;
    nk_interp_t ip;
    nk_interp_init(&ip);
    ip.return_pc = TRAP;
    ip.return_thumb = (uint8_t)thumb;
    ip.budget = budget;
    ip.allow_low_alias = g_allow_low_alias;
    ip.stop_selfb = 1;
    nk_interp_run(c, &ip);
    return ip.st.stop_reason;
}
static void poke16(nk_cpu_t* c, uint32_t a, uint16_t h) { nk_w16(c, a, h); }

/* Run with crash recovery enabled; returns the stop reason and the number of
 * calls that were rolled back. */
static int run_recover(nk_cpu_t* c, uint32_t pc, int thumb,
                       unsigned long* recoveries) {
    c->r[13] = 0x80010000u;
    c->r[14] = TRAP;
    c->cpsr = 0x400000d3u | (thumb ? NK_CPSR_T : 0);
    c->r[15] = pc;
    nk_interp_t ip;
    nk_interp_init(&ip);
    ip.return_pc = TRAP;
    ip.return_thumb = (uint8_t)thumb;
    ip.budget = 100;
    ip.infer_mode = 0;   /* isolate recovery from mode inference */
    ip.recover = 1;
    ip.recover_max = 4;
    ip.recover_log = 0;
    nk_interp_run(c, &ip);
    *recoveries = ip.st.recoveries;
    return ip.st.stop_reason;
}

/* Run with call repair + recovery and an explicit code range; returns the stop
 * reason and the final r0. */
static int run_range(nk_cpu_t* c, uint32_t pc, int thumb, uint32_t lo,
                     uint32_t hi, uint32_t* r0) {
    c->r[13] = 0x80010000u;
    c->r[14] = TRAP;
    c->cpsr = 0x400000d3u | (thumb ? NK_CPSR_T : 0);
    c->r[15] = pc;
    nk_interp_t ip;
    nk_interp_init(&ip);
    ip.return_pc = TRAP;
    ip.return_thumb = (uint8_t)thumb;
    ip.budget = 64;
    ip.infer_mode = 0;
    ip.infer_calls = 1;
    ip.recover = 1;
    ip.recover_log = 0;
    ip.call_fixup_log = 0;
    nk_code_range_add(&ip, lo, hi);
    nk_interp_run(c, &ip);
    *r0 = c->r[0];
    return ip.st.stop_reason;
}

int main(void) {
    nk_cpu_t c;
    memset(&c, 0, sizeof c);
    if (nk_mem_init(&c) != 0) return 1;
    if (nk_alloc_ram(&c, 0x80000000u, 0x20000) != 0) return 1;

    int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } \
                              else printf("ok: %s\n", msg); } while (0)

    /* ---- ARM: mov/add/cmp/conditional move/bx ---- */
    poke32(&c, 0x80000000u, 0xe3a00001u);   /* mov  r0, #1        */
    poke32(&c, 0x80000004u, 0xe2801002u);   /* add  r1, r0, #2    */
    poke32(&c, 0x80000008u, 0xe3510003u);   /* cmp  r1, #3        */
    poke32(&c, 0x8000000cu, 0x03a02001u);   /* moveq r2, #1       */
    poke32(&c, 0x80000010u, 0xe12fff1eu);   /* bx   lr            */
    memset(&c.r, 0, sizeof c.r);
    int r = run(&c, 0x80000000u, 0);
    CHECK(r == NK_STOP_RETURN, "ARM returns through bx lr");
    CHECK(c.r[1] == 3, "ARM add immediate");
    CHECK(c.r[2] == 1, "ARM conditional move (eq)");

    /* ---- ARM: data-processing immediates are not extra loads/stores ----
     * `and rd, rn, #0xff` sets bit 25 (the data-processing immediate flag)
     * and has bits 7-4 = 1111, the same nibble pattern the halfword/signed
     * transfer decoder looks for.  The extra-load/store space requires
     * bit 25 = 0; without that check the mask becomes a bogus LDRH and
     * silently corrupts every "& 0xff" in the boot bank. */
    poke32(&c, 0x80000040u, 0xe3a000ffu);   /* mov  r0, #0xff      */
    poke32(&c, 0x80000044u, 0xe20010f0u);   /* and  r1, r0, #0xf0  */
    poke32(&c, 0x80000048u, 0xe380200fu);   /* orr  r2, r0, #0x0f  */
    poke32(&c, 0x8000004cu, 0xe1d430b0u);   /* ldrh r3, [r4]       */
    poke32(&c, 0x80000050u, 0xe12fff1eu);   /* bx   lr             */
    poke16(&c, 0x80000200u, 0x1234);        /* halfword operand    */
    memset(&c.r, 0, sizeof c.r);
    c.r[4] = 0x80000200u;
    r = run(&c, 0x80000040u, 0);
    CHECK(r == NK_STOP_RETURN && c.r[1] == 0xf0 && c.r[2] == 0xff &&
          c.r[3] == 0x1234,
          "ARM and/orr immediate vs extra load/store");

    /* ---- ARM: `sub sp, sp, #0x258` is not a MUL ----
     * The multiply decoder matched any instruction with bits 7-4 = 1001.
     * `sub sp, sp, #0x258` (0xe24ddf96) has that nibble pattern, so it was
     * executed as a bogus MUL and zeroed SP; the kernel then wrote its
     * stacks through address 0.  Multiply/MLA additionally require bits
     * 27-22 = 000000. */
    poke32(&c, 0x80000060u, 0xe24ddf96u);   /* sub sp, sp, #0x258  */
    poke32(&c, 0x80000064u, 0xe12fff1eu);   /* bx lr               */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000060u, 0);
    CHECK(r == NK_STOP_RETURN && c.r[13] == 0x8000fda8u,
          "ARM data-processing immediate with low nibble 9 is not a MUL");

    /* ---- pre-MMU low alias: the boot bank really executes at 0 ---- */
    if (nk_alloc_ram(&c, 0x00000000u, 0x20000u) != 0) return 1;
    poke32(&c, 0x00001000u, 0xe3a00007u);   /* mov  r0, #7        */
    poke32(&c, 0x00001004u, 0xe12fff1eu);   /* bx   lr            */
    memset(&c.r, 0, sizeof c.r);
    g_allow_low_alias = 1;
    r = run(&c, 0x00001000u, 0);
    g_allow_low_alias = 0;
    CHECK(r == NK_STOP_RETURN && c.r[0] == 7,
          "ARM runs from the pre-MMU low alias");

    /* ---- ARM: stmdb/ldm sp! round-trip ---- */
    poke32(&c, 0x80000100u, 0xe92d0003u);   /* push {r0,r1}       */
    poke32(&c, 0x80000104u, 0xe8bd0003u);   /* pop  {r0,r1}       */
    poke32(&c, 0x80000108u, 0xe12fff1eu);   /* bx   lr            */
    memset(&c.r, 0, sizeof c.r);
    c.r[0] = 0x11; c.r[1] = 0x22;
    r = run(&c, 0x80000100u, 0);
    CHECK(r == NK_STOP_RETURN && c.r[0] == 0x11 && c.r[1] == 0x22,
          "ARM push/pop preserves registers");

    /* ---- Thumb: movs/adds/muls/bx ---- */
    poke16(&c, 0x80000140u, 0x2005);        /* movs r0, #5        */
    poke16(&c, 0x80000142u, 0x3003);        /* adds r0, #3        */
    poke16(&c, 0x80000144u, 0x2102);        /* movs r1, #2        */
    poke16(&c, 0x80000146u, 0x4348);        /* muls r0, r1, r0    */
    poke16(&c, 0x80000148u, 0x4770);        /* bx   lr            */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000140u, 1);
    CHECK(r == NK_STOP_RETURN, "Thumb returns through bx lr");
    CHECK(c.r[0] == 16, "Thumb movs/adds/muls");

    /* ---- Thumb format 2: bit 10 selects imm3 (1) or register (0) ----
     * A swapped selector silently turns every `adds rd,rs,#n` into a
     * register add, which corrupts descriptor pointers and stack frames. */
    poke16(&c, 0x80000160u, 0x2005);        /* movs r0, #5        */
    poke16(&c, 0x80000162u, 0x2103);        /* movs r1, #3        */
    poke16(&c, 0x80000164u, 0x1d02);        /* adds r2, r0, #4    */
    poke16(&c, 0x80000166u, 0x1843);        /* adds r3, r0, r1    */
    poke16(&c, 0x80000168u, 0x1e84);        /* subs r4, r0, #2    */
    poke16(&c, 0x8000016au, 0x4770);        /* bx   lr            */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000160u, 1);
    CHECK(r == NK_STOP_RETURN && c.r[2] == 9 && c.r[3] == 8 && c.r[4] == 3,
          "Thumb add/sub immediate and register forms");

    /* ---- Thumb: movs r4,#7; push {r4,lr}; movs r4,#0; pop {r4,pc} ---- */
    poke16(&c, 0x80000180u, 0x2407);        /* movs r4, #7        */
    poke16(&c, 0x80000182u, 0xb510);        /* push {r4,lr}       */
    poke16(&c, 0x80000184u, 0x2400);        /* movs r4, #0        */
    poke16(&c, 0x80000186u, 0xbd10);        /* pop  {r4,pc}       */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000180u, 1);
    CHECK(r == NK_STOP_RETURN && c.r[4] == 7, "Thumb push/pop {r4,pc}");

    /* ---- Thumb: beq taken ---- */
    poke16(&c, 0x800001c0u, 0x2001);        /* movs r0, #1        */
    poke16(&c, 0x800001c2u, 0x2801);        /* cmp  r0, #1        */
    poke16(&c, 0x800001c4u, 0xd000);        /* beq  +0 (to +4)    */
    poke16(&c, 0x800001c6u, 0x2009);        /* movs r0, #9 (skip) */
    poke16(&c, 0x800001c8u, 0x2002);        /* movs r0, #2        */
    poke16(&c, 0x800001cau, 0x4770);        /* bx   lr            */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x800001c0u, 1);
    CHECK(r == NK_STOP_RETURN && c.r[0] == 2, "Thumb conditional branch");

    /* ---- ARM MUL/MLA: Rd is bits 19-16, not bits 15-12 ----
     * The old decoder stored the product in bits 15-12 (r0 for a plain MUL),
     * so `mul r2,r0,r1` silently zeroed r0.  The object-index accessor's
     * size multiply hit exactly this and lost its result pointer. */
    poke32(&c, 0x80000060u, 0xe3a00010u);   /* mov r0, #0x10       */
    poke32(&c, 0x80000064u, 0xe3a01020u);   /* mov r1, #0x20       */
    poke32(&c, 0x80000068u, 0xe3a02030u);   /* mov r2, #0x30       */
    poke32(&c, 0x8000006cu, 0xe0020190u);   /* mul r2, r0, r1      */
    poke32(&c, 0x80000070u, 0xe0232190u);   /* mla r3, r0, r1, r2  */
    poke32(&c, 0x80000074u, 0xe0040392u);   /* mul r4, r3, r2      */
    poke32(&c, 0x80000078u, 0xe12fff1eu);   /* bx   lr             */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000060u, 0);
    CHECK(r == NK_STOP_RETURN && c.r[0] == 0x10 && c.r[1] == 0x20 &&
          c.r[2] == 0x200 && c.r[3] == 0x400 && c.r[4] == 0x80000,
          "ARM MUL/MLA write bits 19-16 and leave r0 alone");

    /* ---- ARM long multiply: UMULL/UMLAL/SMULL/SMLAL ----
     * These are `00001 U A S RdHi RdLo Rs 1001 Rm`, not a bit-22 variant of
     * MUL.  Before this test the interpreter executed them as a register-
     * shifted SBC (data-processing opcode 0x6), so every 64-bit product in
     * the kernel was garbage; round 28's TTime conversion stopped on exactly
     * that.  Values also pin RdHi == Rs, which the firmware uses. */
    poke32(&c, 0x800000a0u, 0xe59f0034u);   /* ldr r0, [pc, #0x34]  */
    poke32(&c, 0x800000a4u, 0xe59f1034u);   /* ldr r1, [pc, #0x34]  */
    poke32(&c, 0x800000a8u, 0xe0854190u);   /* umull r4, r5, r0, r1 */
    poke32(&c, 0x800000acu, 0xe0a86190u);   /* umlal r6, r8, r0, r1 */
    poke32(&c, 0x800000b0u, 0xe0c32190u);   /* smull r2, r3, r0, r1 */
    poke32(&c, 0x800000b4u, 0xe0e97190u);   /* smlal r7, r9, r0, r1 */
    poke32(&c, 0x800000b8u, 0xe12fff1eu);   /* bx    lr             */
    poke32(&c, 0x800000dcu, 0xffffffffu);   /* -1                   */
    poke32(&c, 0x800000e0u, 0x00000002u);   /*  2                   */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x800000a0u, 0);
    CHECK(r == NK_STOP_RETURN &&
          c.r[4] == 0xfffffffeu && c.r[5] == 0x00000001u &&
          c.r[6] == 0xfffffffeu && c.r[8] == 0x00000001u &&
          c.r[2] == 0xfffffffeu && c.r[3] == 0xffffffffu &&
          c.r[7] == 0xfffffffeu && c.r[9] == 0xffffffffu,
          "ARM UMULL/UMLAL/SMULL/SMLAL produce 64-bit products");

    /* `smull r1, r3, r2, r3`: RdHi is also Rs.  Real ARM7TDMI/920T read Rs
     * first; the interpreter must not overwrite the multiplicand early. */
    poke32(&c, 0x800000f0u, 0xe59f2018u);   /* ldr r2, [pc, #0x18]  */
    poke32(&c, 0x800000f4u, 0xe59f3018u);   /* ldr r3, [pc, #0x18]  */
    poke32(&c, 0x800000f8u, 0xe0c31392u);   /* smull r1, r3, r2, r3 */
    poke32(&c, 0x800000fcu, 0xe12fff1eu);   /* bx    lr             */
    poke32(&c, 0x80000110u, 0x14c00000u);   /* multiplicand         */
    poke32(&c, 0x80000114u, 0x00005000u);   /* multiplier           */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x800000f0u, 0);
    {
        int64_t prod = (int64_t)(int32_t)0x14c00000 * (int64_t)0x5000;
        CHECK(r == NK_STOP_RETURN &&
              c.r[1] == (uint32_t)prod && c.r[3] == (uint32_t)(prod >> 32),
              "ARM SMULL with RdHi == Rs reads the multiplicand first");
    }

    /* ---- ARM: a non-S SUB/ADD/ADC/SBC must not write the condition flags ----
     * The old data-processing switch called sub_flags()/add_flags()
     * unconditionally, so every plain `add`/`sub` clobbered N/Z/C/V.  This is
     * the exact pattern at 0x50389d14 in EUser's 64-bit divide: `adc r3,r3,r3`
     * (S=0) sits between the `sbcs` comparison and the `movhs` remainder
     * update, and the clobber made every division return 0xFFFFF. */
    poke32(&c, 0x80000520u, 0xe3a00005u);   /* mov r0, #5          */
    poke32(&c, 0x80000524u, 0xe2501003u);   /* subs r1, r0, #3     */
    poke32(&c, 0x80000528u, 0xe0a02000u);   /* adc r2, r0, r0      */
    poke32(&c, 0x8000052cu, 0x03a03055u);   /* moveq r3, #0x55     */
    poke32(&c, 0x80000530u, 0x23a040aau);   /* movhs r4, #0xaa     */
    poke32(&c, 0x80000534u, 0xe12fff1eu);   /* bx lr               */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000520u, 0);
    CHECK(r == NK_STOP_RETURN && c.r[1] == 2 && c.r[2] == 11 &&
          c.r[3] == 0 && c.r[4] == 0xaa,
          "ARM non-S data processing preserves the condition flags");

    /* ---- ARM 64-bit divide loop: the real EUser __udivmoddi4 body ----
     * 8 iterations of the 4-step restoring division.  Dividend
     * 0x00e0ca3991f6bc80 / 0x141dd76000 must give 0xb2ca3 remainder
     * 0x86d549c80.  This exercises SMULL/UMULL, the non-S flag rule and the
     * conditional remainder update together. */
    {
        static const uint32_t grp[8] = {
            0xe0955005u, /* adds r5, r5, r5   */
            0xe0b66006u, /* adcs r6, r6, r6   */
            0xe0b99009u, /* adcs sb, sb, sb   */
            0xe056a007u, /* subs sl, r6, r7   */
            0xe0d9c008u, /* sbcs ip, sb, r8   */
            0xe0a33003u, /* adc  r3, r3, r3   */
            0x21a0600au, /* movhs r6, sl      */
            0x21a0900cu, /* movhs sb, ip      */
        };
        uint32_t a = 0x80000600u;
        for (int i = 0; i < 4; i++)
            for (int g = 0; g < 8; g++, a += 4) poke32(&c, a, grp[g]);
        poke32(&c, a, 0xe2544001u); a += 4;      /* subs r4, r4, #1 */
        poke32(&c, a, 0x1affffddu); a += 4;      /* bne 0x80000600  */
        poke32(&c, a, 0xe12fff1eu);              /* bx lr           */
        memset(&c.r, 0, sizeof c.r);
        c.r[5] = 0x91f6bc80u;
        c.r[6] = 0x00e0ca39u;
        c.r[7] = 0x1dd76000u;
        c.r[8] = 0x14u;
        c.r[4] = 8;
        r = run_budget(&c, 0x80000600u, 0, 1000);
        CHECK(r == NK_STOP_RETURN && c.r[3] == 0xb2ca3u &&
              c.r[6] == 0x6d549c80u && c.r[9] == 8u,
              "ARM 64-bit restoring division returns the right quotient");
    }

    /* ---- ARM: PC-relative ldr uses instruction+8, not instruction+4 ---- */
    poke32(&c, 0x80000240u, 0xe59f1008u);   /* ldr r1, [pc, #8]   */
    poke32(&c, 0x80000244u, 0xe3a0002au);   /* mov r0, #0x2a      */
    poke32(&c, 0x80000248u, 0xe12fff1eu);   /* bx  lr             */
    poke32(&c, 0x8000024cu, 0xe1a00000u);   /* nop (alignment)    */
    poke32(&c, 0x80000250u, 0xcafebabeu);   /* literal            */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000240u, 0);
    CHECK(r == NK_STOP_RETURN && c.r[1] == 0xcafebabeu,
          "ARM PC-relative ldr reads instruction+8");

    /* ---- Thumb BL returns to the instruction *after* the 4-byte BL ---- */
    poke16(&c, 0x80000280u, 0xb500);        /* push {lr}           */
    poke16(&c, 0x80000282u, 0xf000);        /* bl 0x800002c0 (h1)  */
    poke16(&c, 0x80000284u, 0xf81du);       /* bl 0x800002c0 (h2)  */
    poke16(&c, 0x80000286u, 0x2109);        /* movs r1, #9         */
    poke16(&c, 0x80000288u, 0xbd00);        /* pop  {pc}           */
    poke16(&c, 0x800002c0u, 0x2007);        /* movs r0, #7         */
    poke16(&c, 0x800002c2u, 0x4770);        /* bx  lr              */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000280u, 1);
    CHECK(r == NK_STOP_RETURN && c.r[0] == 7 && c.r[1] == 9,
          "Thumb BL returns to pc+4");

    /* ---- crash recovery: a faulting callee returns 0 and the caller runs ---- */
    poke32(&c, 0x80000300u, 0xe3a00001u);   /* mov r0, #1          */
    poke32(&c, 0x80000304u, 0xeb00003du);   /* bl  0x80000400      */
    poke32(&c, 0x80000308u, 0xe2801029u);   /* add r1, r0, #0x29   */
    poke32(&c, 0x8000030cu, 0xe8bd8000u);   /* pop {pc}            */
    /* The pre-MMU low alias makes address 0 executable, so a `mov pc,#0`
     * escape is no longer a fault.  Jump to 0x20000000 instead: it is below
     * the ROM/RAM windows but outside the low alias, so the PC-space guard
     * treats it as a corrupted return. */
    poke32(&c, 0x80000400u, 0xe59ff000u);   /* ldr pc, [pc, #0]    */
    poke32(&c, 0x80000404u, 0x00000000u);
    poke32(&c, 0x80000408u, 0x20000000u);   /* invalid target      */
    poke32(&c, 0x80010000u, TRAP);          /* return address      */
    memset(&c.r, 0, sizeof c.r);
    unsigned long rec = 0;
    r = run_recover(&c, 0x80000300u, 0, &rec);
    CHECK(r == NK_STOP_RETURN && rec == 1 && c.r[1] == 0x29,
          "recovery skips a faulting callee and returns 0");

    /* ---- code-range guard: a call outside the declared text is skipped ---- */
    poke32(&c, 0x80000600u, 0xe92d4000u);   /* push {lr}           */
    poke32(&c, 0x80000604u, 0xe3a00001u);   /* mov r0, #1          */
    poke32(&c, 0x80000608u, 0xeb00003cu);   /* bl  0x80000700      */
    poke32(&c, 0x8000060cu, 0xe8bd8000u);   /* pop {pc}            */
    poke32(&c, 0x80000700u, 0xe3a00badu);   /* mov r0, #0xbad      */
    poke32(&c, 0x80000704u, 0xe12fff1eu);   /* bx  lr              */
    memset(&c.r, 0, sizeof c.r);
    c.r[14] = TRAP;
    uint32_t rr0 = 0;
    r = run_range(&c, 0x80000600u, 0, 0x80000600u, 0x80000610u, &rr0);
    if (!(r == NK_STOP_RETURN && rr0 == 0))
        printf("      range test: r=%d r0=%#x pc=%#x lr=%#x\n",
               r, rr0, c.r[15], c.r[14]);
    CHECK(r == NK_STOP_RETURN && rr0 == 0,
          "call repair stays inside the declared code range");

    /* ---- dispatch fallback: nk_call -> interpreter for an unregistered addr ---- */
    poke32(&c, 0x80000200u, 0xe3a00042u);   /* mov r0, #0x42      */
    poke32(&c, 0x80000204u, 0xe12fff1eu);   /* bx   lr            */
    setenv("NK_INTERP_FALLBACK", "1", 1);
    memset(&c.r, 0, sizeof c.r);
    c.r[14] = 0x80000210u;                  /* return address     */
    c.cpsr = 0x400000d3u;
    nk_call(&c, 0x80000200u);
    CHECK(c.r[0] == 0x42 && c.r[15] == 0x80000210u,
          "nk_call falls back to the interpreter");

    /* ---- `b .` is reported as a panic halt, not run until the budget ---- */
    poke32(&c, 0x80000340u, 0xeafffffeu);   /* b .                 */
    memset(&c.r, 0, sizeof c.r);
    r = run(&c, 0x80000340u, 0);
    CHECK(r == NK_STOP_SELF_BRANCH,
          "ARM `b .` stops with self-branch panic reason");

    /* ---- ARM LDMDB/STMDB with writeback: the EUser memmove tail ----
     * EUser's memmove uses `ldmdb rN!,{r3-r10}` / `stmdb rN!,{r3-r10}` in its
     * backward-copy path.  A wrong P/U start address silently copies the
     * caller's stack instead of the source, which shows up as a corrupted
     * TName during process registration. */
    for (unsigned i = 0; i < 8; i++)
        poke32(&c, 0x80000920u + 4 * i, 0x11110000u + i);
    poke32(&c, 0x80000500u, 0xe93107f8u);   /* ldmdb r1!, {r3-r10} */
    poke32(&c, 0x80000504u, 0xe92007f8u);   /* stmdb r0!, {r3-r10} */
    poke32(&c, 0x80000508u, 0xe12fff1eu);   /* bx lr               */
    memset(&c.r, 0, sizeof c.r);
    c.r[0] = 0x80000a40u;
    c.r[1] = 0x80000940u;
    r = run(&c, 0x80000500u, 0);
    int ldmdb_ok = (r == NK_STOP_RETURN && c.r[0] == 0x80000a20u &&
                    c.r[1] == 0x80000920u && c.r[10] == 0x11110007u);
    for (unsigned i = 0; i < 8 && ldmdb_ok; i++)
        if (nk_r32(&c, 0x80000a20u + 4 * i) != 0x11110000u + i)
            ldmdb_ok = 0;
    CHECK(ldmdb_ok, "ARM LDMDB/STMDB writeback copies the source range");

    /* ---- UPP boot handshake stub: 0x58150422 reports ready bit 0x400 ---- */
    CHECK(nk_r16(&c, 0x58150422u) == 0x0400u,
          "UPP 0x58150422 reports the boot ready bit");

    nk_mem_free(&c);
    if (fails) { printf("%d test(s) failed\n", fails); return 1; }
    printf("interpreter self-test OK\n");
    return 0;
}
