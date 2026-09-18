"""regstores.py ELF... - count stores (sw/swc1/sdc1/sd) whose immediate offset
names one of a chosen set of REX3 registers (GO alias included), excluding
$sp/$fp/$gp bases. Heuristic: struct fields at the same offsets also match,
so the per-function listing is printed for judgement."""
import sys
import bisect
from collections import Counter, defaultdict
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"C:\Users\spam\AppData\Local\Temp\claude\C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e\a11d8c0a-4bd4-4d6a-a12a-09061890f305\scratchpad")
from st64 import parse

WANT = {0x030: "SETUP", 0x034: "STEPZ", 0x038: "LSRESTORE", 0x03C: "LSSAVE",
        0x010: "LSPATSAVE", 0x008: "LSMODE", 0x00C: "LSPATTERN",
        0x110: "XSAVE", 0x118: "BRESD", 0x11C: "BRESS1", 0x120: "BRESOCTINC1",
        0x124: "BRESRNDINC2", 0x128: "BRESE1", 0x12C: "BRESS2",
        0x130: "AWEIGHT0", 0x134: "AWEIGHT1",
        0x138: "XSTARTF", 0x13C: "YSTARTF", 0x140: "XENDF", 0x144: "YENDF",
        0x148: "XSTARTI", 0x14C: "XENDF1", 0x158: "XSTARTENDI", 0x114: "XYMOVE"}
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
md.skipdata = True
for path in sys.argv[1:]:
    d, secs, syms = parse(path)
    addrs = [a for a, _ in syms]
    cnt = Counter()
    where = defaultdict(Counter)
    for s in secs:
        if not (s["flags"] & 4) or s["typ"] != 1:
            continue
        for ins in md.disasm(d[s["off"]:s["off"] + s["size"]], s["addr"]):
            if ins.mnemonic not in ("sw", "swc1", "sdc1", "sd"):
                continue
            try:
                disp = ins.op_str.split(",", 1)[1].strip()
                o = int(disp.split("(")[0] or "0", 0)
                base = disp.split("(")[1].rstrip(")")
            except (ValueError, IndexError):
                continue
            if base in ("$sp", "$fp", "$gp", "$s8") or not 0 <= o < 0x2000:
                continue
            r = o & 0x7FF
            if r not in WANT:
                continue
            key = f"{ins.mnemonic:5s} {WANT[r]}{' GO' if o & 0x800 else ''}"
            cnt[key] += 1
            i = bisect.bisect_right(addrs, ins.address) - 1
            where[key][syms[i][1] if i >= 0 else "?"] += 1
    print(f"== {path.split('/')[-1].split(chr(92))[-1]}")
    for k, n in sorted(cnt.items(), key=lambda kv: kv[0]):
        fns = ", ".join(f"{f}({c})" for f, c in where[k].most_common(8))
        print(f"   {n:4d}  {k:22s} {fns}")
