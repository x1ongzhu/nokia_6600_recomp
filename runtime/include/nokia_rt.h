/*
 * nokia-recomp — runtime helpers the generated C calls.
 *
 * Sparse guest memory + ARM NZCV flag math, as static-inline so each generated
 * translation unit stays dependency-light. Ported from ngagerecomp's runtime
 * core (the ARM CPU model is platform-independent) and extended for the 6600's
 * EKA1 memory map:
 *
 *   ROM code       0x5000_0000 .. 0x5160_0000   (22 MiB, XIP)
 *   kernel data    0x8000_0000 .. 0x8030_0000   (3 MiB, RAM)
 *   high vectors   0xffff_0000 .. 0xffff_1000
 *   MMIO           everywhere else (bus callbacks)
 *
 * Accesses take the fast path when the whole value lies inside one 64 KiB page;
 * data crossing a page and all MMIO go through the slow path in nokia_rt.c.
 */
#ifndef NOKIA_RT_H
#define NOKIA_RT_H

#include <stdint.h>
#include "nokia_cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NK_FLASH_BASE   0x50000000u   /* EKA1 ROM link address */
#define NK_FLASH_SIZE   0x01600000u
#define NK_RAM_BASE     0x80000000u   /* kernel data */
#define NK_RAM_SIZE     0x00300000u
#define NK_HIGH_VECTORS 0xffff0000u

/* ---- memory: fast inline page access, slow path in nokia_rt.c ---- */
uint8_t* nk_page_ptr(nk_cpu_t* c, uint32_t a);
uint32_t nk_read_slow(nk_cpu_t* c, uint32_t a, unsigned size);
void     nk_write_slow(nk_cpu_t* c, uint32_t a, uint32_t v, unsigned size);

static inline uint32_t nk_r32(nk_cpu_t* c, uint32_t a) {
    if ((a & NK_PAGE_MASK) <= NK_PAGE_SIZE - 4) {
        const uint8_t* p = nk_page_ptr(c, a);
        if (p) return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                      ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    }
    return nk_read_slow(c, a, 4);
}
static inline uint16_t nk_r16(nk_cpu_t* c, uint32_t a) {
    if ((a & NK_PAGE_MASK) <= NK_PAGE_SIZE - 2) {
        const uint8_t* p = nk_page_ptr(c, a);
        if (p) return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
    }
    return (uint16_t)nk_read_slow(c, a, 2);
}
static inline uint8_t nk_r8(nk_cpu_t* c, uint32_t a) {
    const uint8_t* p = nk_page_ptr(c, a);
    return p ? p[a & NK_PAGE_MASK] : (uint8_t)nk_read_slow(c, a, 1);
}
static inline void nk_w32(nk_cpu_t* c, uint32_t a, uint32_t v) {
    if ((a & NK_PAGE_MASK) <= NK_PAGE_SIZE - 4) {
        uint8_t* p = nk_page_ptr(c, a);
        if (p) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8);
                 p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24); return; }
    }
    nk_write_slow(c, a, v, 4);
}
static inline void nk_w16(nk_cpu_t* c, uint32_t a, uint16_t v) {
    if ((a & NK_PAGE_MASK) <= NK_PAGE_SIZE - 2) {
        uint8_t* p = nk_page_ptr(c, a);
        if (p) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); return; }
    }
    nk_write_slow(c, a, v, 2);
}
static inline void nk_w8(nk_cpu_t* c, uint32_t a, uint8_t v) {
    uint8_t* p = nk_page_ptr(c, a);
    if (p) p[a & NK_PAGE_MASK] = v; else nk_write_slow(c, a, v, 1);
}

/* ---- NZCV flags (in cpsr) ---- */
#define NK_BIT(n) (1u << (n))
static inline uint32_t nk_nf(nk_cpu_t* c){ return (c->cpsr >> NK_FLAG_N) & 1u; }
static inline uint32_t nk_zf(nk_cpu_t* c){ return (c->cpsr >> NK_FLAG_Z) & 1u; }
static inline uint32_t nk_cf(nk_cpu_t* c){ return (c->cpsr >> NK_FLAG_C) & 1u; }
static inline uint32_t nk_vf(nk_cpu_t* c){ return (c->cpsr >> NK_FLAG_V) & 1u; }
static inline void nk_setf(nk_cpu_t* c, int bit, uint32_t v) {
    if (v) c->cpsr |= NK_BIT(bit); else c->cpsr &= ~NK_BIT(bit);
}
static inline void nk_set_nz(nk_cpu_t* c, uint32_t r) {
    nk_setf(c, NK_FLAG_N, r >> 31);
    nk_setf(c, NK_FLAG_Z, r == 0);
}
static inline uint32_t nk_add_flags(nk_cpu_t* c, uint32_t a, uint32_t b, uint32_t cin) {
    uint64_t u = (uint64_t)a + (uint64_t)b + (uint64_t)cin;
    uint32_t r = (uint32_t)u;
    nk_set_nz(c, r);
    nk_setf(c, NK_FLAG_C, (uint32_t)(u >> 32));
    nk_setf(c, NK_FLAG_V, (~(a ^ b) & (a ^ r)) >> 31);
    return r;
}
static inline uint32_t nk_sub_flags(nk_cpu_t* c, uint32_t a, uint32_t b) {
    uint32_t r = a - b;
    nk_set_nz(c, r);
    nk_setf(c, NK_FLAG_C, a >= b);
    nk_setf(c, NK_FLAG_V, ((a ^ b) & (a ^ r)) >> 31);
    return r;
}

/* ---- register-amount shifts (Rs[7:0]; C shift by >= width is UB) ---- */
static inline uint32_t nk_lsl(uint32_t v, uint32_t amt){ amt&=0xff; return amt>=32?0u:(v<<amt); }
static inline uint32_t nk_lsr(uint32_t v, uint32_t amt){ amt&=0xff; return amt>=32?0u:(v>>amt); }
static inline uint32_t nk_asr(uint32_t v, uint32_t amt){ amt&=0xff; if(amt>=32)amt=31; return (uint32_t)((int32_t)v>>amt); }
static inline uint32_t nk_ror(uint32_t v, uint32_t amt){ amt&=0xff; amt&=31; return amt?((v>>amt)|(v<<(32-amt))):v; }

/* ---- memory setup / loading (impl in nokia_rt.c) ---- */
int  nk_mem_init(nk_cpu_t* c);
int  nk_map_region(nk_cpu_t* c, uint32_t va, uint32_t size, uint8_t* host);
int  nk_map_file(nk_cpu_t* c, uint32_t va, const char* path);
int  nk_alloc_ram(nk_cpu_t* c, uint32_t va, uint32_t size);
void nk_mem_free(nk_cpu_t* c);

/* ---- guest -> native dispatch (impl in nokia_rt.c) ---- */
typedef void (*nk_fn)(nk_cpu_t*);
void nk_register(uint32_t guest_addr, nk_fn fn);   /* populate the table at startup */
void nk_call(nk_cpu_t* c, uint32_t guest_addr);    /* bl / indirect / tail dispatch */
void nk_unimplemented(nk_cpu_t* c, uint32_t guest_addr, const char* what);
void nk_game_register(void);                       /* register all lifted funcs (generated) */

#ifdef __cplusplus
}
#endif
#endif /* NOKIA_RT_H */
