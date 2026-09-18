"""Decode the IRIS draw-shape corpus (dm0, dm1, cm) and tally walker features."""
import re
import sys
from collections import Counter, defaultdict

SRC = r"C:\Temp\mistercore\iris\src\rex3_shaders.rs"
trip = []
for line in open(SRC, encoding="utf-8"):
    m = re.search(r"/// dm0=0x([0-9a-fA-F]+) dm1=0x([0-9a-fA-F]+) cm=0x([0-9a-fA-F]+)", line)
    if m:
        trip.append(tuple(int(g, 16) for g in m.groups()))
print("triples:", len(trip), "distinct dm0:", len({t[0] for t in trip}))

OPC = {0: "NOOP", 1: "READ", 2: "DRAW", 3: "SCR2SCR"}
ADR = {0: "SPAN", 1: "BLOCK", 2: "I_LINE", 3: "F_LINE", 4: "A_LINE"}
BITS0 = [(5, "DOSETUP"), (6, "COLORHOST"), (7, "ALPHAHOST"), (8, "STOPONX"),
         (9, "STOPONY"), (10, "SKIPFIRST"), (11, "SKIPLAST"), (12, "ENZPATTERN"),
         (13, "ENLSPATTERN"), (14, "LSADVLAST"), (15, "LENGTH32"), (16, "ZPOPAQUE"),
         (17, "LSOPAQUE"), (18, "SHADE"), (19, "LRONLY"), (20, "XYOFFSET"),
         (21, "CICLAMP"), (22, "ENDPTFILTER"), (23, "YSTRIDE")]

def dec0(v):
    s = [OPC[v & 3], ADR.get((v >> 2) & 7, "ADR%d" % ((v >> 2) & 7))]
    s += [n for b, n in BITS0 if v >> b & 1]
    if v >> 24:
        s.append("HI=%x" % (v >> 24))
    return s

def dec1(v):
    planes = v & 7
    depth = [4, 8, 12, 24][(v >> 3) & 3]
    out = ["pl%d" % planes, "d%d" % depth]
    if v >> 5 & 1: out.append("DBLSRC")
    if v >> 6 & 1: out.append("YFLIP")
    if v >> 7 & 1: out.append("RWPACKED")
    if v >> 11 & 1: out.append("SWAPENDIAN")
    if v >> 15 & 1: out.append("RGB")
    if v >> 16 & 1: out.append("DITHER")
    if v >> 17 & 1: out.append("FASTCLEAR")
    if v >> 18 & 1: out.append("BLEND")
    out.append("lo%x" % (v >> 28))
    return out

feat = Counter()
by_adr = defaultdict(Counter)
combos = Counter()
for dm0, dm1, cm in trip:
    d = dec0(dm0)
    for f in d[2:]:
        feat[f] += 1
        by_adr[d[1]][f] += 1
    feat["op:" + d[0]] += 1
    feat["adr:" + d[1]] += 1
    by_adr[d[1]]["op:" + d[0]] += 1
    # flag-combination key for the walker: op/adr + control flags only
    ctl = [n for n in d[2:] if n in ("DOSETUP", "STOPONX", "STOPONY", "SKIPFIRST",
                                     "SKIPLAST", "LENGTH32", "LRONLY", "XYOFFSET",
                                     "YSTRIDE", "ENZPATTERN", "ENLSPATTERN",
                                     "LSADVLAST", "ZPOPAQUE", "LSOPAQUE",
                                     "ENDPTFILTER", "COLORHOST", "SHADE")]
    combos[(d[0], d[1], tuple(ctl))] += 1
    if dm1 >> 6 & 1:
        feat["dm1:YFLIP"] += 1
    if dm1 >> 11 & 1:
        feat["dm1:SWAPENDIAN"] += 1

print("\n== feature counts over all triples")
for k, n in sorted(feat.items(), key=lambda kv: -kv[1]):
    print("%5d  %s" % (n, k))
print("\n== per address mode")
for a, c in by_adr.items():
    print(a, dict(c))
print("\n== walker control combinations (op, adrmode, flags): count of triples")
for (op, adr, ctl), n in sorted(combos.items(), key=lambda kv: (-kv[1], kv[0])):
    print("%4d  %-7s %-6s %s" % (n, op, adr, " ".join(ctl)))
if "-v" in sys.argv:
    for dm0, dm1, cm in trip:
        print("%08x %08x %04x  %s | %s" % (dm0, dm1, cm, " ".join(dec0(dm0)), " ".join(dec1(dm1))))
