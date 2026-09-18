"""rexbase.py ELF... - per function, find base registers that address REX3
(used with a STATUS/USER_STATUS load at 0x1338/0x133C, or a store with the GO
bit at a REX3 register offset), then list every access (any width) through
those base registers.  Heuristic: base register liveness is ignored."""
import sys, bisect
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from disfn import REX3
REX3 = dict(REX3)
REX3.update({0x1300:"SMASK1X",0x1304:"SMASK1Y",0x1308:"SMASK2X",0x130C:"SMASK2Y",0x1310:"SMASK3X",
 0x1314:"SMASK3Y",0x1318:"SMASK4X",0x131C:"SMASK4Y",0x1320:"TOPSCAN",0x1324:"XYWIN",0x1328:"CLIPMODE",
 0x132C:"STALL1",0x1330:"CONFIG",0x1338:"STATUS",0x133C:"USER_STATUS",0x1340:"DCBRESET"})
MEM = ("lb","lbu","lh","lhu","lw","lwu","ld","ldc1","lwc1","sb","sh","sw","sd","sdc1","swc1","lwl","lwr","swl","swr")
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata = True
def regname(o):
    r = o & 0x17FF
    return REX3.get(r)
for path in sys.argv[1:]:
    d, secs, syms = parse(path)
    addrs = [a for a, _ in syms]
    fninsns = defaultdict(list)
    for s in secs:
        if not (s["flags"] & 4) or s["typ"] != 1: continue
        for ins in md.disasm(d[s["off"]:s["off"]+s["size"]], s["addr"]):
            if ins.mnemonic not in MEM: continue
            try:
                a, disp = ins.op_str.split(",", 1)
                disp = disp.strip(); o = int(disp.split("(")[0] or "0", 0); base = disp.split("(")[1].rstrip(")")
            except (ValueError, IndexError): continue
            i = bisect.bisect_right(addrs, ins.address) - 1
            fninsns[syms[i][1] if i >= 0 else "?"].append((ins.address, ins.mnemonic, a.strip(), o, base))
    tot = Counter(); where = defaultdict(Counter)
    for fn, L in fninsns.items():
        bases = set()
        for (ad, mn, a, o, b) in L:
            if b in ("$sp","$fp","$gp"): continue
            if mn in ("lw",) and (o & 0x1FFF) in (0x1338, 0x133C) and o < 0x2000: bases.add(b)
            if mn in ("sw","sdc1","sd") and 0 <= o < 0x2000 and (o & 0x800) and regname(o): bases.add(b)
        if not bases: continue
        for (ad, mn, a, o, b) in L:
            if b in bases and 0 <= o < 0x2000 and regname(o):
                if mn in ("ld","ldc1","sd","sdc1"):
                    key = f"{mn} {regname(o)}+{REX3.get((o & 0x17FF)+4,'?')}{' GO' if o & 0x800 else ''}"
                elif mn in ("sb","sh","lb","lbu","lh","lhu","swl","swr","lwl","lwr"):
                    key = f"{mn} {regname(o)}+{o & 3}{' GO' if o & 0x800 else ''}"
                else:
                    continue
                tot[key] += 1; where[key][fn] += 1
    print(f"== {path}")
    for k, n in tot.most_common():
        print(f"  {n:4d} {k}   <- {', '.join(f'{f}({c})' for f,c in where[k].most_common(6))}")
