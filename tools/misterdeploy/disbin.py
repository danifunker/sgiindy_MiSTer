#!/usr/bin/env python3
"""Disassemble a raw big-endian MIPS blob at a given base address.

The companion to guestmem.py: that reads the guest's memory in the guest's byte
order, this turns it into instructions. Together they disassemble code that
exists only in RAM - an installer, a kernel, anything the machine loaded - which
tools/prom/win.py cannot do because it reads the PROM image off disk.

    python tools/misterdeploy/disbin.py dump.bin 0x88007400 [--mark 0x880075b4]
"""
import argparse
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN

ap = argparse.ArgumentParser()
ap.add_argument("blob"); ap.add_argument("base")
ap.add_argument("--mark", default=None, help="address to flag with ==>")
ap.add_argument("--from", dest="lo", default=None)
ap.add_argument("--to", dest="hi", default=None)
a = ap.parse_args()

data = open(a.blob, "rb").read()
base = int(a.base, 0)
mark = int(a.mark, 0) if a.mark else None
lo = int(a.lo, 0) if a.lo else base
hi = int(a.hi, 0) if a.hi else base + len(data)

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN)
# WITHOUT THIS THE LISTING STOPS AT THE FIRST WORD CAPSTONE CANNOT DECODE, and
# says nothing about it - which in a kernel or an installer means the first
# coprocessor instruction, tens of instructions before anything interesting.
md.skipdata = True
hiv = {}
for ins in md.disasm(data, base):
    if not (lo <= ins.address < hi):
        continue
    note = ""
    if ins.mnemonic == "lui":
        r, v = [t.strip() for t in ins.op_str.split(",")]
        hiv[r] = int(v, 0) << 16
    elif ins.mnemonic in ("addiu", "ori", "addi"):
        p = [t.strip() for t in ins.op_str.split(",")]
        if len(p) == 3 and p[1] in hiv:
            v = int(p[2], 0)
            if ins.mnemonic != "ori" and v >= 0x8000:
                v -= 0x10000
            note = "  ; = 0x%08x" % ((hiv[p[1]] + v) & 0xffffffff)
    print("%s 0x%08x  %08x  %-8s %s%s"
          % ("==>" if ins.address == mark else "   ", ins.address,
             int.from_bytes(data[ins.address - base:ins.address - base + 4], "big"),
             ins.mnemonic, ins.op_str, note))
