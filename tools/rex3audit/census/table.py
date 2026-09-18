"""table.py KEY... - the per-register census table from out/<key>.rex.pkl"""
import sys
import pickle
from collections import defaultdict, Counter
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from census import REX3

HERE = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]
ORDER = {n: o for o, n in REX3.items()}


def table(key, maxfn=6):
    R = pickle.load(open(HERE + "/out/%s.rex.pkl" % key, "rb"))
    rows = defaultdict(Counter)
    fns = defaultdict(Counter)
    for a in R["rex"]:
        w = a["wo"] & ~3 if a["width"] < 8 else a["wo"]
        reg = a["reg"]
        k = ("W " if a["st"] else "R ") + a["mn"] + (" GO" if a["go"] else "")
        if a["width"] in (1, 2):
            k += " +%d" % (a["wo"] & 3)
        if a["width"] == 8:
            nxt = REX3.get((a["wo"] & 0x7FF) + 4 if a["wo"] < 0x1000 else a["wo"] + 4, "?")
            reg = reg + "+" + nxt
        rows[reg][k] += 1
        fns[reg][a["fn"]] += 1
    print("### %s: %d accesses, %d functions" % (R["img"], len(R["rex"]), len({a["flo"] for a in R["rex"]})))
    for reg in sorted(rows, key=lambda r: ORDER.get(r.split("+")[0], 0x9999) + (0.5 if "+" in r else 0)):
        kinds = ", ".join("%s:%d" % (k, n) for k, n in sorted(rows[reg].items()))
        fl = ", ".join(f for f, n in fns[reg].most_common(maxfn))
        more = len(fns[reg]) - maxfn
        print("| %s | %s | %d | %s%s |" % (reg, kinds, len(fns[reg]), fl, " +%d" % more if more > 0 else ""))


if __name__ == "__main__":
    for k in sys.argv[1:]:
        table(k)
