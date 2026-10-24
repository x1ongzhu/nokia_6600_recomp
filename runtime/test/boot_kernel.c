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
 *   NK_CALLMAP=path         call-site fixups / HLE stubs (see config/callmap-6600.txt)
 *   NK_RECOVER=1            roll back a broken callee and continue (bring-up)
 *   NK_RECOVER_MAX=n        stop after n skipped calls (default 256)
 *   NK_RECOVER_LOG=n        log the first n skips (default 16)
 *   NK_SNAP_NOFAST=1        ignore a leaf entry at the raw target and always
 *                           snap to the nearest prologue
 *   NK_HLE_HEAP=0x...       bump heap for NK_HLE_ALLOC (default 0x80400000)
 *   NK_IAT_FAKE=1           unresolved imports return 0 instead of stopping
 *   NK_IAT_LOG=n            log the first n unbound imports (default 16)
 *   NK_ENTRY_ARM=1          start in ARM state instead of Thumb
 *   NK_ENTRY_THUMB=1        force Thumb state (the kernel text is Thumb)
 *   NK_ENTRY=0x...          override the entry address (e.g. 0x50000000 to
 *                           run the ROM's exception-vector code)
 *   NK_WATCH=0x...          dump registers + the call ring when PC hits this
 *   NK_WATCH_HITS=n         how many times to report (default 1)
 *   NK_WATCH_LOG=n          how many recent calls to print (default 16)
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
 *                           0x10-byte segments, see recompiler/bootregions.py) at
 *                           addr (default 0x80000000) and report it; pass the
 *                           same addr in NK_R11 to reproduce the mask-ROM
 *                           hand-off
 *   NK_DUMP=a:l[,a:l...]    append guest memory ranges to NK_DUMP_FILE at the
 *                           end of the run (default out/memdump.bin)
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

static unsigned long env_ulong(const char* name, unsigned long def) {
    const char* s = getenv(name);
    return s ? strtoul(s, NULL, 0) : def;
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
} rom_image_t;

static uint32_t rom_image_prepare(nk_cpu_t* cpu, nk_interp_t* ip,
                                  const uint8_t* img, long len, int verbose) {
    static rom_image_t images[NK_MAX_IMAGES];
    int nimg = 0;
    uint32_t kernel_entry = 0, kernel_hdr = 0;

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
        if (uid3 == 0x100058e8u) { kernel_entry = entry; kernel_hdr = h; }
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
    if (nk_alloc_ram(&cpu, NK_RAM_BASE, NK_RAM_SIZE) != 0) return 1;
    /* The EKA1 kernel entry runs before the MMU remaps RAM to 0x80000000;
     * its early literal pools contain physical data offsets (0x0004_6564,
     * 0x0004_6fca), so the bootstrap view needs RAM at 0x00000000 too. */
    if (!getenv("NK_NO_LOW_RAM") &&
        nk_alloc_ram(&cpu, 0x00000000u, NK_RAM_SIZE) != 0) return 1;
    if (nk_alloc_ram(&cpu, NK_HIGH_VECTORS, 0x10000) != 0) return 1;
    /* Bring-up heap for the callmap's NK_HLE_ALLOC entries. */
    if (nk_alloc_ram(&cpu, 0x80400000u, 0x400000u) != 0) return 1;

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
        thumb_entry = getenv("NK_ENTRY_ARM") ? 0 : 1;
        if (getenv("NK_ENTRY_THUMB")) thumb_entry = 1;
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
        thumb_entry = getenv("NK_ENTRY_ARM") ? 0 : 1;
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
     * and lets recompiler/bootregions.py evolve the table format independently. */
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
    cpu.r[15] = entry & ~1u;

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
    ip.spin_max = (uint32_t)env_ulong("NK_SPIN", 0) ?
        (uint32_t)env_ulong("NK_SPIN_MAX", 20000) : 0;
    ip.require_code = (int)env_ulong("NK_CODE_ONLY", 1);
    ip.allow_low_alias = getenv("NK_LOW_ROM") ? 1 : 0;
    const char* callmap = getenv("NK_CALLMAP");
    if (callmap) load_callmap(&ip, callmap);
    ip.hle_heap = (uint32_t)env_ulong("NK_HLE_HEAP", 0x80400000);
    ip.hle_heap_end = (uint32_t)env_ulong("NK_HLE_HEAP_END", 0x80800000);
    if (getenv("NK_TRACE")) ip.trace = 1;
    ip.trace_limit = (long)env_ulong("NK_TRACE_N", 64);
    ip.trace_from = (uint32_t)env_ulong("NK_TRACE_FROM", 0);
    ip.return_pc = (uint32_t)env_ulong("NK_STOP_PC", cpu.r[14]);
    ip.return_thumb = (uint8_t)thumb_entry;

    printf("run: sp=%#010x cpsr=%#010x budget=%ld infer=%d call-infer=%d policy=%d\n",
           cpu.r[13], cpu.cpsr, ip.budget, ip.infer_mode, ip.infer_calls,
           ip.call_policy);
    nk_interp_run(&cpu, &ip);

    printf("\n--- stop: %s (%d) at %#010x ---\n",
           nk_interp_reason(&ip), ip.st.stop_reason, ip.st.stop_pc);
    printf("insns=%lu (ARM %lu / Thumb %lu), mode switches=%lu, undefined=%lu, "
           "call fixups=%lu, unbound IAT=%lu, recoveries=%lu\n",
           ip.st.insns, ip.st.arm_insns, ip.st.thumb_insns,
           ip.st.mode_switches, ip.st.undefined, ip.st.call_fixups, ip.st.iat_hits,
           ip.st.recoveries);
    printf("mmio: %lu reads, %lu writes\n", nk_mmio_reads(), nk_mmio_writes());
    printf("regs: r0=%#010x r1=%#010x r2=%#010x r3=%#010x sp=%#010x lr=%#010x pc=%#010x\n",
           cpu.r[0], cpu.r[1], cpu.r[2], cpu.r[3], cpu.r[13], cpu.r[14], cpu.r[15]);
    printf("cpsr=%#010x\n", cpu.cpsr);
    printf("last pcs:");
    int start = ip.last_n > 16 ? ip.last_n - 16 : 0;
    for (int i = start; i < ip.last_n; i++)
        printf(" %08x", ip.last[i & 15]);
    printf("\n");

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
