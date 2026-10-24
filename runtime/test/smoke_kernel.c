/*
 * smoke_kernel.c — run a real lifted 6600 kernel function on the host.
 *
 * This is the smallest end-to-end check of the 6600 path:
 *   EKA1 ROM -> wd2.py -> kernel image -> recursive/extract -> lift.py -> C
 *   -> sparse guest memory (ROM at 0x50000000, RAM at 0x80000000)
 *   -> nk_call dispatch.
 *
 * func_5031308c is an ARM helper in the kernel that writes a 32-bit value to
 * the ROM export area (0x58000000 + r1).  The runtime has no device there yet,
 * so the write is logged by the MMIO bus; seeing that log proves the guest
 * instruction executed natively.
 */
#include <stdio.h>
#include <string.h>
#include "nokia_rt.h"
#include "nokia_interp.h"

void func_5031308c(nk_cpu_t* c);

int main(void) {
    nk_cpu_t c;
    memset(&c, 0, sizeof(c));
    if (nk_mem_init(&c) != 0) { fprintf(stderr, "memory init failed\n"); return 1; }
    if (nk_map_file(&c, NK_FLASH_BASE, "6600_mcu.bin") < 0) {
        fprintf(stderr, "cannot map 6600_mcu.bin (run wd2.py extract first)\n");
        return 1;
    }
    if (nk_alloc_ram(&c, NK_RAM_BASE, NK_RAM_SIZE) != 0) {
        fprintf(stderr, "cannot allocate guest RAM\n");
        return 1;
    }
    c.r[13] = NK_RAM_BASE + NK_RAM_SIZE;   /* stack */
    c.r[0] = 0x1234;                       /* value */
    c.r[1] = 0;                            /* offset into the export area */
    func_5031308c(&c);
    printf("native 6600 kernel function returned: r2=%#x\n", c.r[2]);

    /* Same bytes, same instructions, but executed by the ARMv4T interpreter
     * instead of the generated C.  func_5031308c is:
     *   mov r2, #0x58000000 ; str r0, [r2, r1] ; mov pc, lr
     * LR points at a trap address so the interpreter stops on the return. */
    nk_cpu_t ic;
    memset(&ic, 0, sizeof(ic));
    if (nk_mem_init(&ic) != 0) { fprintf(stderr, "memory init failed\n"); return 1; }
    if (nk_map_file(&ic, NK_FLASH_BASE, "6600_mcu.bin") < 0) return 1;
    if (nk_map_file(&ic, 0x50310000, "fw/6600_kernel.bin") < 0) return 1;
    if (nk_alloc_ram(&ic, NK_RAM_BASE, NK_RAM_SIZE) != 0) return 1;
    ic.r[0] = 0x5678;
    ic.r[1] = 0;
    ic.r[13] = NK_RAM_BASE + NK_RAM_SIZE;
    ic.r[14] = 0xdeadbee0u;
    ic.cpsr = 0x400000d3u;                 /* SVC, ARM state */
    ic.r[15] = 0x5031308cu;
    nk_interp_t ip;
    nk_interp_init(&ip);
    ip.return_pc = 0xdeadbee0u;
    ip.return_thumb = 0;
    ip.budget = 16;
    nk_interp_run(&ic, &ip);
    printf("interpreter: stop=%s pc=%#x r2=%#x insns=%lu\n",
           nk_interp_reason(&ip), ic.r[15], ic.r[2], ip.st.insns);
    if (ip.st.stop_reason != NK_STOP_RETURN || ic.r[2] != 0x58000000u) {
        fprintf(stderr, "interpreter self-check FAILED\n");
        nk_mem_free(&ic);
        nk_mem_free(&c);
        return 1;
    }
    nk_mem_free(&ic);
    nk_mem_free(&c);
    return 0;
}
