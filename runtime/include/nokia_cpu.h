/*
 * nokia-recomp — ARMv4T (ARM920T / UPP_WD2) guest CPU context.
 *
 * The shape the recompiler's emitted C targets: one generated function per guest
 * function, each taking a pointer to this context and operating on guest
 * registers / flags / memory directly. Ported from ngagerecomp.
 *
 * Memory is a sparse 64 KiB page map (NK_PAGE_COUNT entries).  A 6600 image is
 * not a single flat blob: code lives at 0x5000_0000 (ROM), kernel data at
 * 0x8000_0000 (RAM), exception vectors at 0xFFFF_0000, and the UPP registers
 * sit in MMIO space.  The page map lets the runtime map those independently
 * while keeping the generated C simple.
 */
#ifndef NOKIA_CPU_H
#define NOKIA_CPU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NK_PAGE_SHIFT 16
#define NK_PAGE_SIZE  (1u << NK_PAGE_SHIFT)
#define NK_PAGE_MASK  (NK_PAGE_SIZE - 1)
#define NK_PAGE_COUNT (1u << (32 - NK_PAGE_SHIFT))   /* 65536 */

typedef struct nk_bus nk_bus_t;

/* ARMv4T banked registers.  r13/r14 are banked for every exception mode;
 * FIQ also banks r8-r12.  SPSR exists for FIQ/IRQ/SVC/ABT/UND only.  The
 * interpreter's mode model is opt-in (`NK_BANKED=1`) during bring-up; the
 * plain `r[]`/`cpsr` view remains the default so existing traces are stable. */
typedef struct nk_mode_bank {
    uint32_t sp;
    uint32_t lr;
    uint32_t spsr;
    uint32_t r8, r9, r10, r11, r12;   /* FIQ only */
    uint8_t valid;                     /* sp/lr have been initialised */
    uint8_t spsr_valid;                /* spsr came from a real exception */
    uint8_t preset;                    /* harness supplied this stack */
} nk_mode_bank;

typedef struct nk_cpu {
    uint32_t r[16];   /* r0..r15; r13=sp, r14=lr, r15=pc */
    uint32_t cpsr;    /* NZCV condition flags + mode bits */
    uint8_t* mem;     /* optional flat base (kept for simple test harnesses) */
    uint8_t** pages;  /* sparse guest page map: pages[va >> 16] */
    nk_bus_t* bus;    /* MMIO / device dispatch */
    nk_mode_bank bank[8];  /* USR/SYS, FIQ, IRQ, SVC, ABT, UND */
    uint32_t cp15_c1;      /* CP15 control register (MMU/cache/V bits) */
} nk_cpu_t;

enum { NK_FLAG_N = 31, NK_FLAG_Z = 30, NK_FLAG_C = 29, NK_FLAG_V = 28 };

#ifdef __cplusplus
}
#endif
#endif /* NOKIA_CPU_H */
