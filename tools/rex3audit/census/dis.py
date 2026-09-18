"""dis.py KEY FUNC|ADDR [--mem] - disassemble one function with symbolic base
values for loads/stores and values for stores (REX3 register names added)."""
import sys
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from binload import all_images
from mipsflow import Func, Ctx, partition, split, fmt, heuristic_starts
from census import regname

key, fn = sys.argv[1], sys.argv[2]
memonly = "--mem" in sys.argv
img = all_images()[key]()
fl = partition(img, heuristic_starts(img) if key in ("prom", "xsgi") else ())
if fn.startswith("0x"):
    a = int(fn, 16)
    lo, hi, nm = next(x for x in fl if x[0] <= a < x[1])
else:
    lo, hi, nm = next(x for x in fl if x[2] == fn)
f = Func(img, lo, hi, nm, Ctx())
names = lambda a: img.dsyms.get(a)
print("%s %08x-%08x %s" % (nm, lo, hi, img.srcfile.get(lo, "")))
for k, i in enumerate(f.ins):
    note = ""
    if i.kind in ("load", "store") and i.rs != 29:
        b = f.operand(k, i.rs)
        alts = split(b)
        ns = []
        for r, off in alts:
            off = (off + i.simm) & 0xFFFFFFFF
            so = off - (1 << 32) if off & 0x80000000 else off
            rn = regname(so, i.width) if r != ("c", 0) else None
            ns.append("%s%+#x%s" % (fmt(r, names)[:60], so, " =" + rn[0] + ("*" if rn[1] else "") if rn else ""))
        note = "  ; [" + " | ".join(ns) + "]"
        if i.kind == "store" and not i.fpr:
            note += " <= " + fmt(f.operand(k, i.rt), names)[:80]
    elif memonly:
        continue
    if i.kind in ("jump",) and i.link:
        note = "  ; " + img.funcs.get(i.target, "")
    if i.kind == "jalr":
        t = f.operand(k, i.rs)
        if t[0] == "c":
            note = "  ; " + img.funcs.get(t[1], hex(t[1]))
    print("%08x  %08x  %-34s%s" % (i.pc, i.w, i.text(), note))
