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

typedef struct nk_cpu {
    uint32_t r[16];   /* r0..r15; r13=sp, r14=lr, r15=pc */
    uint32_t cpsr;    /* NZCV condition flags (+ mode bits, later) */
    uint8_t* mem;     /* optional flat base (kept for simple test harnesses) */
    uint8_t** pages;  /* sparse guest page map: pages[va >> 16] */
    nk_bus_t* bus;    /* MMIO / device dispatch */
} nk_cpu_t;

enum { NK_FLAG_N = 31, NK_FLAG_Z = 30, NK_FLAG_C = 29, NK_FLAG_V = 28 };

#ifdef __cplusplus
}
#endif
#endif /* NOKIA_CPU_H */
