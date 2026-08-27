"""Shared library for SGI IP24 (Indy) PROM analysis."""
import struct, re, os

BASE = 0xbfc00000          # kseg1 uncached alias the reset vector runs in
KSEG0 = 0x9fc00000         # kseg0 cached alias (same physical PROM)
PHYS  = 0x1fc00000         # physical

def norm(a):
    """Normalise any PROM alias to the kseg1 (0xbfc00000) canonical form."""
    if 0x9fc00000 <= a < 0x9fc80000: return a - 0x9fc00000 + BASE
    if 0x1fc00000 <= a < 0x1fc80000: return a - 0x1fc00000 + BASE
    return a

class Image:
    def __init__(self, path, base=BASE):
        self.data = open(path,'rb').read()
        self.base = base
        self.size = len(self.data)
        self.end  = base + self.size
        self.path = path
    def inside(self, a):
        return self.base <= a < self.end
    def off(self, a):
        return a - self.base
    def w32(self, a):
        o = a - self.base
        if o < 0 or o+4 > self.size: return None
        return struct.unpack('>I', self.data[o:o+4])[0]
    def u8(self, a):
        o = a - self.base
        if o < 0 or o >= self.size: return None
        return self.data[o]
    def cstr(self, a, maxlen=400):
        o = a - self.base
        if o < 0 or o >= self.size: return None
        e = self.data.find(b'\0', o)
        if e < 0 or e - o > maxlen: e = min(o+maxlen, self.size)
        return self.data[o:e]

def load_map(path):
    """Parse Ghidra 'addr ? name' export -> {canonical_addr: [names]}"""
    syms = {}
    for line in open(path, errors='replace'):
        p = line.split()
        if len(p) != 3: continue
        try: a = int(p[0], 16)
        except ValueError: continue
        syms.setdefault(norm(a), []).append(p[2])
    return syms

AUTO_PREFIXES = ('FUN_','SUB_','LAB_','DAT_','PTR_','caseD','switchD',
                 'switchdataD','default','s_','FLOAT_')

def sym_kind(names):
    """Classify a Ghidra symbol set into code/data/string/jumptable."""
    # A hand-written annotation (anything not matching Ghidra's auto-name
    # patterns) is a renamed function in this database -- seed it as code.
    for n in names:
        if not n.startswith(AUTO_PREFIXES): return 'func'
    for n in names:
        if n.startswith(('FUN_','SUB_')): return 'func'
    for n in names:
        if n.startswith(('LAB_','caseD','default','switchD')) and not n.startswith('switchdataD'):
            return 'code'
    for n in names:
        if n.startswith('switchdataD'): return 'jumptable'
    for n in names:
        if n.startswith('s_'): return 'string'
    for n in names:
        if n.startswith(('PTR_','DAT_')): return 'data'
    return 'data'
