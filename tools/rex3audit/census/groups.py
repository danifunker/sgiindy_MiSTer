"""groups.py KEY [VERDICTS] [--fn REGEX] - list base-root groups with their offsets"""
import sys
import re
import pickle
from collections import defaultdict
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from mipsflow import fmt
from census import regname

key = sys.argv[1]
want = set(sys.argv[2].split(",")) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else {"abs", "strong", "shape", "weak"}
fnre = None
if "--fn" in sys.argv:
    fnre = re.compile(sys.argv[sys.argv.index("--fn") + 1])
D = pickle.load(open(__file__.rsplit("\\", 1)[0].rsplit("/", 1)[0] + "/out/%s.pkl" % key, "rb"))
acc, groups, verdict = D["acc"], D["groups"], D["verdict"]
names = lambda a: D["dsyms"].get(a)
byfn = defaultdict(list)
for g, v in verdict.items():
    if v in want:
        byfn[g[0]].append(g)
for flo in sorted(byfn):
    gs = byfn[flo]
    fn = acc[groups[gs[0]][0]]["fn"]
    if fnre and not fnre.search(fn):
        continue
    print("%08x %s  [%s]" % (flo, fn, D["srcfile"].get(flo, "")))
    for g in gs:
        js = groups[g]
        offs = sorted({(acc[j]["wo"], acc[j]["width"]) for j in js})
        parts = []
        for o, w in offs:
            r = regname(o, w)
            sub = "" if w == 4 else ("/b%d" % (o & 3) if w == 1 else "/h%d" % ((o & 3) // 2) if w == 2 else "/d")
            parts.append("%s%s%s" % (r[0], "*" if r[1] else "", sub) if r else "0x%x?" % o)
        print("    %-7s %-40s n=%-4d %s" % (verdict[g], fmt(g[1], names)[:40], len(js), " ".join(parts)))
