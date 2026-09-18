"""mipsflow.py - a small MIPS III decoder, per-function CFG, reaching
definitions (GPRs + $sp stack slots) and symbolic values, enough to name the
base register of every load/store as an expression such as
    ld(e.a0 + 0x60)          "the word at offset 0x60 of the first argument"
    g(0x881bddb8)            "the global variable at that address"
    c(0xbf0f0000)            "a constant"
"""
import struct
from bisect import bisect_right

REGN = ["zero", "at", "v0", "v1", "a0", "a1", "a2", "a3", "t0", "t1", "t2", "t3",
        "t4", "t5", "t6", "t7", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
        "t8", "t9", "k0", "k1", "gp", "sp", "s8", "ra"]
SP_, GP_, RA_ = 29, 28, 31
CLOBBER = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 24, 25, 31]
MUL, CLB = 4096, 2048

LOADS = {0x20: ("lb", 1), 0x21: ("lh", 2), 0x22: ("lwl", 4), 0x23: ("lw", 4),
         0x24: ("lbu", 1), 0x25: ("lhu", 2), 0x26: ("lwr", 4), 0x27: ("lwu", 4),
         0x1A: ("ldl", 8), 0x1B: ("ldr", 8), 0x37: ("ld", 8), 0x30: ("ll", 4),
         0x34: ("lld", 8)}
FLOADS = {0x31: ("lwc1", 4), 0x35: ("ldc1", 8), 0x32: ("lwc2", 4), 0x36: ("ldc2", 8)}
STORES = {0x28: ("sb", 1), 0x29: ("sh", 2), 0x2A: ("swl", 4), 0x2B: ("sw", 4),
          0x2C: ("sdl", 8), 0x2D: ("sdr", 8), 0x2E: ("swr", 4), 0x3F: ("sd", 8),
          0x38: ("sc", 4), 0x3C: ("scd", 8)}
FSTORES = {0x39: ("swc1", 4), 0x3D: ("sdc1", 8), 0x3A: ("swc2", 4), 0x3E: ("sdc2", 8)}


