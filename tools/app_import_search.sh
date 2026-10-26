#!/bin/sh
# app_import_search.sh - greedy per-slot search over EUser ordinals an app uses.
#
# Usage: tools/app_import_search.sh [idx:shift ...]
#
# Each candidate pins EUser export slot <idx> to the value of ROM export
# <idx - shift> (through NK_IMPORTMAP_APP), runs EFile and reports the
# stop reason plus the Thumb instruction count.  It exists because a uniform
# rotation is wrong (round 105) and the mapping has to be found per slot.
#
# NOTE: the Thumb count is a poor score.  Larger values can mean the run has
# fallen back into an older crash, e.g. the round-100 RHeap housekeeping null
# call at 0x5039ca0c.  Always read the stop reason and the last PCs too.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
ED=0x503b3794

EDATA=$ED .venv/bin/python - "$@" <<'PY'
import os, struct, subprocess, sys
ED = int(os.environ["EDATA"], 0)
d = open('out/6600_runtime.bin','rb').read()
def val(i): return struct.unpack_from('<I', d, ED + 4*i - 0x50000000)[0]

base_env = dict(os.environ)
def run(mapfile, log):
    env = dict(base_env)
    env.update({
        "NK_SUPERPAGE":"1","NK_RAM_EXTRA":"0x300000","NK_KERNEL_VECTORS":"1",
        "NK_SWI_DIRECT":"1","NK_SWI_COMPLETE":"0x4d","NK_RECOVER":"0",
        "NK_CALL_INFER":"0","NK_BUDGET":"600000","NK_MMIO_N":"8","NK_SWI_LOG":"0",
        "NK_B7E":"1","NK_B7E_LIVE":"1","NK_EXT_STUB":"1","NK_TRAPCLEAN":"1",
        "NK_TRAP_FRAME":"1","NK_THREAD_HEAP":"0x80905ec4","NK_ALLOC_HLE":"1",
        "NK_ALLOC_PC":"0x5038e2ec","NK_ALLOC_LOG":"0","NK_ALLOC_HLE_KERNEL_ONLY":"1",
        "NK_ALLOC_BASE":"0x80600000","NK_ALLOC_END":"0x80a00000",
        "NK_HLE_HEAP":"0x80700000","NK_CALLMAP":"config/callmap-rtc-6600.txt",
        "NK_BOOT_HANDOFF":"1","NK_PRIMARY_RAM":"0x80900000","NK_HAL_TIMER_HZ":"4",
        "NK_SYSTEM_TIME":"1","NK_TIMER":"1","NK_TIMER_LOG":"0",
        "NK_IMPORTMAP":"config/imports-r29-6600.txt","NK_IMPORTMAP_REVERT":"1",
        "NK_IMPORTMAP_NO_REVERT":"0x503b3948","NK_IMPORTMAP_APP":mapfile,
        "NK_CPSR":"0x40000053","NK_IRQ_LOG":"0","NK_TIMERQ":"1",
        "NK_B7E_VALID_HI":"0x80a00000","NK_SCHED":"1","NK_SCHED_FAKE":"1",
        "NK_SCHED_ENTRY":"0x503b7105","NK_SCHED_STACK":"0x80560000",
        "NK_SCHED_STACK_EXTRA":"0x600","NK_SCHED_STACK_FILL":"0xdead0000",
        "NK_SCHED_AUTOCOMPLETE":"1","NK_SCHED_EXIT":"1","NK_SCHED_LOG":"0",
        "NK_HANDOFF_ARM":"1","NK_MEMCOPY_CLAMP":"1","NK_SCHED_NO_PREEMPT":"1",
        "NK_SWI_RET":"0x1c:-1",
    })
    with open(log, "w") as fh:
        subprocess.run(["./out/boot_kernel","6600_mcu.bin","fw/6600_kernel.bin",
                        "--rom-image","out/6600_runtime.bin"], env=env,
                       stdout=fh, stderr=subprocess.STDOUT, check=False)
    txt = open(log).read()
    thumb = 0
    stop = ""
    import re
    for line in txt.splitlines():
        m = re.search(r'Thumb (\d+)', line)
        if m:
            thumb = int(m.group(1))
        if line.startswith("--- stop:"):
            stop = line.strip()
    return thumb, stop

open('/tmp/ais_empty.map','w').close()
best, stop = run('/tmp/ais_empty.map', '/tmp/ais_base.log')
crash0 = any(k in stop for k in ('null call', 'pc left', 'undefined',
                                 'self-branch', 'Swi'))
print('baseline          Thumb=%-5d %s%s' % (best, stop,
                                             ' (crash)' if crash0 else ' (clean)'))
for spec in sys.argv[1:]:
    idx, shift = (int(x) for x in spec.split(':'))
    slot = ED + 4*idx
    tgt = val(idx - shift)
    with open('/tmp/ais_try.map','w') as fh:
        fh.write('0x%08x 0x%08x\n' % (slot, tgt))
    t, s = run('/tmp/ais_try.map', '/tmp/ais_try.log')
    def crashed(st):
        return any(k in st for k in ('null call', 'pc left', 'undefined',
                                     'self-branch', 'Swi'))
    flag = ''
    if not crashed(s) and (crashed(stop) or t > best):
        flag = 'BETTER (no crash)'
    elif t > best:
        flag = 'longer but crashes'
    print('idx=%-4d -%d -> %-12s Thumb=%-5d %s %s'
          % (idx, shift, '0x%08x' % tgt, t, s, flag))
PY
