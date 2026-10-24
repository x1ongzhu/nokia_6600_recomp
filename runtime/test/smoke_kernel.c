/*
 * smoke_kernel.c — run a real lifted 6600 kernel function on the host.
 *
 * This is the smallest end-to-end check of the 6600 path:
 *   EKA1 ROM -> wd2.py -> kernel image -> recursive/extract -> lift.py -> C
 *   -> sparse guest memory (ROM at 0x50000000, RAM at 0x80000000)
 *   -> nk_call dispatch.
 *
 * func_50313084 is an ARM helper in the kernel that writes a 32-bit value to
 * the ROM export area (0x58000000 + r1).  The runtime has no device there yet,
 * so the write is logged by the MMIO bus; seeing that log proves the guest
 * instruction executed natively.
 */
#include <stdio.h>
#include <string.h>
#include "nokia_rt.h"

void func_50313084(nk_cpu_t* c);

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
    func_50313084(&c);
    printf("native 6600 kernel function returned: r2=%#x\n", c.r[2]);
    nk_mem_free(&c);
    return 0;
}
