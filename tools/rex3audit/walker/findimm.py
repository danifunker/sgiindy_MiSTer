"""findimm.py ELF IMM [before] [after] - find instructions with a given 16-bit
immediate (ori/addiu/li) and print a window of disassembly around each."""
import sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:\Users\spam\AppData\Local\Temp\claude\C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e\a11d8c0a-4bd4-4d6a-a12a-09061890f305\scratchpad")
from st64 import parse
from disfn import REX3

path, imm = sys.argv[1], int(sys.argv[2], 0)
before = int(sys.argv[3]) if len(sys.argv) > 3 else 12
after = int(sys.argv[4]) if len(sys.argv) > 4 else 30
d, secs, syms = parse(path)
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.skipdata = True
for s in secs:
    if not (s["flags"] & 4) or s["typ"] != 1:
        continue
    ins = list(md.disasm(d[s["off"]:s["off"] + s["size"]], s["addr"]))
    for i, x in enumerate(ins):
        if x.mnemonic in ("ori", "addiu", "li", "xori", "andi") and x.op_str.endswith(hex(imm)):
            print("-" * 60)
            for y in ins[max(0, i - before):i + after]:
                note = ""
                if y.mnemonic in ("sw", "swc1", "sdc1", "lw", "sd"):
                    try:
                        disp = y.op_str.split(",")[1].strip()
                        o = int(disp.split("(")[0], 0) if disp.split("(")[0] else 0
                        base = disp.split("(")[1].rstrip(")")
                        if base not in ("$sp", "$gp", "$fp") and 0 <= o < 0x2000:
                            reg = REX3.get(o & 0x7FF)
                            if reg:
                                note = f"   ; {reg}{' GO' if o & 0x800 else ''}"
                    except (ValueError, IndexError):
                        pass
                mark = ">>" if y.address == x.address else "  "
                print(f"{mark}0x{y.address:08x}  {y.mnemonic:8s} {y.op_str}{note}")
