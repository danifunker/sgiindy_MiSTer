"""census.py IMAGE... - every load/store whose base is (or plausibly is) the
REX3 register window, per binary. Writes usage/out/<image>.pkl with all the
accesses and the per-(function, base-root) group verdicts."""
import sys
import pickle
import time
from collections import defaultdict, Counter
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from binload import all_images
from mipsflow import Func, Ctx, partition, split, fmt, REGN, SP_, GP_

REX3 = {0x000: "DRAWMODE1", 0x004: "DRAWMODE0", 0x008: "LSMODE", 0x00C: "LSPATTERN",
        0x010: "LSPATSAVE", 0x014: "ZPATTERN", 0x018: "COLORBACK", 0x01C: "COLORVRAM",
        0x020: "ALPHAREF", 0x024: "STALL0", 0x028: "SMASK0X", 0x02C: "SMASK0Y",
        0x030: "SETUP", 0x034: "STEPZ", 0x038: "LSRESTORE", 0x03C: "LSSAVE",
        0x100: "XSTART", 0x104: "YSTART", 0x108: "XEND", 0x10C: "YEND",
        0x110: "XSAVE", 0x114: "XYMOVE", 0x118: "BRESD", 0x11C: "BRESS1",
        0x120: "BRESOCTINC1", 0x124: "BRESRNDINC2", 0x128: "BRESE1", 0x12C: "BRESS2",
        0x130: "AWEIGHT0", 0x134: "AWEIGHT1", 0x138: "XSTARTF", 0x13C: "YSTARTF",
        0x140: "XENDF", 0x144: "YENDF", 0x148: "XSTARTI", 0x14C: "XENDF1",
        0x150: "XYSTARTI", 0x154: "XYENDI", 0x158: "XSTARTENDI",
        0x200: "COLORRED", 0x204: "COLORALPHA", 0x208: "COLORGREEN", 0x20C: "COLORBLUE",
        0x210: "SLOPERED", 0x214: "SLOPEALPHA", 0x218: "SLOPEGREEN", 0x21C: "SLOPEBLUE",
        0x220: "WRMASK", 0x224: "COLORI", 0x228: "COLORX", 0x22C: "SLOPERED1",
        0x230: "HOSTRW0", 0x234: "HOSTRW1", 0x238: "DCBMODE", 0x240: "DCBDATA0",
        0x244: "DCBDATA1",
        0x1300: "SMASK1X", 0x1304: "SMASK1Y", 0x1308: "SMASK2X", 0x130C: "SMASK2Y",
        0x1310: "SMASK3X", 0x1314: "SMASK3Y", 0x1318: "SMASK4X", 0x131C: "SMASK4Y",
        0x1320: "TOPSCAN", 0x1324: "XYWIN", 0x1328: "CLIPMODE", 0x132C: "STALL1",
        0x1330: "CONFIG", 0x1338: "STATUS", 0x133C: "USER_STATUS", 0x1340: "DCBRESET"}
WINDOWS = (0x1F0F0000, 0x1F4F0000, 0x1F8F0000, 0x1FCF0000)


def regname(o, width=4):
    """offset within the 8 KB window (+ access width) -> (name, go) or None.
    Sub-word accesses name the containing register; 8-byte ones the first."""
    if not 0 <= o < 0x2000:
        return None
    if width == 8:
        if o & 7:
            return None
    elif width in (1, 2):
        if o & (width - 1):
            return None
    elif o & 3:
        return None
    w = o & ~3
    if w in REX3 and w >= 0x1000:
        return REX3[w], False
    if w < 0x1000 and (w & ~0x800) in REX3 and (w & ~0x800) < 0x1000:
        return REX3[w & ~0x800], bool(w & 0x800)
    return None


def bank(o):
    w = o & ~3
    if w >= 0x1000:
        return "P"
    if w & 0x800:
        return "G"
    w &= 0x7FF
    if w < 0x100:
        return "A"
    if w < 0x200:
        return "B"
    if w >= 0x238:
        return "D"
    return "C"


def strength(offw):
    """offw: set of (offset, width[, is_store]). -> verdict string.
    'no'  : some access is not a REX3 register, or reads a GO alias of
            anything but HOSTRW0/1 (nothing reads DRAWMODE0|GO)
    'odd' : a sub-word access to a register other than DCBDATA0/1"""
    bad = set()
    odd = set()
    offs = set()
    for t in offw:
        o, w = t[0], t[1]
        st = t[2] if len(t) > 2 else True
        r = regname(o, w)
        if r is None:
            bad.add(o)
            continue
        if r[1] and not st and r[0] not in ("HOSTRW0", "HOSTRW1"):
            bad.add(o)
        if w in (1, 2) and r[0] not in ("DCBDATA0", "DCBDATA1"):
            odd.add(o)
        offs.add(o & ~3)
    if bad:
        return "no"
    banks = {bank(o) for o in offs}
    n = len(offs)
    v = "small"
    if "G" in banks and n >= 2:
        v = "strong"
    elif "P" in banks and (n >= 3 or (n >= 2 and banks - {"P"})):
        v = "strong"
    elif "D" in banks and n >= 2:
        v = "strong"
    elif len(banks & {"A", "B", "C"}) >= 2 and n >= 3:
        v = "strong"
    elif banks & {"G", "P", "D", "B", "C"}:
        v = "weak"
    if odd:
        return "odd"
    return v


