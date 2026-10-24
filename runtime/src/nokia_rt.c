/*
 * nokia-recomp — runtime dispatch, sparse guest memory and MMIO stubs.
 *
 * Guest addresses are 32-bit.  The page map gives each 64 KiB page a host
 * pointer; pages without one are treated as MMIO and routed through the bus.
 * The bus starts as a logging stub, which is exactly what the bring-up phase
 * needs: the firmware tells us which UPP registers it wants.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nokia_rt.h"
#include "nokia_interp.h"

/* ------------------------------------------------------------------ */
/* Guest memory                                                        */
/* ------------------------------------------------------------------ */

struct nk_bus {
    /* Reserved for per-device shims.  NULL means "log and return 0". */
    void* user;
};

typedef struct { uint8_t* host; uint32_t size; } nk_alloc_t;
static nk_alloc_t* g_allocs = NULL;
static size_t g_nallocs = 0, g_capallocs = 0;

static void remember_alloc(uint8_t* host, uint32_t size) {
    if (g_nallocs == g_capallocs) {
        g_capallocs = g_capallocs ? g_capallocs * 2 : 16;
        g_allocs = (nk_alloc_t*)realloc(g_allocs, g_capallocs * sizeof(*g_allocs));
    }
    g_allocs[g_nallocs].host = host;
    g_allocs[g_nallocs].size = size;
    g_nallocs++;
}

int nk_mem_init(nk_cpu_t* c) {
    if (!c->pages) {
        c->pages = (uint8_t**)calloc(NK_PAGE_COUNT, sizeof(uint8_t*));
        if (!c->pages) return -1;
    }
    if (!c->bus) {
        c->bus = (nk_bus_t*)calloc(1, sizeof(nk_bus_t));
        if (!c->bus) return -1;
    }
    return 0;
}

uint8_t* nk_page_ptr(nk_cpu_t* c, uint32_t a) {
    if (c->pages) return c->pages[a >> NK_PAGE_SHIFT];
    if (c->mem) return c->mem + a;
    return NULL;
}

int nk_map_region(nk_cpu_t* c, uint32_t va, uint32_t size, uint8_t* host) {
    if (!c->pages) return -1;
    if (va & NK_PAGE_MASK || (size & NK_PAGE_MASK)) {
        fprintf(stderr, "[nk_mem] region %#x+%#x is not page aligned\n", va, size);
        return -1;
    }
    uint32_t n = size >> NK_PAGE_SHIFT;
    for (uint32_t i = 0; i < n; i++) c->pages[(va >> NK_PAGE_SHIFT) + i] = host + (i << NK_PAGE_SHIFT);
    if (host) remember_alloc(host, size);
    return 0;
}

int nk_alloc_ram(nk_cpu_t* c, uint32_t va, uint32_t size) {
    uint8_t* p = (uint8_t*)calloc(1, size);
    if (!p) return -1;
    return nk_map_region(c, va, size, p);
}

int nk_map_file(nk_cpu_t* c, uint32_t va, const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "[nk_mem] cannot open %s\n", path); return -1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return -1; }
    uint32_t size = ((uint32_t)n + NK_PAGE_MASK) & ~NK_PAGE_MASK;
    uint8_t* p = (uint8_t*)calloc(1, size);
    if (!p) { fclose(f); return -1; }
    if (fread(p, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(p); return -1; }
    fclose(f);
    if (nk_map_region(c, va, size, p) != 0) { free(p); return -1; }
    return (int)n;
}

void nk_mem_free(nk_cpu_t* c) {
    for (size_t i = 0; i < g_nallocs; i++) free(g_allocs[i].host);
    free(g_allocs); g_allocs = NULL; g_nallocs = g_capallocs = 0;
    free(c->pages); c->pages = NULL;
    free(c->bus); c->bus = NULL;
}

/* ------------------------------------------------------------------ */
/* MMIO bus                                                            */
/* ------------------------------------------------------------------ */

/* MMIO starts as a logging bus.  The boot trace can produce tens of thousands
 * of accesses to unmapped scratch addresses, so cap the log (NK_MMIO_N, default
 * 400) and print a summary when the cap is hit. */
static unsigned long g_mmio_limit = 400, g_mmio_reads, g_mmio_writes;
static int g_mmio_env = -1;

static void mmio_init(void) {
    if (g_mmio_env >= 0) return;
    const char* s = getenv("NK_MMIO_N");
    g_mmio_limit = s ? strtoul(s, NULL, 0) : 400;
    g_mmio_env = 1;
}

static int mmio_log(unsigned long n) {
    if (g_mmio_limit == 0) return 0;
    if (n < g_mmio_limit) return 1;
    if (n == g_mmio_limit) fprintf(stderr, "[mmio] ... further accesses suppressed\n");
    return 0;
}

static uint32_t mmio_read(nk_cpu_t* c, uint32_t a, unsigned size) {
    (void)c;
    mmio_init();
    unsigned long n = g_mmio_reads++;
    if (mmio_log(n)) fprintf(stderr, "[mmio] read  %#010x (%u)\n", a, size);
    /* The secondary boot bank polls UPP 0x58150422 for bit 0x400 before it
     * continues (linked 0x3ec0..0x3ec8).  The bus has no UPP device model
     * yet, so an unmapped read returning 0 turns that handshake into a
     * 500k-read spin.  Report the ready bit; this is a device stub, not a
     * property of the CPU. */
    if (a == 0x58150422u && size == 2) return 0x0400u;
    /* The same handshake then polls UPP 0x58120a08 until it becomes
     * non-zero (linked 0x3a9c..0x3aa4).  Report a pending event. */
    if (a == 0x58120a08u && size == 4) return 1u;
    /* RAM size probe at linked 0x3c04 reads 0x41001400 and requires bit 0
     * (memory controller present) to continue; bit 1 means "halt" there. */
    if (a == 0x41001400u && size == 4) return 1u;
    return 0;
}