class I:
    __slots__ = ("pc", "w", "op", "rs", "rt", "rd", "sa", "fn", "imm", "simm",
                 "kind", "defs", "mn", "width", "target", "likely", "cond",
                 "link", "fpr")

    def __init__(self, pc, w):
        self.pc, self.w = pc, w
        self.op = w >> 26
        self.rs = (w >> 21) & 31
        self.rt = (w >> 16) & 31
        self.rd = (w >> 11) & 31
        self.sa = (w >> 6) & 31
        self.fn = w & 63
        self.imm = w & 0xFFFF
        self.simm = self.imm - 0x10000 if self.imm & 0x8000 else self.imm
        self.kind = "other"
        self.defs = ()
        self.mn = "?"
        self.width = 0
        self.target = None
        self.likely = False
        self.cond = False
        self.link = False
        self.fpr = False
        self._decode()

    def _br(self, likely, cond=True, link=False):
        self.kind = "branch"
        self.target = (self.pc + 4 + (self.simm << 2)) & 0xFFFFFFFF
        if self.op == 4 and self.rs == 0 and self.rt == 0:
            cond = False                          # b
        if self.op == 1 and self.rs == 0 and self.rt in (1, 0x11):
            cond = False                          # bgez $0 / bal
        self.likely, self.cond, self.link = likely, cond, link
        if link:
            self.defs = (RA_,)

    def _decode(self):
        op, rs, rt, rd, fn = self.op, self.rs, self.rt, self.rd, self.fn
        if op == 0:
            if fn == 8:
                self.kind, self.mn = "jr", "jr"
            elif fn == 9:
                self.kind, self.mn, self.link = "jalr", "jalr", True
                self.defs = (rd,)
            elif fn in (0x0C, 0x0D, 0x0F) or 0x18 <= fn <= 0x1F or 0x30 <= fn <= 0x36 \
                    or fn in (0x11, 0x13):
                self.kind = "other"
                self.mn = {0x0C: "syscall", 0x0D: "break", 0x0F: "sync"}.get(fn, "muldiv")
            else:
                self.kind = "r"
                self.mn = {0x00: "sll", 0x02: "srl", 0x03: "sra", 0x04: "sllv", 0x06: "srlv",
                           0x07: "srav", 0x10: "mfhi", 0x12: "mflo", 0x20: "add", 0x21: "addu",
                           0x22: "sub", 0x23: "subu", 0x24: "and", 0x25: "or", 0x26: "xor",
                           0x27: "nor", 0x2A: "slt", 0x2B: "sltu", 0x2C: "dadd", 0x2D: "daddu",
                           0x2E: "dsub", 0x2F: "dsubu", 0x38: "dsll", 0x3A: "dsrl", 0x3B: "dsra",
                           0x3C: "dsll32", 0x3E: "dsrl32", 0x3F: "dsra32", 0x14: "dsllv",
                           0x16: "dsrlv", 0x17: "dsrav"}.get(fn, "r%02x" % fn)
                self.defs = (rd,) if rd else ()
        elif op == 1:
            if rt in (0, 1, 2, 3, 0x10, 0x11, 0x12, 0x13):
                self._br(likely=rt in (2, 3, 0x12, 0x13), link=rt >= 0x10)
                self.mn = {0: "bltz", 1: "bgez", 2: "bltzl", 3: "bgezl", 0x10: "bltzal",
                           0x11: "bgezal", 0x12: "bltzall", 0x13: "bgezall"}[rt]
            else:
                self.mn = "trap"
        elif op in (2, 3):
            self.kind = "jump"
            self.target = ((self.pc + 4) & 0xF0000000) | ((self.w & 0x3FFFFFF) << 2)
            self.link = op == 3
            self.mn = "jal" if op == 3 else "j"
            if op == 3:
                self.defs = (RA_,)
        elif op in (4, 5, 6, 7, 0x14, 0x15, 0x16, 0x17):
            self._br(likely=op >= 0x14)
            self.mn = {4: "beq", 5: "bne", 6: "blez", 7: "bgtz", 0x14: "beql", 0x15: "bnel",
                       0x16: "blezl", 0x17: "bgtzl"}[op]
        elif 8 <= op <= 0x0F or op in (0x18, 0x19):
            self.kind = "imm"
            self.mn = {8: "addi", 9: "addiu", 0xA: "slti", 0xB: "sltiu", 0xC: "andi",
                       0xD: "ori", 0xE: "xori", 0xF: "lui", 0x18: "daddi", 0x19: "daddiu"}[op]
            self.defs = (rt,) if rt else ()
        elif 0x10 <= op <= 0x13:
            if rs in (0, 1, 2):
                self.kind, self.mn = "mfc", "mfc%d" % (op & 3)
                self.defs = (rt,) if rt else ()
            elif rs == 8:
                self._br(likely=rt in (2, 3))
                self.mn = "bc%d%s" % (op & 3, ["f", "t", "fl", "tl"][rt & 3])
            else:
                self.kind, self.mn = "cop", "cop%d" % (op & 3)
        elif op in LOADS:
            self.kind = "load"
            self.mn, self.width = LOADS[op]
            self.defs = (rt,) if rt else ()
        elif op in FLOADS:
            self.kind, self.fpr = "load", True
            self.mn, self.width = FLOADS[op]
        elif op in STORES:
            self.kind = "store"
            self.mn, self.width = STORES[op]
            if op in (0x38, 0x3C) and rt:
                self.defs = (rt,)
        elif op in FSTORES:
            self.kind, self.fpr = "store", True
            self.mn, self.width = FSTORES[op]
        elif op in (0x2F, 0x33):
            self.mn = "cache" if op == 0x2F else "pref"

    def is_cti(self):
        return self.kind in ("branch", "jump", "jr", "jalr")

    def text(self):
        k = self.kind
        if k in ("load", "store"):
            r = ("$f%d" % self.rt) if self.fpr else "$" + REGN[self.rt]
            return "%s %s, %s($%s)" % (self.mn, r, hex(self.simm) if self.simm >= 0 else "-" + hex(-self.simm), REGN[self.rs])
        if k == "imm":
            if self.mn == "lui":
                return "lui $%s, 0x%x" % (REGN[self.rt], self.imm)
            v = self.simm if self.mn in ("addi", "addiu", "slti", "sltiu", "daddi", "daddiu") else self.imm
            return "%s $%s, $%s, %s" % (self.mn, REGN[self.rt], REGN[self.rs], hex(v))
        if k == "r":
            if self.mn in ("sll", "srl", "sra", "dsll", "dsrl", "dsra", "dsll32", "dsrl32", "dsra32"):
                return "%s $%s, $%s, %d" % (self.mn, REGN[self.rd], REGN[self.rt], self.sa)
            if self.mn in ("mfhi", "mflo"):
                return "%s $%s" % (self.mn, REGN[self.rd])
            return "%s $%s, $%s, $%s" % (self.mn, REGN[self.rd], REGN[self.rs], REGN[self.rt])
        if k in ("branch", "jump"):
            return "%s 0x%08x" % (self.mn, self.target)
        if k == "jr":
            return "jr $%s" % REGN[self.rs]
        if k == "jalr":
            return "jalr $%s" % REGN[self.rs]
        if k == "mfc":
            return "%s $%s, $%d" % (self.mn, REGN[self.rt], self.rd)
        return self.mn


