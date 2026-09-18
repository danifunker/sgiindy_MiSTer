import sys
sys.path.insert(0, r"..")
from st64 import parse
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
from collections import Counter, defaultdict
import bisect
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata=True
MEM = ("lb","lbu","lh","lhu","lw","ld","ldc1","lwc1","sb","sh","sw","sd","sdc1","swc1")
offs = {0x238:"DCBMODE",0x240:"DCBDATA0",0x241:"DCBDATA0+1",0x242:"DCBDATA0+2",0x243:"DCBDATA0+3",0x244:"DCBDATA1",0x245:"DCBDATA1+1",0x246:"DCBDATA1+2",0x247:"DCBDATA1+3",0x1340:"DCBRESET",0x1330:"CONFIG",0x230:"HOSTRW0",0x234:"HOSTRW1",0x1338:"STATUS",0x133c:"USER_STATUS",0x24:"STALL0",0x132c:"STALL1",0x30:"SETUP",0x34:"STEPZ",0x38:"LSRESTORE",0x3c:"LSSAVE",0x1320:"TOPSCAN"}
for path in sys.argv[1:]:
    d, secs, syms = parse(path)
    addrs=[a for a,_ in syms]
    c = Counter(); fn=defaultdict(Counter)
    for s in secs:
        if not (s["flags"] & 4) or s["typ"] != 1: continue
        for ins in md.disasm(d[s["off"]:s["off"]+s["size"]], s["addr"]):
            if ins.mnemonic not in MEM: continue
            try:
                disp = ins.op_str.split(",",1)[1].strip(); o = int(disp.split("(")[0] or "0",0); base = disp.split("(")[1].rstrip(")")
            except Exception: continue
            if base in ("$sp","$fp","$gp"): continue
            if o < 0 or o >= 0x2000: continue
            r = o & ~0x800
            if r in offs:
                k=f"{ins.mnemonic} {offs[r]}{' GO' if o & 0x800 else ''}"
                c[k]+=1
                i=bisect.bisect_right(addrs, ins.address)-1
                fn[k][syms[i][1] if i>=0 else '?']+=1
    print("==", path)
    for k,n in sorted(c.items(), key=lambda x:(-x[1])):
        print(f"  {n:4d} {k}   {', '.join(f'{f}({m})' for f,m in fn[k].most_common(5))}")
