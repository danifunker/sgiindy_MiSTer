"""regscan.py ELF... - count every load/store whose immediate offset names a
REX3 register (GO alias split out), base not sp/fp/gp. Heuristic: struct
fields at the same offsets also count, so read GO counts as strongest."""
import sys, bisect
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from disfn import REX3
REX3 = dict(REX3)
REX3.update({0x1300:"SMASK1X",0x1304:"SMASK1Y",0x1308:"SMASK2X",0x130C:"SMASK2Y",0x1310:"SMASK3X",0x1314:"SMASK3Y",0x1318:"SMASK4X",0x131C:"SMASK4Y",0x1320:"TOPSCAN",0x1324:"XYWIN",0x1328:"CLIPMODE",0x132C:"STALL1",0x1330:"CONFIG",0x1338:"STATUS",0x133C:"USER_STATUS",0x1340:"DCBRESET"})
ST = {"sw","swc1","sdc1","sd","sh","sb"}
LD = {"lw","lwc1","ldc1","ld","lh","lhu","lb","lbu"}
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.skipdata = True
want = set(a.upper() for a in sys.argv[2:]) if len(sys.argv) > 2 else None
path = sys.argv[1]
d, secs, syms = parse(path) if not path.endswith("unix") else (None,None,None)
cnt = Counter(); where = defaultdict(Counter)
addrs = [a for a,_ in syms]
for s in secs:
    if not (s["flags"] & 4) or s["typ"] != 1: continue
    for ins in md.disasm(d[s["off"]:s["off"]+s["size"]], s["addr"]):
        m = ins.mnemonic
        if m not in ST and m not in LD: continue
        try:
            disp = ins.op_str.split(",",1)[1].strip()
            o = int(disp.split("(")[0] or "0", 0)
            base = disp.split("(")[1].rstrip(")")
        except Exception: continue
        if base in ("$sp","$fp","$gp","$s8") or o < 0 or o >= 0x2000: continue
        go = bool(o & 0x800)
        r = o & ~0x800
        if r not in REX3: continue
        kind = "ST" if m in ST else "LD"
        key = (REX3[r], go, kind, m)
        cnt[key] += 1
        i = bisect.bisect_right(addrs, ins.address)-1
        where[key][syms[i][1] if i>=0 else "?"] += 1
order = {v:k for k,v in REX3.items()}
for key in sorted(cnt, key=lambda k:(order[k[0]], k[1], k[2], k[3])):
    name, go, kind, m = key
    if want and name not in want: continue
    fns = ", ".join(f"{f}({n})" for f,n in where[key].most_common(6))
    print(f"{name:12s} {'GO' if go else '  '} {kind} {m:5s} {cnt[key]:5d}   {fns}")