# ---------------------------------------------------------------- expressions
def C(v):
    return ("c", v & 0xFFFFFFFF)


def depth(x):
    if x[0] in ("c", "e", "g", "?", "ret", "clob"):
        return 1
    if x[0] == "phi":
        return 1 + max(depth(y) for y in x[1])
    return 1 + max(depth(y) for y in x[1:] if isinstance(y, tuple))


def add(x, k):
    k &= 0xFFFFFFFF
    if k == 0:
        return x
    if x[0] == "c":
        return C(x[1] + k)
    if x[0] == "+":
        s = (x[2] + k) & 0xFFFFFFFF
        return x[1] if s == 0 else ("+", x[1], s)
    return ("+", x, k)


def split(x):
    """-> list of (root, offset) alternatives; root ('c',0) means absolute."""
    if x[0] == "phi":
        out = []
        for y in x[1]:
            out.extend(split(y))
        return out
    if x[0] == "c":
        return [(("c", 0), x[1])]
    if x[0] == "+":
        return [(x[1], x[2])]
    if x[0] == "|" and x[2][0] == "c" and x[1][0] != "c":
        return [(x[1], x[2][1])]
    return [(x, 0)]


def sgn(k):
    return k - (1 << 32) if k & 0x80000000 else k


def fmt(x, names=None):
    t = x[0]
    if t == "c":
        n = names(x[1]) if names else None
        return ("0x%x" % x[1]) + ("<%s>" % n if n else "")
    if t == "e":
        return "e.%s" % (REGN[x[1]] if x[1] < 32 else "stk%x" % (x[1] - 32))
    if t == "g":
        n = names(x[1]) if names else None
        return "g(0x%x%s)" % (x[1], ":" + n if n else "")
    if t == "+":
        k = sgn(x[2])
        return "%s%s0x%x" % (fmt(x[1], names), "+" if k >= 0 else "-", abs(k))
    if t == "ld":
        k = sgn(x[2])
        return "ld%s(%s%s)" % ("" if x[3] == "lw" else "." + x[3], fmt(x[1], names),
                               ("+0x%x" % k if k > 0 else "-0x%x" % -k) if k else "")
    if t == "ret":
        return "ret@%x" % x[1]
    if t == "clob":
        return "clob@%x.%s" % (x[1], REGN[x[2]] if len(x) > 2 and x[2] < 32 else "?")
    if t == "?":
        return "?@%x" % x[1]
    if t == "phi":
        return "phi{" + ", ".join(sorted(fmt(y, names) for y in x[1])) + "}"
    return "(%s %s %s)" % (fmt(x[1], names), t, fmt(x[2], names) if isinstance(x[2], tuple) else x[2])


