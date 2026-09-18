"""xref.py ELF PATTERN... - disassemble all executable sections and print
instructions whose op_str matches any regex, with the enclosing function."""
import sys, re
from bisect import bisect_right
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
path = sys.argv[1]
pats = [re.compile(p) for p in sys.argv[2:]]
d, secs, syms = parse(path)
addrs = [a for a, _ in syms]
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.skipdata = True
for s in secs:
    if s["typ"] != 1 or not (s["flags"] & 4):
        continue
    for ins in md.disasm(d[s["off"]:s["off"] + s["size"]], s["addr"]):
        txt = f"{ins.mnemonic} {ins.op_str}"
        if any(p.search(txt) for p in pats):
            i = bisect_right(addrs, ins.address) - 1
            fn = syms[i][1] if i >= 0 else "?"
            print(f"0x{ins.address:08x} {fn:40s} {txt}")
