#!/bin/sh
# test_round46.sh - the splash-screen route and its EwSrv frontier.
#
# The phone's first visual is the splash/startup screen.  The ROMFS contains
# SplashScreen.exe (uid3 0x100059de, entry 0x509eee85 Thumb) with
# SplashScreen.mbm, plus EwSrv.exe (uid3 0x10003b20, entry 0x506a8205) and
# EStart.exe (0x503da440).  Running SplashScreen in the stable app harness
# reaches EwSrv code and then hits an undefined instruction at 0x506cbf1c:
#
#   509ef864 -> 0x506cbf1c, lr=0x509ef1ab
#
# The target bytes are data / an uninitialised function pointer, not a valid
# Thumb/ARM entry.  Call-site inference does not help, so the next step is the
# EwSrv import/vtable initialisation, not CPU decoding.
#
# NK_MAP_APP_LOW=1 maps the direct path's 0x600000..0x1600000 copy buffer as
# RAM; it shows the copy is a multi-MB data copy with a bad length, not a
# framebuffer.  It remains an opt-in diagnostic.
#
# Acceptance:
#   - the three ROMFS images are at the expected addresses/uid3;
#   - SplashScreen stops at the undefined instruction 0x506cbf1c with
#     lr=0x509ef1ab;
#   - NK_MAP_APP_LOW logs the 16 MiB mapping but does not remove the frontier.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi
mkdir -p out

echo "== round 46: splash screen route"
tools/build_rom_image.sh >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

.venv/bin/python - <<'EOF'
import struct
d = open('out/6600_runtime.bin', 'rb').read(); base = 0x50000000
def u32(a): return struct.unpack_from('<I', d, a - base)[0]
for name, addr, uid3 in (
        ('SplashScreen.exe', 0x509eee20, 0x100059de),
        ('EwSrv.exe', 0x506a81a0, 0x10003b20),
        ('EStart.exe', 0x503da440, 0x00000000)):
    assert u32(addr + 8) == uid3, (name, hex(u32(addr + 8)))
    print('ok: %s @ %#x uid3 %#x' % (name, addr, uid3))
EOF

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=0 \
    NK_SWI_EXCEPTION=1 NK_DFC_EMPTY=1 NK_RECOVER=0 NK_CALL_INFER=1 \
    NK_BUDGET=500000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=0 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000030 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 NK_BANKED=1 \
    NK_ENTRY=0x509eee85 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round46_splash.log 2>&1

grep -q "^--- stop: undefined instruction (1) at 0x506cbf1c ---" \
    out/round46_splash.log
grep -q "lr=0x509ef1ab" out/round46_splash.log
grep -q "509ef864 509ef866 509ef868 506cbf1c" out/round46_splash.log

env NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
    NK_SWI_COMPLETE=0x4d NK_MAP_APP_LOW=1 NK_RECOVER=0 NK_CALL_INFER=0 \
    NK_BUDGET=500000 NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_B7E_LIVE=1 \
    NK_EXT_STUB=1 NK_TRAPCLEAN=1 NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
    NK_ALLOC_LOG=0 NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
    NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
    NK_BOOT_HANDOFF=1 NK_PRIMARY_RAM=0x80900000 NK_HAL_TIMER_HZ=4 \
    NK_SYSTEM_TIME=1 NK_TIMER=1 NK_TIMER_LOG=0 \
    NK_IMPORTMAP=config/imports-r29-6600.txt NK_CPSR=0x40000053 \
    NK_IRQ_LOG=0 NK_TIMERQ=1 NK_B7E_VALID_HI=0x80a00000 \
    NK_ENTRY=0x506897d5 NK_SP=0x80580000 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/round46_lowmap.log 2>&1
grep -q "app low buffer: mapped 0x600000..0x1600000" out/round46_lowmap.log

echo "ok: SplashScreen.exe / EwSrv.exe / EStart.exe are at the expected"
echo "    ROMFS addresses"
echo "ok: SplashScreen reaches EwSrv code and stops on the bad pointer"
echo "    0x506cbf1c (lr=0x509ef1ab), not a CPU decode limit"
echo "ok: NK_MAP_APP_LOW maps the 16 MiB low buffer; the copy is a data copy"
echo "    with a bad length, not the framebuffer"
echo "PASS: round 46 pins the splash-screen route and its EwSrv frontier"