# ---------------------------------------------------------------- functions
class Func:
    def __init__(self, img, lo, hi, name, ctx):
        self.img, self.lo, self.hi, self.name, self.ctx = img, lo, hi, name, ctx
        raw = img.read(lo, hi - lo)
        n = len(raw) // 4
        self.ins = [I(lo + 4 * k, w) for k, w in enumerate(struct.unpack(">%dI" % n, raw[:4 * n]))]
        self.n = n
        self._slots()
        self._cfg()
        self._dataflow()
        self.memo = {}
        self.busy = set()

    # stack slots: sp-relative word accesses become pseudo registers 32+k
    def _slots(self):
        offs = sorted({i.simm for i in self.ins if i.kind in ("load", "store") and
                       i.rs == SP_ and not i.fpr and i.width in (4, 8)})
        self.slot = {o: 32 + k for k, o in enumerate(offs)}
        self.nloc = 32 + len(offs)

    def defs_of(self, k):
        i = self.ins[k]
        d = list(i.defs)
        if i.kind == "store" and i.rs == SP_ and not i.fpr and i.simm in self.slot:
            d.append(self.slot[i.simm])
        return d

    def _cfg(self):
        n, ins = self.n, self.ins
        succ = [[] for _ in range(n)]
        self.indirect = False
        callret = set()          # instruction index after which a call's clobber applies
        for k, i in enumerate(ins):
            if i.is_cti() and k + 1 < n:
                ds = k + 1
                tk = None
                if i.target is not None and self.lo <= i.target < self.hi:
                    tk = (i.target - self.lo) // 4
                if i.kind == "branch" and not i.link:
                    if i.likely:
                        succ[k] = [ds] + ([k + 2] if k + 2 < n else [])
                        succ[ds] = [tk] if tk is not None else []
                    else:
                        succ[k] = [ds]
                        s = []
                        if tk is not None:
                            s.append(tk)
                        if i.cond and k + 2 < n:
                            s.append(k + 2)
                        succ[ds] = s
                elif i.kind == "jump" and not i.link:        # j
                    succ[k] = [ds]
                    succ[ds] = [tk] if tk is not None else []
                elif i.link:                                 # jal, jalr, bal
                    succ[k] = [ds]
                    succ[ds] = [k + 2] if k + 2 < n else []
                    callret.add(ds)
                elif i.kind == "jr":
                    succ[k] = [ds]
                    succ[ds] = []
                    if i.rs != RA_:
                        self.indirect = True
            elif not succ[k] and k + 1 < n and not (k > 0 and ins[k - 1].is_cti()):
                succ[k] = [k + 1]
            elif k > 0 and ins[k - 1].is_cti():
                pass                  # delay slot: set above
        self.callret = callret
        preds = [[] for _ in range(n)]
        for k in range(n):
            for s in succ[k]:
                preds[s].append(k)
        # leaders
        lead = [False] * n
        if n:
            lead[0] = True
        for k in range(n):
            if len(succ[k]) != 1:
                for s in succ[k]:
                    lead[s] = True
                if k + 1 < n:
                    lead[k + 1] = True
            if len(preds[k]) != 1:
                lead[k] = True
            elif preds[k][0] != k - 1:
                lead[k] = True
            if k in callret and k + 1 < n:
                lead[k + 1] = True
        starts = [k for k in range(n) if lead[k]]
        self.bstart = starts
        self.bof = [0] * n
        blocks = []
        for b, s in enumerate(starts):
            e = starts[b + 1] if b + 1 < len(starts) else n
            blocks.append((s, e))
            for k in range(s, e):
                self.bof[k] = b
        self.blocks = blocks
        self.bsucc = [sorted({self.bof[t] for t in succ[e - 1]}) if e > s else [] for s, e in blocks]
        self.bpred = [[] for _ in blocks]
        for b, ss in enumerate(self.bsucc):
            for t in ss:
                self.bpred[t].append(b)
        # blocks nobody reaches: switch targets if the function has an indirect
        # jump (edge from every indirect-jump block), otherwise extra entries
        self.entries = {0}
        jrblocks = [b for b, (s, e) in enumerate(blocks)
                    if any(self.ins[k].kind == "jr" and self.ins[k].rs != RA_ for k in range(s, e))]
        for b in range(len(blocks)):
            if b and not self.bpred[b]:
                if jrblocks:
                    for j in jrblocks:
                        self.bsucc[j].append(b)
                        self.bpred[b].append(j)
                else:
                    self.entries.add(b)

    def _dataflow(self):
        nloc = self.nloc
        entry = tuple(frozenset([-(l + 1)]) for l in range(nloc))
        empty = tuple(frozenset() for _ in range(nloc))
        # per block transfer: last def per loc
        gen = []
        for s, e in self.blocks:
            g = {}
            for k in range(s, e):
                for l in self.defs_of(k):
                    g[l] = frozenset([k * MUL + l])
                if k in self.callret:
                    for l in CLOBBER:
                        g[l] = frozenset([k * MUL + CLB + l])
            gen.append(g)
        nb = len(self.blocks)
        IN = [empty] * nb
        OUT = [None] * nb
        for b in self.entries:
            IN[b] = entry
        work = list(range(nb))
        inwork = set(work)
        while work:
            b = work.pop()
            inwork.discard(b)
            if b in self.entries and b != 0:
                st = entry
            else:
                st = IN[b]
                if self.bpred[b]:
                    acc = [set() for _ in range(nloc)]
                    for p in self.bpred[b]:
                        if OUT[p] is None:
                            continue
                        for l in range(nloc):
                            acc[l] |= OUT[p][l]
                    if b == 0:
                        for l in range(nloc):
                            acc[l] |= entry[l]
                    st = tuple(frozenset(a) for a in acc)
                elif b == 0:
                    st = entry
            IN[b] = st
            o = list(st)
            for l, dd in gen[b].items():
                o[l] = dd
            o = tuple(o)
            if o != OUT[b]:
                OUT[b] = o
                for t in self.bsucc[b]:
                    if t not in inwork:
                        work.append(t)
                        inwork.add(t)
        self.IN = IN
        self._cache_b = None

    def reach(self, k, loc):
        """reaching defs of loc just before instruction k"""
        b = self.bof[k]
        s, e = self.blocks[b]
        cur = self.IN[b][loc]
        for j in range(s, k):
            if loc in self.defs_of(j):
                cur = frozenset([j * MUL + loc])
            if j in self.callret and loc in CLOBBER:
                cur = frozenset([j * MUL + CLB + loc])
        return cur

    def arg_at_call(self, kc, loc):
        """value of loc as the callee sees it: call at kc, delay slot kc+1"""
        ds = kc + 1
        if ds >= self.n:
            return ("?", self.ins[kc].pc)
        if loc in self.defs_of(ds):
            return self.val(ds * MUL + loc)
        return self.operand(ds, loc)

    def calls(self):
        """[(k, target or None)] for jal / jalr / bal"""
        out = []
        for k, i in enumerate(self.ins):
            if i.kind == "jump" and i.link:
                out.append((k, i.target))
            elif i.kind == "jalr":
                t = self.operand(k, i.rs)
                out.append((k, t[1] if t[0] == "c" else None))
            elif i.kind == "branch" and i.link:
                out.append((k, i.target))
        return out

    # ------------------------------------------------------------ values
    def operand(self, k, loc):
        if loc == 0:
            return C(0)
        if loc == GP_ and self.img.gp is not None:
            return C(self.img.gp)
        ds = self.reach(k, loc)
        vals = set()
        for d in ds:
            vals.add(self.val(d))
            if len(vals) > 6:
                return ("?", self.ins[k].pc)
        if not vals:
            return ("?", self.ins[k].pc)
        if len(vals) == 1:
            return vals.pop()
        return ("phi", frozenset(vals))

    def val(self, d):
        if d < 0:
            loc = -d - 1
            if loc == 25 and self.img.pic:         # t9 = own address at entry (PIC)
                return C(self.lo)
            return ("e", loc)
        if d in self.memo:
            return self.memo[d]
        if d in self.busy:
            return ("?", self.ins[d // MUL].pc)
        self.busy.add(d)
        try:
            if d % MUL >= CLB:
                k, loc = d // MUL, d % MUL - CLB
                v = ("ret", self.ins[k - 1].pc) if loc == 2 else ("clob", self.ins[k - 1].pc, loc)
            else:
                v = self._val(d // MUL, d % MUL)
            if depth(v) > 10:
                v = ("?", self.ins[d // MUL].pc)
        finally:
            self.busy.discard(d)
        self.memo[d] = v
        return v

    def _val(self, k, loc):
        i = self.ins[k]
        if loc >= 32:                      # stack slot store
            return self.operand(k, i.rt)
        if loc == GP_ and self.img.gp is not None:
            return C(self.img.gp)
        m = i.mn
        if i.kind == "imm":
            if m == "lui":
                return C(i.imm << 16)
            a = self.operand(k, i.rs)
            if m in ("addi", "addiu", "daddi", "daddiu"):
                return add(a, i.simm)
            if m == "ori":
                if a[0] == "c":
                    return C(a[1] | i.imm)
                return ("|", a, C(i.imm))
            if m == "andi":
                if a[0] == "c":
                    return C(a[1] & i.imm)
                return ("&", a, C(i.imm))
            if m == "xori":
                if a[0] == "c":
                    return C(a[1] ^ i.imm)
                return ("^", a, C(i.imm))
            return ("slt", a, C(i.simm))
        if i.kind == "r":
            if m in ("mfhi", "mflo"):
                return ("?", i.pc)
            if m in ("sll", "srl", "sra", "dsll", "dsrl", "dsra", "dsll32", "dsrl32", "dsra32"):
                a = self.operand(k, i.rt)
                sh = i.sa + (32 if m.endswith("32") else 0)
                if a[0] == "c":
                    if m in ("sll", "dsll"):
                        return C(a[1] << sh)
                    if m in ("srl", "dsrl"):
                        return C(a[1] >> sh)
                    return C(sgn(a[1]) >> sh)
                if sh == 0:
                    return a
                return ({"sll": "<<", "dsll": "<<", "srl": ">>", "dsrl": ">>"}.get(m, ">>a"), a, C(sh))
            a = self.operand(k, i.rs)
            b = self.operand(k, i.rt)
            if m in ("addu", "add", "daddu", "dadd", "or"):
                if i.rt == 0:
                    return a
                if i.rs == 0:
                    return b
                if a[0] == "c" and b[0] == "c":
                    return C(a[1] + b[1]) if m != "or" else C(a[1] | b[1])
                if m != "or":
                    if b[0] == "c":
                        return add(a, b[1])
                    if a[0] == "c":
                        return add(b, a[1])
                    return ("+r", a, b)
                return ("|", a, b) if b[0] == "c" or a[0] != "c" else ("|", b, a)
            if m in ("subu", "sub", "dsubu", "dsub"):
                if b[0] == "c":
                    return add(a, -b[1])
                return ("-", a, b)
            if m == "and":
                if a[0] == "c" and b[0] == "c":
                    return C(a[1] & b[1])
                return ("&", a, b)
            if m == "xor":
                if a[0] == "c" and b[0] == "c":
                    return C(a[1] ^ b[1])
                return ("^", a, b)
            if m == "nor":
                if a[0] == "c" and b[0] == "c":
                    return C(~(a[1] | b[1]))
                return ("nor", a, b)
            if m in ("sllv", "srlv", "srav", "dsllv", "dsrlv", "dsrav"):
                return ({"sllv": "<<", "dsllv": "<<", "srlv": ">>", "dsrlv": ">>"}.get(m, ">>a"), b, a)
            return ("slt", a, b)
        if i.kind == "load":
            if i.rs == SP_ and i.simm in self.slot and i.width in (4, 8):
                return self.operand(k, self.slot[i.simm])
            base = self.operand(k, i.rs)
            alts = split(add(base, i.simm))
            if len(alts) == 1:
                r, off = alts[0]
                if r == ("c", 0):
                    return self.ctx.const_load(self.img, off, i.mn)
                return ("ld", r, off, i.mn)
            return ("?", i.pc)
        if i.kind == "store":                   # sc/scd rt
            return ("?", i.pc)
        if i.kind in ("jump", "branch", "jalr"):
            return ("?", i.pc)                  # ra
        return ("?", i.pc)


class Ctx:
    def const_load(self, img, addr, mn):
        sec = img.secname(addr)
        if sec is not None and mn in ("lw", "ld") and (
                (img.got and img.got[0] <= addr < img.got[1]) or sec in (".rodata", ".rdata", "rom")):
            w = img.word(addr)
            if w is not None:
                return C(w)
        return ("g", addr) if mn == "lw" else ("ld", ("c", addr), 0, mn)


def heuristic_starts(img):
    """function starts for stripped code: the first instruction after
    `jr $ra; <delay>` (zero padding skipped) when it opens a stack frame, and
    code pointers found in data whose target looks like a function entry
    (opens a frame, or follows a `jr $ra; <delay>` + padding) - jump-table
    targets inside a function do neither."""
    out = set()
    words = {}
    for sva, b, code, nm in img.segs:
        if code:
            n = len(b) // 4
            words[sva] = struct.unpack(">%dI" % n, b[:4 * n])

    def at(a):
        for sva, ws in words.items():
            if sva <= a < sva + 4 * len(ws):
                return ws, (a - sva) // 4
        return None, None

    def entry_like(a):
        ws, k = at(a)
        if ws is None:
            return False
        if (ws[k] & 0xFFFF8000) == 0x27BD8000:
            return True
        j = k - 1
        while j >= 0 and ws[j] == 0:
            j -= 1
        return j >= 1 and ws[j - 1] == 0x03E00008 or (j >= 0 and ws[j] == 0x03E00008 and False)

    for sva, ws in words.items():
        n = len(ws)
        for k in range(n):
            if ws[k] >> 16 == 0x3C1C:          # lui $gp: a PIC prologue
                out.add(sva + 4 * k)
        for k in range(n - 2):
            if ws[k] == 0x03E00008:
                j = k + 2
                while j < n and ws[j] == 0:
                    j += 1
                if j < n and (ws[j] & 0xFFFF8000) == 0x27BD8000:
                    out.add(sva + 4 * j)
    for sva, b, code, nm in img.segs:
        if code:
            continue
        n = len(b) // 4
        for w in struct.unpack(">%dI" % n, b[:4 * n]):
            for cand in (w, (w & 0x1FFFFFFF) | 0xA0000000):
                if cand & 3 == 0 and entry_like(cand):
                    out.add(cand)
                    break
    return out


def partition(img, extra_starts=()):
    """function list [(lo, hi, name)] over the code ranges"""
    out = []
    for sva, b in img.code_ranges():
        end = sva + len(b)
        starts = {a for a in img.funcs if sva <= a < end}
        starts |= {a for a in extra_starts if sva <= a < end}
        # jal targets in this range
        n = len(b) // 4
        ws = struct.unpack(">%dI" % n, b[:4 * n])
        for k, w in enumerate(ws):
            if w >> 26 == 3:
                t = (((sva + 4 * k + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
                if sva <= t < end:
                    starts.add(t)
        starts.add(sva)
        st = sorted(starts)
        for j, a in enumerate(st):
            hi = st[j + 1] if j + 1 < len(st) else end
            nm = img.funcs.get(a)
            if nm is None:
                nm = "sub_%08x" % a
            out.append((a, hi, nm))
    return out
