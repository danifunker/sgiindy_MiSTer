"""disva.py ELF LO HI - disassemble an ELF32 MSB MIPS by virtual address range, annotating lui/ori constants and REX3 register offsets."""
import sys, struct
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
R = {0x238:"DCBMODE",0x240:"DCBDATA0",0x241:"DCBDATA0.b1",0x242:"DCBDATA0.h1",0x243:"DCBDATA0.b3",0x244:"DCBDATA1",0x133c:"USERSTATUS",0x1338:"STATUS",0x1320:"TOPSCAN",0x1324:"XYWIN",0x1328:"CLIPMODE",0x1330:"CONFIG",0x1340:"DCBRESET"}
path, lo, hi = sys.argv[1], int(sys.argv[2],0), int(sys.argv[3],0)
d, secs, syms = parse(path)
sec = next(s for s in secs if s["addr"] <= lo < s["addr"]+s["size"] and s["typ"]==1)
off = sec["off"] + lo - sec["addr"]
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata=True
hiv={}
for ins in md.disasm(d[off:off+(hi-lo)], lo):
    note=""; ops=[o.strip() for o in ins.op_str.split(",")]
    if ins.mnemonic=="lui": hiv[ops[0]]=int(ops[1],0)<<16
    elif ins.mnemonic in ("ori","addiu") and len(ops)==3 and ops[1] in hiv:
        v=int(ops[2],0)
        if ins.mnemonic=="addiu" and v>=0x8000: v-=0x10000
        note="  ; = 0x%08x"%((hiv[ops[1]]|v) if ins.mnemonic=="ori" else (hiv[ops[1]]+v)&0xffffffff)
    if ins.mnemonic in ("sw","sh","sb","lw","lbu","lhu","lb","lh") and len(ops)==2:
        try:
            o=int(ops[1].split("(")[0],0)
            if (o & 0x17ff) in R or (o&0x7ff) in R: note += "  ; "+R.get(o&0x17ff, R.get(o&0x7ff,""))
        except ValueError: pass
    fn=""
    for a,n in syms:
        if a==ins.address: fn="<"+n+">"
    print(f"{fn}\n" if fn else "", end="")
    print("0x%08x  %-7s %s%s"%(ins.address, ins.mnemonic, ins.op_str, note))
