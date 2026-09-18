"""review.py KEY [--fn REGEX] [--all] - per function: REX3 roots, evidence, registers"""
import sys
import re
import pickle
from collections import defaultdict
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from mipsflow import fmt

HERE = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]
key = sys.argv[1]
fnre = re.compile(sys.argv[sys.argv.index("--fn") + 1]) if "--fn" in sys.argv else None
R = pickle.load(open(HERE + "/out/%s.rex.pkl" % key, "rb"))
names = lambda a: R["dsyms"].get(a)
byfn = defaultdict(lambda: defaultdict(list))
fname = {}
for a in R["rex"]:
    byfn[a["flo"]][(a["root"], a["ev"])].append(a)
    fname[a["flo"]] = a["fn"]
for flo in sorted(byfn):
    if fnre and not fnre.search(fname[flo]):
        continue
    print("%08x %s  [%s]" % (flo, fname[flo], R["srcfile"].get(flo, "")))
    for (root, ev), L in byfn[flo].items():
        regs = []
        seen = set()
        for a in sorted(L, key=lambda a: a["wo"]):
            t = "%s%s%s%s" % (a["reg"], "*" if a["go"] else "",
                              "" if a["width"] == 4 else "/" + a["mn"], "" if a["st"] else "(r)")
            if t not in seen:
                seen.add(t)
                regs.append(t)
        print("    %-6s %-44s n=%-4d %s" % (ev, fmt(root, names)[:44], len(L), " ".join(regs)))
