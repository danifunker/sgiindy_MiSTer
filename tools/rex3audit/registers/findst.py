"""findst.py ELF OFFSET[,OFFSET...] [--ctx N] - list addresses of loads/stores whose
immediate offset equals one of OFFSETs (base not sp/fp/gp); with --ctx N print
N instructions of context before and after each hit."""
import sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
path = sys.argv[1]
offs = set(int(x,0) for x in sys.argv[2].split(","))
ctx = 0
if "--ctx" in sys.argv: ctx = int(sys.argv[sys.argv.index("--ctx")+1])
only = None
if "--st" in sys.argv: only = "st"
d, secs, syms = parse(path)
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata = True
for s in secs:
    if not (s["flags"] & 4) or s["typ"] != 1: continue
    insns = list(md.disasm(d[s["off"]:s["off"]+s["size"]], s["addr"]))
    for i, ins in enumerate(insns):
        if not (ins.mnemonic.startswith("s") or ins.mnemonic.startswith("l")) or "(" not in ins.op_str: continue
        if only == "st" and not ins.mnemonic.startswith("s"): continue
        try:
            disp = ins.op_str.split(",",1)[1].strip(); o = int(disp.split("(")[0] or "0",0); base = disp.split("(")[1].rstrip(")")
        except Exception: continue
        if base in ("$sp","$fp","$gp"): continue
        if o in offs:
            if ctx:
                print("-----")
                for j in range(max(0,i-ctx), min(len(insns), i+ctx+1)):
                    x = insns[j]; print(f"{'>>' if j==i else '  '} 0x{x.address:08x} {x.mnemonic:8s} {x.op_str}")
            else:
                print(f"0x{ins.address:08x} {ins.mnemonic} {ins.op_str}")
