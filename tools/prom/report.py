"""Generate the analysis reports that accompany the listings."""
import sys, os, json, struct
from collections import defaultdict, Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from promlib import Image, load_map, norm
from strings import extract
from hwmap import lookup, MC, MC_BASE, INT2, INT2_BASE
from disasm import Dis
from emit import Emitter
from capstone.mips import *

img_path, map_path, outdir, tag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
img = Image(img_path)
syms = load_map(map_path) if map_path != '-' else {}
d = Dis(img, syms); d.run(scan_prologues=True)
e = Emitter(img, syms, d)
os.makedirs(outdir, exist_ok=True)

# ---------------------------------------------------------------- function map
funcs = sorted(d.func)
bounds = {}
for i, f in enumerate(funcs):
    nxt = funcs[i+1] if i+1 < len(funcs) else img.end
    end = f
    a = f
    while a < nxt and a in d.code: a += 4
    bounds[f] = (f, a)

def owner(addr):
    lo, hi = 0, len(funcs)-1
    best = None
    while lo <= hi:
        m = (lo+hi)//2
        if funcs[m] <= addr: best = funcs[m]; lo = m+1
        else: hi = m-1
    if best is not None and bounds[best][1] > addr: return best
    return best

# strings used by each function
fn_strings = defaultdict(list)
for sa in e.strs:
    for ref in d.xref_data.get(sa, ()):
        o = owner(ref)
        if o is not None: fn_strings[o].append(sa)

# mmio touched by each function
fn_mmio = defaultdict(set)
mmio_fn = defaultdict(set)
for va, refs in d.xref_data.items():
    if img.inside(va): continue
    hw = lookup(va)
    if not hw: continue
    p = va & 0x1fffffff
    if not (0x1f000000 <= p < 0x1fc00000): continue
    for r in refs:
        o = owner(r)
        if o is not None:
            fn_mmio[o].add(hw[0]); mmio_fn[hw[0]].add(o)

with open(os.path.join(outdir, 'functions-%s.txt' % tag), 'w') as fh:
    fh.write('SGI IP24 PROM %s - function inventory (%d functions)\n' % (tag, len(funcs)))
    fh.write('=' * 100 + '\n\n')
    for f in funcs:
        lo, hi = bounds[f]
        nm = e.names.get(f, 'sub_%08x' % f)
        callers = sorted(d.xref_call.get(f, ()))
        fh.write('%-34s %08x-%08x  %5d bytes  callers=%d\n' % (nm, lo, hi, hi-lo, len(callers)))
        if callers:
            cn = sorted({e.names.get(owner(c), '?') for c in callers if owner(c) is not None})
            fh.write('    called by : %s\n' % ', '.join(cn[:12]) + (' ...' if len(cn) > 12 else ''))
        if fn_mmio.get(f):
            fh.write('    hardware  : %s\n' % ', '.join(sorted(fn_mmio[f])[:14]))
        ss = fn_strings.get(f)
        if ss:
            for sa in sorted(set(ss))[:8]:
                t = e.strs[sa].decode('latin1').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t')
                fh.write('    string    : "%s"\n' % (t[:78] + ('...' if len(t) > 78 else '')))
        fh.write('\n')

# ---------------------------------------------------------------- hardware map
with open(os.path.join(outdir, 'hardware-%s.txt' % tag), 'w') as fh:
    fh.write('SGI IP24 PROM %s - memory-mapped hardware access inventory\n' % tag)
    fh.write('=' * 100 + '\n')
    fh.write('Every address the PROM forms with a lui/addiu or lui/ori pair, grouped by device.\n')
    fh.write('"refs" counts distinct instructions touching the address.\n\n')
    groups = defaultdict(list)
    for va, refs in d.xref_data.items():
        if img.inside(va): continue
        p = va & 0x1fffffff if va >= 0x80000000 else va
        hw = lookup(va)
        if hw is None: continue
        if 0x1fa00000 <= p < 0x1fa20000: g = 'MC   - memory / GIO64 controller  (phys 0x1fa00000)'
        elif 0x1fbd9880 <= p < 0x1fbd98e0: g = 'INT2 - interrupt controller + 8254 timers (phys 0x1fbd9880)'
        elif 0x1fbe0000 <= p < 0x1fbe8000: g = 'RTC/NVRAM - Dallas DS1386 (phys 0x1fbe0000, byte per word)'
        elif 0x1fb80000 <= p < 0x1fc00000: g = 'HPC3 - peripheral controller (phys 0x1fb80000)'
        elif 0x1f000000 <= p < 0x1fa00000: g = 'GFX / GIO expansion (phys 0x1f000000-0x1f9fffff)'
        elif 0x08000000 <= p < 0x10000000: g = 'Main memory / PROM working RAM (phys 0x08000000+)'
        else: continue
        groups[g].append((p, va, len(refs), hw))
    for g in sorted(groups):
        rows = sorted(set(groups[g]))
        fh.write('\n' + '-' * 100 + '\n%s\n' % g + '-' * 100 + '\n')
        for p, va, n, hw in rows:
            fh.write('  phys 0x%08x  (va 0x%08x)  %-28s refs=%-4d %s\n' % (p, va, hw[0], n, hw[1]))

# ---------------------------------------------------------------- strings
with open(os.path.join(outdir, 'strings-%s.txt' % tag), 'w') as fh:
    fh.write('SGI IP24 PROM %s - string table (%d strings)\n\n' % (tag, len(e.strs)))
    for sa in sorted(e.strs):
        refs = sorted(d.xref_data.get(sa, ()))
        who = sorted({e.names.get(owner(r), '') for r in refs if owner(r) is not None})
        t = e.strs[sa].decode('latin1').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t')
        fh.write('%08x  %-72s  %s\n' % (sa, '"%s"' % t[:70], ('<- ' + ', '.join(who[:4])) if who else ''))

json.dump({'funcs': ['%08x' % f for f in funcs],
           'names': {('%08x' % a): n for a, n in e.names.items()}},
          open(os.path.join(outdir, 'symbols-%s.json' % tag), 'w'), indent=0)
print('%s: %d funcs, %d strings, %d hw addrs' % (tag, len(funcs), len(e.strs), sum(len(v) for v in groups.values())))
