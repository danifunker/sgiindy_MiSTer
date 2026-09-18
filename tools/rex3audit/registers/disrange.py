import sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from disfn import REX3
EXTRA = {0x1300:"SMASK1X",0x1304:"SMASK1Y",0x1308:"SMASK2X",0x130C:"SMASK2Y",0x1310:"SMASK3X",0x1314:"SMASK3Y",0x1318:"SMASK4X",0x131C:"SMASK4Y",0x1320:"TOPSCAN",0x1324:"XYWIN",0x1328:"CLIPMODE",0x132C:"STALL1",0x1330:"CONFIG",0x1338:"STATUS",0x133C:"USER_STATUS",0x1340:"DCBRESET"}
path = sys.argv[1]; lo = int(sys.argv[2],0); hi = int(sys.argv[3],0)
d, secs, syms = parse(path)
sec = next(s for s in secs if s["addr"] <= lo < s["addr"]+s["size"] and s["typ"]==1)
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata=True
for ins in md.disasm(d[sec["off"]+lo-sec["addr"]: sec["off"]+hi-sec["addr"]], lo):
    note=""
    if "(" in ins.op_str and (ins.mnemonic[0] in "sl"):
        try:
            disp = ins.op_str.split(",",1)[1].strip(); o = int(disp.split("(")[0] or "0",0)
            r = o & ~0x800
            nm = REX3.get(r) or EXTRA.get(r)
            if nm and r >= 0x100: note = f"   ; {nm}{' GO' if o & 0x800 else ''}"
            elif nm: note = f"   ; ?{nm}{' GO' if o & 0x800 else ''}"
        except Exception: pass
    print(f"0x{ins.address:08x} {ins.mnemonic:8s} {ins.op_str}{note}")
