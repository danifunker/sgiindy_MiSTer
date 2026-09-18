import sys
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from st64 import parse
from disfn import REX3
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
path, lo, hi = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
d, secs, syms = parse(path)
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata = True
for s in secs:
    if s["typ"] == 1 and s["addr"] <= lo < s["addr"] + s["size"]:
        off = s["off"] + lo - s["addr"]
        for ins in md.disasm(d[off:off + (hi - lo)], lo):
            note = ""
            if ins.mnemonic in ("sw", "lw", "sdc1", "ldc1", "swc1"):
                try:
                    disp = ins.op_str.split(",")[1].strip()
                    o = int(disp.split("(")[0], 0) if disp.split("(")[0] else 0
                    if "$sp" not in disp and "$gp" not in disp:
                        reg = REX3.get(o & 0x7FF) if (o & ~0xFFF) == 0 or (o & ~0x1FFF) == 0 else None
                        if reg: note = f"   ; {reg}{' GO' if o & 0x800 else ''}"
                except (ValueError, IndexError):
                    pass
            print(f"0x{ins.address:08x}  {ins.mnemonic:8s} {ins.op_str}{note}")