static void mmio_write(nk_cpu_t* c, uint32_t a, uint32_t v, unsigned size) {
    (void)c;
    mmio_init();
    unsigned long n = g_mmio_writes++;
    if (mmio_log(n)) fprintf(stderr, "[mmio] write %#010x = %#x (%u)\n", a, v, size);
}

unsigned long nk_mmio_reads(void)  { return g_mmio_reads; }
unsigned long nk_mmio_writes(void) { return g_mmio_writes; }

uint32_t nk_read_slow(nk_cpu_t* c, uint32_t a, unsigned size) {
    /* Whole access in one unmapped page: let the bus answer as a unit. */
    if ((a & NK_PAGE_MASK) <= NK_PAGE_SIZE - size && !nk_page_ptr(c, a))
        return mmio_read(c, a, size);
    uint32_t v = 0;
    for (unsigned i = 0; i < size; i++) {
        uint8_t* p = nk_page_ptr(c, a + i);
        uint32_t b = p ? p[(a + i) & NK_PAGE_MASK]
                       : (uint32_t)(mmio_read(c, a + i, 1) & 0xff);
        v |= b << (8 * i);
    }
    return v;
}

void nk_write_slow(nk_cpu_t* c, uint32_t a, uint32_t v, unsigned size) {
    if ((a & NK_PAGE_MASK) <= NK_PAGE_SIZE - size && !nk_page_ptr(c, a)) {
        mmio_write(c, a, v, size);
        return;
    }
    for (unsigned i = 0; i < size; i++) {
        uint8_t* p = nk_page_ptr(c, a + i);
        uint8_t b = (uint8_t)(v >> (8 * i));
        if (p) p[(a + i) & NK_PAGE_MASK] = b;
        else mmio_write(c, a + i, b, 1);
    }
}

/* ------------------------------------------------------------------ */
/* Guest -> native dispatch                                            */
/* ------------------------------------------------------------------ */

typedef struct { uint32_t addr; nk_fn fn; } entry_t;

static entry_t* g_tab = NULL;
static size_t   g_len = 0, g_cap = 0;
static int      g_sorted = 0;

void nk_register(uint32_t addr, nk_fn fn) {
    if (g_len == g_cap) {
        g_cap = g_cap ? g_cap * 2 : 1024;
        g_tab = (entry_t*)realloc(g_tab, g_cap * sizeof(entry_t));
    }
    g_tab[g_len].addr = addr; g_tab[g_len].fn = fn; g_len++;
    g_sorted = 0;
}

static int cmp(const void* a, const void* b) {
    uint32_t x = ((const entry_t*)a)->addr, y = ((const entry_t*)b)->addr;
    return (x > y) - (x < y);
}

static nk_fn lookup(uint32_t addr) {
    if (!g_sorted) { qsort(g_tab, g_len, sizeof(entry_t), cmp); g_sorted = 1; }
    size_t lo = 0, hi = g_len;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (g_tab[mid].addr < addr) lo = mid + 1;
        else hi = mid;
    }
    if (lo < g_len && g_tab[lo].addr == addr) return g_tab[lo].fn;
    return NULL;
}

/* Bring-up aids (env-controlled): NK_TRACE logs resolved calls; NK_MAX_CALLS caps
 * total dispatches so a mislifted loop can't spin forever; NK_INTERP_FALLBACK=1
 * runs a callee we have not lifted in the ARMv4T interpreter instead of just
 * reporting it. */
static int  g_trace = -1;
static int  g_interp = -1;
static long g_calls = 0, g_max = 0;

void nk_call(nk_cpu_t* c, uint32_t guest_addr) {
    if (g_trace < 0) {
        g_trace = getenv("NK_TRACE") ? 1 : 0;
        g_interp = getenv("NK_INTERP_FALLBACK") ? 1 : 0;
        const char* m = getenv("NK_MAX_CALLS");
        g_max = m ? atol(m) : 0;
    }
    if (g_max && ++g_calls > g_max) {
        fprintf(stderr, "[nk_call] call budget %ld exhausted\n", g_max);
        return;
    }
    uint32_t a = guest_addr & ~1u;   /* Thumb targets carry bit0=1 */
    nk_fn fn = lookup(a);
    if (fn) {
        if (g_trace) fprintf(stderr, "[nk_call] -> %#010x\n", a);
        fn(c);
        return;
    }
    if (g_interp) {
        if (g_trace) fprintf(stderr, "[nk_call] interp -> %#010x\n", a);
        if (!nk_interp_call(c, guest_addr))
            fprintf(stderr, "[nk_call] interpreter stopped at %#010x before "
                    "returning to %#010x\n", c->r[15], c->r[14]);
        return;
    }
    fprintf(stderr, "[nk_call] no function at %#010x (lr=%#010x)\n", guest_addr, c->r[14]);
}

void nk_unimplemented(nk_cpu_t* c, uint32_t guest_addr, const char* what) {
    (void)c;
    fprintf(stderr, "[nk_unimplemented] %#010x: %s\n", guest_addr, what);
}
