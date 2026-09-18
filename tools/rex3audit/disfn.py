"""disfn.py ELF FUNC [--st64] - disassemble one function of an ELF32 MSB MIPS
object by symbol name. --st64 prints only the doubleword stores/loads with
the REX3 register each offset would name (base + offset & 0x1FFF)."""
import sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
from st64 import parse

REX3 = {0x000: "DRAWMODE1", 0x004: "DRAWMODE0", 0x008: "LSMODE", 0x00C: "LSPATTERN",
        0x010: "LSPATSAVE", 0x014: "ZPATTERN", 0x018: "COLORBACK", 0x01C: "COLORVRAM",
        0x020: "ALPHAREF", 0x024: "STALL0", 0x028: "SMASK0X", 0x02C: "SMASK0Y",
        0x030: "SETUP", 0x034: "STEPZ", 0x038: "LSRESTORE", 0x03C: "LSSAVE",
        0x100: "XSTART", 0x104: "YSTART", 0x108: "XEND", 0x10C: "YEND",
        0x110: "XSAVE", 0x114: "XYMOVE", 0x118: "BRESD", 0x11C: "BRESS1",
        0x120: "BRESOCTINC1", 0x124: "BRESRNDINC2", 0x128: "BRESE1", 0x12C: "BRESS2",
        0x130: "AWEIGHT0", 0x134: "AWEIGHT1", 0x138: "XSTARTF", 0x13C: "YSTARTF",
        0x140: "XENDF", 0x144: "YENDF", 0x148: "XSTARTI", 0x14C: "XENDF1",
        0x150: "XYSTARTI", 0x154: "XYENDI", 0x158: "XSTARTENDI",
        0x200: "COLORRED", 0x204: "COLORALPHA", 0x208: "COLORGREEN", 0x20C: "COLORBLUE",
        0x210: "SLOPERED", 0x214: "SLOPEALPHA", 0x218: "SLOPEGREEN", 0x21C: "SLOPEBLUE",
        0x220: "WRMASK", 0x224: "COLORI", 0x228: "COLORX", 0x22C: "SLOPERED1",
        0x230: "HOSTRW0", 0x234: "HOSTRW1", 0x238: "DCBMODE", 0x240: "DCBDATA0",
        0x244: "DCBDATA1"}

if __name__ == "__main__":
    path, fn = sys.argv[1], sys.argv[2]
    only = "--st64" in sys.argv
    d, secs, syms = parse(path)
    addrs = [a for a, _ in syms]
    lo = next(a for a, n in syms if n == fn)
    hi = next((a for a in addrs if a > lo), lo + 0x4000)
    sec = next(s for s in secs if s["addr"] <= lo < s["addr"] + s["size"] and s["typ"] == 1)
    off = sec["off"] + (lo - sec["addr"])
    md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
    md.skipdata = True
    for ins in md.disasm(d[off:off + (hi - lo)], lo):
        note = ""
        if ins.mnemonic in ("sdc1", "ldc1", "sw", "lw", "swc1"):
            try:
                disp = ins.op_str.split(",")[1].strip()
                o = int(disp.split("(")[0], 0) if disp.split("(")[0] else 0
                reg = REX3.get(o & 0x7FF)
                if reg:
                    note = f"   ; {reg}{' GO' if o & 0x800 else ''}"
            except (ValueError, IndexError):
                pass
        if only and ins.mnemonic not in ("sdc1", "ldc1"):
            continue
        print(f"0x{ins.address:08x}  {ins.mnemonic:8s} {ins.op_str}{note}")
