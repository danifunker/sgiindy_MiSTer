"""Emit the annotated disassembly listing."""
import sys, os, struct
sys.path.insert(0, os.path.dirname(__file__))
from promlib import Image, load_map, sym_kind, norm
from strings import extract
from hwmap import lookup
from disasm import Dis
from capstone.mips import *

CACHE_OP = {
 0x00:'Index_Invalidate_I', 0x01:'Index_WB_Invalidate_D',
 0x02:'Index_Invalidate_SI',0x03:'Index_WB_Invalidate_SD',
 0x04:'Index_Load_Tag_I',   0x05:'Index_Load_Tag_D',
 0x06:'Index_Load_Tag_SI',  0x07:'Index_Load_Tag_SD',
 0x08:'Index_Store_Tag_I',  0x09:'Index_Store_Tag_D',
 0x0a:'Index_Store_Tag_SI', 0x0b:'Index_Store_Tag_SD',
 0x0d:'Create_Dirty_Exc_D', 0x0f:'Create_Dirty_Exc_SD',
 0x10:'Hit_Invalidate_I',   0x11:'Hit_Invalidate_D',
 0x12:'Hit_Invalidate_SI',  0x13:'Hit_Invalidate_SD',
 0x14:'Fill_I',             0x15:'Hit_WB_Invalidate_D',
 0x17:'Hit_WB_Invalidate_SD',
 0x18:'Hit_WB_I',           0x19:'Hit_WB_D', 0x1b:'Hit_WB_SD',
 0x1e:'Hit_Set_Virtual_SI', 0x1f:'Hit_Set_Virtual_SD',
}

COP0 = {0:'Index',1:'Random',2:'EntryLo0',3:'EntryLo1',4:'Context',5:'PageMask',
        6:'Wired',8:'BadVAddr',9:'Count',10:'EntryHi',11:'Compare',12:'Status',
        13:'Cause',14:'EPC',15:'PRId',16:'Config',17:'LLAddr',18:'WatchLo',
        19:'WatchHi',20:'XContext',26:'ECC',27:'CacheErr',28:'TagLo',29:'TagHi',
        30:'ErrorEPC'}

