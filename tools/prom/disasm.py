"""SGI IP24 PROM disassembler: recursive descent + linear fill, with
   symbol/string/MMIO annotation and full xref database."""
import sys, struct, json
from collections import defaultdict
sys.path.insert(0, __import__('os').path.dirname(__file__))
from promlib import Image, load_map, sym_kind, norm, BASE
from capstone import *
from capstone.mips import *

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.detail = True

JUMPS   = {'j','b'}
CALLS   = {'jal'}
CONDBR  = {'beq','bne','blez','bgtz','bltz','bgez','bltzal','bgezal','beqz','bnez',
           'bc1t','bc1f','bgezl','bltzl','beql','bnel','blezl','bgtzl'}
RETURNS = {'jr'}

class Dis:
    def __init__(self, img, syms):
        self.img, self.syms = img, syms
        self.insns = {}        # addr -> capstone insn
        self.code  = set()     # addrs known to be code
        self.func  = set()     # function entry points
        self.xref_code = defaultdict(set)   # target -> {sources}  (branch/jump)
        self.xref_call = defaultdict(set)   # target -> {callers}
        self.xref_data = defaultdict(set)   # target -> {referencing insn addrs}
        self.const    = {}     # insn addr -> resolved absolute constant (lui pair)
        self.bad      = set()

    def decode(self, a):
        if a in self.insns: return self.insns[a]
        o = self.img.off(a)
        if o < 0 or o+4 > self.img.size: return None
        try:
            i = next(md.disasm(self.img.data[o:o+4], a))
        except StopIteration:
            self.bad.add(a); return None
        self.insns[a] = i
        return i

    def sweep(self, start):
        """Recursive descent from one entry point."""
        stack, seen = [start], set()
        while stack:
            a = stack.pop()
            while True:
                if a in seen or not self.img.inside(a): break
                seen.add(a); self.code.add(a)
                i = self.decode(a)
                if i is None: break
                m = i.mnemonic
                # delay slot always executes
                nxt = a + 4
                tgt = self.branch_target(i)
                if m in CALLS or m == 'jalr':
                    if tgt is not None and self.img.inside(tgt):
                        self.xref_call[tgt].add(a); self.func.add(tgt)
                        if tgt not in seen: stack.append(tgt)
                    a = nxt; continue
                if m in CONDBR:
                    if tgt is not None and self.img.inside(tgt):
                        self.xref_code[tgt].add(a)
                        if tgt not in seen: stack.append(tgt)
                    a = nxt; continue
                if m in JUMPS:
                    if tgt is not None and self.img.inside(tgt):
                        self.xref_code[tgt].add(a)
                        if tgt not in seen: stack.append(tgt)
                    # unconditional: delay slot then stop
                    self.code.add(nxt); self.decode(nxt); break
                if m in RETURNS or m == 'eret':
                    self.code.add(nxt); self.decode(nxt); break
                a = nxt

    @staticmethod
    def branch_target(i):
        for op in i.operands:
            if op.type == MIPS_OP_IMM:
                return op.imm & 0xffffffff
        return None

    def run(self, scan_prologues=False):
        # entry: reset vector + every mapped function symbol + exception vectors
        entries = [self.img.base]
        # R4000 BEV=1 vector table: 0xbfc00000..0xbfc00400, one 'j' per 8 bytes.
        # Recursive descent stops at each unconditional j, so seed every slot.
        for off in range(0, 0x400, 8):
            entries.append(self.img.base + off)
        for a, names in self.syms.items():
            if self.img.inside(a) and sym_kind(names) in ('func','code'):
                entries.append(a)
                if sym_kind(names) == 'func': self.func.add(a)
        self.func.add(self.img.base)
        for e in sorted(set(entries)):
            self.sweep(e)
        if scan_prologues:
            self.scan_prologues()
        self.resolve_constants()

    def scan_prologues(self, rounds=4):
        """Heuristic entry discovery for images with no symbol map.

        MIPS o32 functions almost always open with 'addiu $sp,$sp,-N'
        (0x27bdffxx). Sweep from every such word that is not already known
        code, then repeat -- newly found functions reveal further callees.
        """
        import struct as _s
        for _ in range(rounds):
            found = 0
            for off in range(0, self.img.size - 4, 4):
                a = self.img.base + off
                if a in self.code: continue
                w = _s.unpack('>I', self.img.data[off:off+4])[0]
                # addiu $sp, $sp, -N  with a sane, 8-aligned frame size
                if (w & 0xffff8007) == 0x27bd8000 and 0x10 <= (0x10000 - (w & 0xffff)) <= 0x400:
                    before = self.code
                    n0 = len(before)
                    self.sweep(a)
                    if len(self.code) > n0:
                        self.func.add(a); found += 1
            if not found: break

    def resolve_constants(self):
        """Track lui/addiu|ori|lw|sw pairs per register to recover absolute addrs."""
        regstate = {}
        for a in sorted(self.code):
            i = self.insns.get(a)
            if i is None: continue
            m, ops = i.mnemonic, i.operands
            if m == 'lui' and len(ops) == 2:
                regstate[ops[0].reg] = ops[1].imm << 16
                continue
            # reg + immediate completion
            if m in ('addiu','ori','addi','daddiu') and len(ops) == 3:
                if ops[1].reg in regstate and ops[1].reg != MIPS_REG_ZERO:
                    hi = regstate[ops[1].reg]
                    v = (hi + ops[2].imm) & 0xffffffff if m in ('addiu','addi','daddiu') \
                        else (hi | (ops[2].imm & 0xffff)) & 0xffffffff
                    v = norm(v)
                    self.const[a] = v
                    regstate[ops[0].reg] = v
                    self.xref_data[v].add(a)
                    continue
            # memory op with base register holding a lui value
            if ops and ops[-1].type == MIPS_OP_MEM:
                mem = ops[-1].mem
                if mem.base in regstate:
                    v = norm((regstate[mem.base] + mem.disp) & 0xffffffff)
                    self.const[a] = v
                    self.xref_data[v].add(a)
            # invalidate clobbered destination
            if ops and ops[0].type == MIPS_OP_REG and m not in ('lui',):
                if m.startswith(('s','b','j')) and m not in ('sll','srl','sra','slt','sltu','slti','sltiu','sub','subu','srlv','srav','sllv'):
                    pass
                else:
                    regstate.pop(ops[0].reg, None)
            if m in ('jal','jalr') or m.startswith('b') or m == 'j':
                regstate.clear()