def abs_rex(a):
    """absolute address -> window offset if inside a REX3 window"""
    if (a >> 29) not in (0, 4, 5):
        return None
    p = a & 0x1FFFFFFF
    for w in WINDOWS:
        if w <= p < w + 0x2000:
            return p - w
    return None


def rootkey(r):
    return r


def is_global(x):
    t = x[0]
    if t in ("e", "?", "ret", "clob", "phi"):
        return False
    if t in ("c", "g"):
        return True
    return all(is_global(y) for y in x[1:] if isinstance(y, tuple))


def run(key):
    img = all_images()[key]()
    ctx = Ctx()
    from mipsflow import heuristic_starts
    extra = heuristic_starts(img) if key in ("prom", "xsgi") else ()
    fl = partition(img, extra)
    names = lambda a: img.dsyms.get(a)
    acc = []         # dicts
    calls = []
    t0 = time.time()
    nfun = 0
    for lo, hi, nm in fl:
        if hi - lo < 4:
            continue
        # quick filter: any load/store with a non-sp base?
        try:
            f = Func(img, lo, hi, nm, ctx)
        except Exception as e:  # noqa
            print("  !! %s %s: %s" % (nm, hex(lo), e))
            continue
        nfun += 1
        for k, i in enumerate(f.ins):
            if i.kind not in ("load", "store") or i.rs == SP_:
                continue
            base = f.operand(k, i.rs)
            alts = split(base)
            for root, off in alts:
                off = (off + i.simm) & 0xFFFFFFFF
                a = dict(fn=nm, flo=lo, pc=i.pc, k=k, mn=i.mn, width=i.width,
                         st=i.kind == "store", fpr=i.fpr, rt=i.rt, rs=i.rs,
                         root=root, off=off, nalts=len(alts), txt=i.text())
                if root == ("c", 0):
                    wo = abs_rex(off)
                    if wo is None:
                        continue
                    a["wo"] = wo
                    a["abs"] = True
                else:
                    so = off - (1 << 32) if off & 0x80000000 else off
                    a["wo"] = so
                    a["abs"] = False
                if a["st"] and not i.fpr:
                    a["val"] = f.operand(k, i.rt)
                acc.append(a)
        for kc, tgt in f.calls():
            args = {}
            for r in (4, 5, 6, 7):
                v = f.arg_at_call(kc, r)
                args[r] = split(v)
            calls.append(dict(flo=lo, fn=nm, pc=f.ins[kc].pc, tgt=tgt, args=args))
    print("%s: %d functions, %d candidate accesses, %.0fs" % (img.name, nfun, len(acc), time.time() - t0))
    # group by (function, root)
    groups = defaultdict(list)
    for j, a in enumerate(acc):
        groups[(a["flo"], a["root"])].append(j)
    verdict = {}
    for g, js in groups.items():
        if acc[js[0]]["abs"]:
            verdict[g] = "abs"
            continue
        verdict[g] = strength({(acc[j]["wo"], acc[j]["width"]) for j in js})
    # roots proven elsewhere: global roots anywhere; argument-derived roots
    # only within the same source file (same struct types)
    src = img.srcfile
    proven = defaultdict(set)
    for g, v in verdict.items():
        if v in ("strong", "abs"):
            proven[None if is_global(g[1]) else src.get(g[0], g[0])].add(g[1])
    for g, v in list(verdict.items()):
        if v in ("weak", "small"):
            if g[1] in proven[None] or g[1] in proven[src.get(g[0], g[0])]:
                verdict[g] = "shape"
    out = dict(img=img.name, acc=acc, calls=calls, groups=dict(groups), verdict=verdict,
               funcs=fl, srcfile=img.srcfile, dsyms=img.dsyms, gp=img.gp)
    pickle.dump(out, open(__file__.rsplit("\\", 1)[0].rsplit("/", 1)[0] + "/out/%s.pkl" % key, "wb"))
    c = Counter(verdict.values())
    print("   groups:", dict(c))


if __name__ == "__main__":
    import os
    os.makedirs(__file__.rsplit("\\", 1)[0].rsplit("/", 1)[0] + "/out", exist_ok=True)
    for key in sys.argv[1:]:
        run(key)