class Emitter:
    def __init__(self, img, syms, d):
        self.img, self.syms, self.d = img, syms, d
        self.strs = {a: b for a, b in extract(img, 3)}
        self.names = {}
        for a, n in syms.items():
            if img.inside(a):
                nm = self.pick(n)
                # Ghidra auto-names embed whichever alias (0x9fc.. / 0xbfc..)
                # the analyst happened to click; rewrite to the canonical addr
                for pref in ('FUN_', 'SUB_', 'LAB_', 'DAT_', 'PTR_DAT_',
                             'PTR_FUN_', 'FLOAT_'):
                    if nm.startswith(pref) and len(nm) == len(pref) + 8:
                        nm = '%s%08x' % (pref, a)
                        break
                self.names[a] = nm
        for a in d.func:
            self.names.setdefault(a, 'sub_%08x' % a)
        for a in d.xref_code:
            self.names.setdefault(a, 'loc_%08x' % a)
        for a in self.strs:
            self.names.setdefault(a, 'aStr_%08x' % a)

    AUTO = ('FUN_', 'SUB_', 'LAB_', 'DAT_', 'PTR_', 'caseD', 'switchD',
            'switchdataD', 'default', 's_', 'FLOAT_')

    @classmethod
    def pick(cls, names):
        # a hand-written annotation always wins over a Ghidra auto-name
        for n in names:
            if not n.startswith(cls.AUTO): return n
        for pref in ('FUN_', 'SUB_', 's_', 'PTR_', 'switchD', 'switchdataD',
                     'caseD', 'LAB_', 'DAT_'):
            for n in names:
                if n.startswith(pref): return n
        return names[0]

    def label(self, a):
        a = norm(a)
        if a in self.names: return self.names[a]
        hw = lookup(a)
        if hw: return hw[0]
        return '0x%08x' % a

    def strpreview(self, a, n=60):
        b = self.strs.get(norm(a))
        if b is None: return None
        s = b.decode('latin1')
        s = s.replace('\\','\\\\').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t').replace('"','\\"')
        return '"%s%s"' % (s[:n], '...' if len(s) > n else '')

    def fixup(self, i, raw):
        """Rewrite operand text capstone renders wrongly for CP0 / cache ops."""
        m, ops = i.mnemonic, i.op_str
        if m in ('mfc0','mtc0','dmfc0','dmtc0','cfc0','ctc0'):
            rt  = (raw >> 16) & 0x1f
            rd  = (raw >> 11) & 0x1f
            sel = raw & 7
            gpr = ops.split(',')[0].strip()
            nm  = COP0.get(rd, 'CP0r%d' % rd)
            return '%s, $%s%s' % (gpr, nm, (', %d' % sel) if sel else '')
        if m == 'cache':
            op = (raw >> 16) & 0x1f
            rest = ops.split(',', 1)[1].strip() if ',' in ops else ops
            return '%s, %s' % (CACHE_OP.get(op, '0x%02x' % op), rest)
        return ops

    def annotate(self, i, raw):
        """Right-hand comment for one instruction."""
        c = []
        a = i.address
        v = self.d.const.get(a)
        if v is not None:
            sp = self.strpreview(v)
            if sp:
                c.append('-> %s %s' % (self.label(v), sp))
            elif self.img.inside(v):
                lbl = self.label(v)
                # a load from PROM data: show the word actually fetched
                if i.mnemonic in ('lw','lwu') and (v & 3) == 0:
                    w = self.img.w32(v)
                    if w is not None:
                        t = norm(w)
                        tgt = self.strpreview(t)
                        if tgt: c.append('-> %s = %s' % (lbl, tgt))
                        elif self.img.inside(t) and t in self.names:
                            c.append('-> %s = &%s' % (lbl, self.names[t]))
                        else:
                            hw = lookup(w)
                            if hw and w >= 0x1f000000:
                                c.append('-> %s = 0x%08x (%s)' % (lbl, w, hw[0]))
                            else:
                                c.append('-> %s = 0x%08x' % (lbl, w))
                    else: c.append('-> %s' % lbl)
                else: c.append('-> %s' % lbl)
            else:
                hw = lookup(v)
                if hw: c.append('-> %s  [%s]' % (hw[0], hw[1]))
                else: c.append('= 0x%08x (%d)' % (v, v if v < 0x80000000 else v - (1 << 32)))
        if i.mnemonic in ('j','jal','b') or i.mnemonic.startswith('b'):
            for op in i.operands:
                if op.type == MIPS_OP_IMM:
                    t = norm(op.imm & 0xffffffff)
                    if self.img.inside(t) and t in self.names:
                        c.append('%s' % self.names[t])
                    break
        return '  ; ' + ' | '.join(c) if c else ''

    def emit(self, fh, lo=None, hi=None):
        img = self.img
        lo = lo if lo is not None else img.base
        hi = hi if hi is not None else img.end
        a = lo
        in_data = None
        while a < hi:
            nm = self.names.get(a)
            xr_c = self.d.xref_call.get(a, ())
            xr_b = self.d.xref_code.get(a, ())
            xr_d = self.d.xref_data.get(a, ())
            if a in self.d.code and self.d.insns.get(a):
                if in_data: fh.write('\n'); in_data = False
                if a in self.d.func or xr_c:
                    fh.write('\n' + '=' * 78 + '\n')
                    fh.write('%s:   ; %s\n' % (nm or 'sub_%08x' % a, self._xrefline(xr_c, xr_b, xr_d)))
                    fh.write('=' * 78 + '\n')
                elif nm and (xr_b or xr_d):
                    fh.write('\n%s:   ; %s\n' % (nm, self._xrefline(xr_c, xr_b, xr_d)))
                i = self.d.insns[a]
                raw = struct.unpack('>I', img.data[a-img.base:a-img.base+4])[0]
                fh.write('%08x  %08x  %-8s %-34s%s\n'
                         % (a, raw, i.mnemonic, self.fixup(i, raw), self.annotate(i, raw)))
                a += 4
            else:
                if not in_data:
                    fh.write('\n'); in_data = True
                a = self._emit_data(fh, a, hi)
        return

    def _xrefline(self, c, b, d):
        parts = []
        if c: parts.append('CALLED BY %d: %s' % (len(c), ', '.join('%08x' % x for x in sorted(c)[:6]) + (' ...' if len(c) > 6 else '')))
        if b: parts.append('BRANCH FROM %d: %s' % (len(b), ', '.join('%08x' % x for x in sorted(b)[:6]) + (' ...' if len(b) > 6 else '')))
        if d: parts.append('DATA REF %d: %s' % (len(d), ', '.join('%08x' % x for x in sorted(d)[:6]) + (' ...' if len(d) > 6 else '')))
        return ' ; '.join(parts) or 'no xrefs'

    def _emit_data(self, fh, a, hi):
        img = self.img
        nm = self.names.get(a)
        xr_d = self.d.xref_data.get(a, ())
        # ---- NUL-terminated string ----
        if a in self.strs:
            b = self.strs[a]
            if nm or xr_d:
                fh.write('%s:   ; %s\n' % (nm or 'aStr_%08x' % a, self._xrefline((), (), xr_d)))
            s = b.decode('latin1').replace('\\','\\\\').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t')
            fh.write('%08x  .asciiz  "%s"\n' % (a, s))
            a += len(b) + 1
            # absorb NUL padding up to the next word boundary so that the
            # word stream stays aligned (strings themselves are packed)
            pad = 0
            while a % 4 and a < hi and img.u8(a) == 0 and a not in self.strs:
                a += 1; pad += 1
            if pad: fh.write('          .align   4                              ; %d pad byte(s)\n' % pad)
            return a
        # ---- unaligned bytes: emit as .byte until aligned ----
        if a % 4:
            n = min(4 - (a % 4), hi - a)
            bs = img.data[a-img.base:a-img.base+n]
            fh.write('%08x  .byte    %s\n' % (a, ', '.join('0x%02x' % c for c in bs)))
            return a + n
        # ---- word data ----
        if nm or xr_d:
            fh.write('%s:   ; %s\n' % (nm or 'dat_%08x' % a, self._xrefline((), (), xr_d)))
        n = 0
        start = a
        while a < hi and a not in self.d.code and a not in self.strs and n < 4:
            if a != start and (self.names.get(a) or self.d.xref_data.get(a)): break
            w = img.w32(a)
            if w is None: break
            extra = ''
            t = norm(w)
            if img.inside(t):
                if t in self.strs: extra = '  ; %s' % self.strpreview(t)
                elif t in self.names: extra = '  ; -> %s' % self.names[t]
            else:
                hw = lookup(w)
                if hw and w >= 0x1f000000: extra = '  ; -> %s' % hw[0]
            asc = ''.join(chr(c) if 32 <= c < 127 else '.' for c in img.data[a-img.base:a-img.base+4])
            fh.write('%08x  .word    0x%08x                        ; |%s|%s\n' % (a, w, asc, extra))
            a += 4; n += 1
        return a if a > start else start + 4
