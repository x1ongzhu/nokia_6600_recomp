#!/bin/sh
# test_imports.sh — EKA1 import binding + the boot image table.
#
# Round 19 found two coupled facts:
#
#   1. `\System\Libs` is the 586-entry directory below the kernel.  It is the
#      ROM's boot image table: TRomHeader.iPrimaryFile/iSecondaryFile/
#      iVariantFile/iExtensionFile are TRomEntry pointers into it, starting
#      with ekern.exe, EFile.exe, ecust.dll and rtc.dll.  An older build
#      overlaid this directory with \System\Libs\Plugins (171 entries) and
#      destroyed those entries, so the kernel's boot loader read UTF-16 name
#      bytes as an image header.
#
#   2. A flat image already binds every real import: the stub's slot *is* the
#      exporting image's export-table entry and holds the linked code address.
#      The only kernel slot that is not bound is ELocl.dll ordinal 20, an
#      export-table hole (0xffffffff).  NK_IMPORTMAP binds it to an explicit
#      zero-return stub so the boot can reach the next real frontier.
#
# Acceptance:
#   - imports.py enumerates 257 kernel stubs (236 EUser + 21 ELocl) and
#     exactly one unresolved kernel slot (ELocl ordinal 20);
#   - the ROM header's primary/secondary/variant/extension entries resolve to
#     ekern.exe, EFile.exe, ecust.dll and rtc.dll in the linear Libs table;
#   - the flat image bridges that slot at load time (1 patched) and the run
#     no longer stops on an unbound IAT;
#   - the next frontier is the missing initial process/object index, which is
#     B7e, not an import/layout problem.  The accessor at 0x50380270 was
#     misread as RHeap::Alloc in round 19; round 20 identifies it as
#     CObjectIx::At (see tools/test_b7e.sh).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ROM=${1:-6600_mcu.bin}
if [ ! -f "$ROM" ]; then
    echo "$ROM missing; run: .venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 $ROM" >&2
    exit 1
fi

PY=${PY:-}
if [ -z "$PY" ]; then
    if [ -x .venv/bin/python ]; then PY=.venv/bin/python; else PY=python3; fi
fi
mkdir -p out

echo "== import stubs"
"$PY" recompiler/imports.py verify "$ROM" | tee out/imports_verify.log
grep -q "kernel stubs: 257 (236 -> EUser, 21 -> ELocl)" out/imports_verify.log
grep -q "ok: the only unresolved kernel import is ELocl ordinal 20" \
    out/imports_verify.log

"$PY" recompiler/imports.py map "$ROM" --json out/imports_map.json \
    >/dev/null
"$PY" - <<'PY'
import json
rows = json.load(open("out/imports_map.json"))
holes = [r for r in rows if r["image"] == 0x100058e8 and r["kind"] != "bound"]
assert len(holes) == 1, holes
h = holes[0]
assert (h["owner"], h["ordinal"], h["slot"], h["value"]) == \
       (0x100065a5, 20, 0x5037d0e8, 0xffffffff), h
print("ok: kernel imports 236 EUser + 21 ELocl slots; one hole at "
      "ELocl ordinal 20")
PY

echo "== ROMFS boot table"
"$PY" - "$ROM" <<'PY'
import struct, sys
sys.path.insert(0, "recompiler")
import romimage

rom = romimage.load_packed(sys.argv[1])
hdr = romimage.find_rom_header(rom)
root = romimage.find_romfs_root(rom, hdr["root_dir_list"])
dirs = romimage.find_boot_dirs(rom, root, hdr["root_dir_list"])
assert len(dirs.libs_entries) == 586, len(dirs.libs_entries)
assert len(dirs.programs_entries) == 55, len(dirs.programs_entries)
assert len(dirs.plugins_entries or []) == 171, len(dirs.plugins_entries or [])
print(f"ok: \\System\\Libs {len(dirs.libs_entries)}, "
      f"\\System\\Programs {len(dirs.programs_entries)}, "
      f"Plugins {len(dirs.plugins_entries)}")

def entry_at(va):
    off = root + (va - hdr["root_dir_list"])
    size, addr = struct.unpack_from("<II", rom, off)
    nlen = rom[off + 9]
    name = rom[off + 10:off + 10 + 2 * nlen].decode("utf-16le")
    return name, addr, size

want = {
    "primary_file":   ("ekern.exe", 0x5030ff9c, 0x2974c),
    "secondary_file": ("EFile.exe", 0x503b70a0, 0x12318),
    "variant_file":   ("ecust.dll", 0x50339750, 0x2320),
    "extension_file": ("rtc.dll",   0x5033edb0, 0x2614),
}
for field, exp in want.items():
    name, addr, size = entry_at(hdr[field])
    assert (name, addr, size) == exp, (field, name, hex(addr), hex(size))
    print(f"ok: {field} -> {name} @ {addr:#010x} (+{size:#x})")
PY

echo "== flat image import binding"
tools/build_rom_image.sh >/dev/null

clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
    runtime/test/boot_kernel.c runtime/src/nokia_rt.c runtime/src/nokia_interp.c \
    -o out/boot_kernel

NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
NK_IMPORTMAP=config/imports-6600.txt NK_IAT_FAKE=0 NK_RECOVER=0 \
NK_CALL_INFER=0 NK_BUDGET=200000 NK_MMIO_N=0 NK_SWI_LOG=0 \
    ./out/boot_kernel "$ROM" fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin >out/imports_boot.log 2>&1

grep -q "import map config/imports-6600.txt: 1 slot overrides" out/imports_boot.log
grep -q "import rebind: 0x5037d0e8 (uid 0x100065a5 ord 20) 0xffffffff -> 0xffff0100" \
    out/imports_boot.log
grep -q "imports: .* 1 patched" out/imports_boot.log
grep -q "unbound IAT=0" out/imports_boot.log
grep -q "undefined=0" out/imports_boot.log

insns=$(sed -n 's/^insns=\([0-9][0-9]*\).*/\1/p' out/imports_boot.log)
if [ -z "$insns" ] || [ "$insns" -lt 8000 ]; then
    echo "FAIL: run only reached ${insns:-0} instructions" >&2
    tail -25 out/imports_boot.log >&2
    exit 1
fi
echo "ok: import bridge executed $insns instructions with 0 unbound IAT"

# The next frontier must be the allocator, not an import/layout stop.
grep -q "^--- stop: pc left the image (5) at 0000000000 ---" out/imports_boot.log
grep -q "lr=0x503802ac" out/imports_boot.log
grep -q "cpsr=0x000000db" out/imports_boot.log
echo "ok: next frontier is the missing initial process/object index (B7e)"
echo "    (round 20: 0x50380270 is CObjectIx::At, not RHeap::Alloc)"

echo "PASS: import table, ROMFS boot table, and the flat-image slot bridge"
