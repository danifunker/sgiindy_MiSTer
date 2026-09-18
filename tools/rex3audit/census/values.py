"""values.py KEY REG[,REG] [--const] - every store to the named REX3 registers
with the stored value (symbolic; constants decoded)."""
import sys
import pickle
from collections import Counter, defaultdict
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from mipsflow import fmt
from rexdecode import DECODE

HERE = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]


def consts_in(x, out):
    """collect ('op', const) pairs appearing in a value expression"""
    if not isinstance(x, tuple):
        return
    t = x[0]
    if t == "c":
        out.append(("=", x[1]))
        return
    if t in ("|", "&", "^", "+", "<<", ">>", ">>a") and len(x) == 3:
        a, b = x[1], x[2]
        if isinstance(b, tuple) and b[0] == "c":
            out.append((t, b[1]))
            consts_in(a, out)
            return
        if isinstance(b, int):
            out.append((t, b))
            consts_in(a, out)
            return
    if t == "phi":
        for y in x[1]:
            consts_in(y, out)
        return
    for y in x[1:]:
        consts_in(y, out)


def values(key, regs, only_const=False):
    R = pickle.load(open(HERE + "/out/%s.rex.pkl" % key, "rb"))
    names = lambda a: R["dsyms"].get(a)
    for reg in regs:
        rows = []
        for a in R["rex"]:
            if a["reg"] != reg or not a["st"]:
                continue
            v = a.get("val")
            if v is None:
                txt = "(FPR %s)" % a["mn"]
            elif v[0] == "c":
                d = DECODE.get(reg)
                txt = "0x%08x  %s" % (v[1], d(v[1]) if d else "")
            else:
                if only_const:
                    continue
                txt = fmt(v, names)[:150]
            rows.append((a["fn"], a["pc"], ("GO " if a["go"] else "") + a["mn"], txt))
        print("=== %s %s: %d stores" % (R["img"], reg, len(rows)))
        for r in sorted(rows, key=lambda r: r[1]):
            print("  %-30s %08x %-7s %s" % (r[0][:30], r[1], r[2], r[3]))


if __name__ == "__main__":
    values(sys.argv[1], sys.argv[2].split(","), "--const" in sys.argv)
