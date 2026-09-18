"""rex64.py ELF... - doubleword accesses that look like REX3 register pairs.

A candidate is an sdc1/sd/ldc1/ld whose base register is not $sp/$fp/$gp and
whose offset, taken as an 8-byte-aligned offset into REX3's 8 KB window
(GO alias included), names a register - the shape IRIS GL's __line_shade
uses: sdc1 $f2, 0x138($t0) writes XSTARTF and YSTARTF in one transaction.
Prints the per-library totals and each register pair's count.
"""
import sys
from collections import Counter
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from st64 import parse
from disfn import REX3

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.skipdata = True
for path in sys.argv[1:]:
    d, secs, syms = parse(path)
    pairs, fns, total = Counter(), Counter(), 0
    names = sorted(syms)
    import bisect
    addrs = [a for a, _ in names]
    for s in secs:
        if not (s["flags"] & 4) or s["typ"] != 1:
            continue
        for ins in md.disasm(d[s["off"]:s["off"] + s["size"]], s["addr"]):
            if ins.mnemonic not in ("sdc1", "sd", "ldc1", "ld"):
                continue
            try:
                disp = ins.op_str.split(",", 1)[1].strip()
                o = int(disp.split("(")[0] or "0", 0)
                base = disp.split("(")[1].rstrip(")")
            except (ValueError, IndexError):
                continue
            if base in ("$sp", "$fp", "$gp", "$s8") or o % 8 or not 0 <= o < 0x2000:
                continue
            r = o & 0x7FF
            if r not in REX3 or r + 4 not in REX3:
                continue
            total += 1
            key = f"{ins.mnemonic} {REX3[r]}+{REX3[r + 4]}{' GO' if o & 0x800 else ''}"
            pairs[key] += 1
            i = bisect.bisect_right(addrs, ins.address) - 1
            fns[names[i][1] if i >= 0 else "?"] += 1
    print(f"== {path.split('/')[-1]}: {total} candidate REX3 doubleword accesses "
          f"in {len(fns)} functions")
    for k, n in pairs.most_common():
        print(f"   {n:4d}  {k}")
    print("   functions:", ", ".join(f"{f}({n})" for f, n in fns.most_common(40)))
