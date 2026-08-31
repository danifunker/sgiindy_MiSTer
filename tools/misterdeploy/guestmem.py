#!/usr/bin/env python3
"""Read the GUEST's memory by its own addresses. RUNS ON THE DEVICE.

ddr3_peek.py reads ARM physical addresses and hands back bytes in the order the
ARM sees them. Neither of those is what you have when a machine has just
panicked: you have a MIPS address out of an exception frame, and you want the
guest's bytes in the guest's order. This does both conversions.

THE ADDRESS. KSEG0 (0x80000000-0x9FFFFFFF) and KSEG1 (0xA0000000-0xBFFFFFFF)
are unmapped windows onto physical memory, so a panic's EPC needs only its top
bits removed. Then rtl/sgi/sgi_indy.sv puts main memory at physical 0x08000000
and rtl/mister/ddr3_mux.sv puts that region at ARM 0x30000000, with the boot
PROM's 0x1FC00000 at ARM 0x35000000.

THE BYTE ORDER, WHICH IS THE PART THAT CATCHES PEOPLE. The core numbers bytes
big-endian within each 64-bit word and the ARM reads little-endian, so every
eight-byte group comes back REVERSED. A hex dump of the guest's code through
ddr3_peek looks like nothing at all until the groups are flipped back; flipping
them gives exactly the bytes the CPU fetched.

    python3 guestmem.py 0x880075b4 0x80              # hex dump
    python3 guestmem.py 0x880075b4 0x200 -o /tmp/x   # raw, for a disassembler

An address outside the two mapped regions is refused rather than silently read
from somewhere plausible.
"""
import argparse
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
_m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_m)

RAM_PHYS, RAM_ARM, RAM_LEN = 0x08000000, 0x30000000, 0x04000000
PROM_PHYS, PROM_ARM, PROM_LEN = 0x1FC00000, 0x35000000, 0x00080000


def to_arm(addr):
    """A guest virtual (or physical) address -> the ARM physical address."""
    if 0x80000000 <= addr < 0xA0000000:
        phys = addr - 0x80000000
    elif 0xA0000000 <= addr < 0xC0000000:
        phys = addr - 0xA0000000
    else:
        phys = addr
    if RAM_PHYS <= phys < RAM_PHYS + RAM_LEN:
        return RAM_ARM + (phys - RAM_PHYS), "main memory"
    if PROM_PHYS <= phys < PROM_PHYS + PROM_LEN:
        return PROM_ARM + (phys - PROM_PHYS), "boot PROM"
    sys.exit("0x%08x -> physical 0x%08x, which is not main memory or the PROM"
             % (addr, phys))


def read_guest(addr, length):
    """Bytes in the guest's own order."""
    arm, _ = to_arm(addr)
    lo = arm & ~7                       # whole 8-byte groups, then trim
    hi = (arm + length + 7) & ~7
    raw = _m.read_phys(lo, hi - lo)
    out = bytearray()
    for i in range(0, len(raw), 8):
        out += raw[i:i + 8][::-1]       # un-reverse each group
    off = arm - lo
    return bytes(out[off:off + length])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addr")
    ap.add_argument("length", nargs="?", default="0x40")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()
    addr, length = int(a.addr, 0), int(a.length, 0)
    arm, where = to_arm(addr)
    data = read_guest(addr, length)

    if a.out:
        open(a.out, "wb").write(data)
        print("wrote %d bytes of %s at 0x%08x (ARM 0x%08x) to %s"
              % (len(data), where, addr, arm, a.out))
        return

    print("0x%08x in %s (ARM 0x%08x)" % (addr, where, arm))
    for i in range(0, len(data), 16):
        row = data[i:i + 16]
        txt = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print("  %08x  %-47s  |%s|"
              % (addr + i, " ".join("%02x" % b for b in row), txt))


main()
