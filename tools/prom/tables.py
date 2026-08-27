"""Find static tables of (string pointer, function pointer, ...) records."""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from promlib import Image, load_map, norm
from strings import extract
from disasm import Dis

img = Image(sys.argv[1])
syms = load_map(sys.argv[2]) if sys.argv[2] != '-' else {}
d = Dis(img, syms); d.run(scan_prologues=True)
strs = {a: b for a, b in extract(img, 2)}

def kind(w):
    t = norm(w)
    if not img.inside(t): return 'x'
    if t in strs: return 's'
    if t in d.code: return 'f'
    return 'd'

W = [(img.base + o, struct.unpack('>I', img.data[o:o+4])[0]) for o in range(0, img.size, 4)]
K = [kind(w) for _, w in W]
sig = ''.join(K)

def scan(pattern, minrep=4):
    """Find runs of a repeating record signature, e.g. 'sf' or 'sd'."""
    out, i, n = [], 0, len(sig)
    L = len(pattern)
    while i < n - L:
        if sig[i:i+L] == pattern:
            j = i
            while sig[j:j+L] == pattern: j += L
            rep = (j - i) // L
            if rep >= minrep: out.append((W[i][0], rep))
            i = j
        else: i += 1
    return out

for pat, label in [('sf', 'name -> handler'), ('sff', 'name -> 2 handlers'),
                   ('sd', 'name -> data'), ('sfd', 'name -> handler + data'),
                   ('ss', 'string pair'), ('sdd', 'name + 2 words')]:
    for base, rep in scan(pat, 5):
        print('\n=== table @ 0x%08x : %d records of "%s" (%s) ==='
              % (base, rep, pat, label))
        for r in range(min(rep, 40)):
            a = base + r * len(pat) * 4
            cells = []
            for c in range(len(pat)):
                w = struct.unpack('>I', img.data[a-img.base+c*4:a-img.base+c*4+4])[0]
                t = norm(w)
                if t in strs:
                    cells.append('"%s"' % strs[t].decode('latin1')[:34])
                elif img.inside(t) and t in d.func: cells.append('sub_%08x' % t)
                elif img.inside(t): cells.append('->%08x' % t)
                else: cells.append('0x%08x' % w)
            print('   %08x  %s' % (a, '  '.join(cells)))
        if rep > 40: print('   ... %d more' % (rep - 40))
