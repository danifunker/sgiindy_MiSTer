"""basescan.py ELF BASEOFF - per function, registers loaded by `lw rX, BASEOFF(rY)`
are REX3 base pointers (until overwritten); report every load/store through them."""
import sys, bisect
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from disfn import REX3
REX3 = dict(REX3)
REX3.update({0x1300:"SMASK1X",0x1304:"SMASK1Y",0x1308:"SMASK2X",0x130C:"SMASK2Y",0x1310:"SMASK3X",0x1314:"SMASK3Y",0x1318:"SMASK4X",0x131C:"SMASK4Y",0x1320:"TOPSCAN",0x1324:"XYWIN",0x1328:"CLIPMODE",0x132C:"STALL1",0x1330:"CONFIG",0x1338:"STATUS",0x133C:"USER_STATUS",0x1340:"DCBRESET"})
path = sys.argv[1]; baseoffs = set(int(x,0) for x in sys.argv[2].split(","))
d, secs, syms = parse(path)
addrs = [a for a,_ in syms]
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata = True
cnt = Counter(); fns = defaultdict(Counter); unk = Counter()
for s in secs:
    if not (s["flags"] & 4) or s["typ"] != 1: continue
    live = set(); curfn = None
    for ins in md.disasm(d[s["off"]:s["off"]+s["size"]], s["addr"]):
        i = bisect.bisect_right(addrs, ins.address)-1
        fn = syms[i][1] if i >= 0 else "?"
        if fn != curfn: live = set(); curfn = fn
        ops = [o.strip() for o in ins.op_str.split(",")]
        m = ins.mnemonic
        if "(" in ins.op_str and (m[0] in "sl") and m not in ("lui","li","la"):
            try:
                disp = ins.op_str.split(",",1)[1].strip(); o = int(disp.split("(")[0] or "0",0); base = disp.split("(")[1].rstrip(")")
            except Exception: o=None; base=None
            if base is not None and base in live:
                r = o & ~0x800
                nm = REX3.get(r, f"?{r:#x}")
                kind = "ST" if m.startswith("s") else "LD"
                cnt[(nm, "GO" if o & 0x800 else "", kind, m)] += 1
                fns[(nm, "GO" if o & 0x800 else "", kind, m)][fn] += 1
            if m == "lw" and o in baseoffs:
                live.add(ops[0]); continue
        # any other write to a live reg kills it (crude: first operand is dest for most ALU/loads)
        if ops and ops[0] in live and m not in ("sw","sh","sb","swc1","sdc1","sd","beq","bne","beqz","bnez","bgez","bltz","blez","bgtz","jr","jalr","mtc1"):
            live.discard(ops[0])
order = {v:k for k,v in REX3.items()}
for k in sorted(cnt, key=lambda k:(order.get(k[0], 0x9999), k[1], k[2], k[3])):
    f = ", ".join(f"{a}({b})" for a,b in fns[k].most_common(5))
    print(f"{k[0]:12s} {k[1]:2s} {k[2]} {k[3]:5s} {cnt[k]:4d}  {f}")
