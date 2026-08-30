#!/usr/bin/env python3
"""Disassemble a window of the boot PROM around one address.

WHY NOT run.py. That builds the whole annotated 512 KB listing, which is the
right tool when you are reading the PROM and the wrong one when a panic has
just handed you an EPC and you want the six instructions around it. This is
the second case: it is for turning "Exception PC: 0x9fc1f238" into an
instruction, in one command, with the lui/addiu constant pairs resolved because
that is nearly always the thing you actually wanted to know.

    python tools/prom/win.py 0x9fc1f238            # +/- 12 instructions
    python tools/prom/win.py 0x9fc1f238 --before 40 --after 8

Addresses may be given in any of the PROM's three aliases - kseg1 0xbfc.....,
kseg0 0x9fc....., or physical 0x1fc..... - because a panic prints kseg0 and the
chip specifications use kseg1 and neither is more correct than the other.
"""
import argparse, os, sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN

ROM = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "..", "roms", "IP24_Indy", "ip24prom.070-9101-011.bin")

def norm(a):
    """Any of the three aliases -> the kseg1 form the image is based at."""
    return (a & 0x1fffffff) | 0xbfc00000 if (a & 0x1fffffff) >= 0xc00000 \
           else (a & 0x1fffffff) | 0xbfc00000

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addr"); ap.add_argument("--before", type=int, default=12)
    ap.add_argument("--after", type=int, default=12)
    ap.add_argument("--rom", default=ROM)
    a = ap.parse_args()

    img = open(a.rom, "rb").read()
    base = 0xbfc00000
    target = norm(int(a.addr, 0))
    start = target - 4 * a.before
    n = a.before + a.after + 1
    off = start - base
    if off < 0 or off + 4 * n > len(img):
        sys.exit("0x%08x is outside the image" % target)

    md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
    hi = {}   # register -> upper half from the most recent lui, for the pairs
    for ins in md.disasm(img[off:off + 4 * n], start):
        mark = "==>" if ins.address == target else "   "
        note = ""
        op = ins.mnemonic
        txt = ins.op_str
        if op == "lui":
            r, v = [t.strip() for t in txt.split(",")]
            hi[r] = int(v, 0) << 16
        elif op in ("addiu", "ori", "addi") and "," in txt:
            parts = [t.strip() for t in txt.split(",")]
            if len(parts) == 3 and parts[1] in hi:
                v = int(parts[2], 0)
                if op == "addiu" or op == "addi":
                    v = v - 0x10000 if v >= 0x8000 else v
                    note = "  ; = 0x%08x" % ((hi[parts[1]] + v) & 0xffffffff)
                else:
                    note = "  ; = 0x%08x" % (hi[parts[1]] | v)
        elif "(" in txt and op[0] in "ls":
            parts = txt.split(",")
            reg = parts[-1].strip().split("(")[-1].rstrip(")")
            if reg in hi:
                dsp = parts[-1].strip().split("(")[0]
                v = int(dsp, 0)
                v = v - 0x10000 if v >= 0x8000 else v
                note = "  ; [0x%08x]" % ((hi[reg] + v) & 0xffffffff)
        print("%s 0x%08x  %08x  %-8s %s%s"
              % (mark, ins.address,
                 int.from_bytes(img[ins.address - base:ins.address - base + 4], "big"),
                 op, txt, note))

main()
