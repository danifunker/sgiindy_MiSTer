#!/usr/bin/env python3
"""Read the CPU suite's console log out of the machine's RAM. RUNS ON THE DEVICE.

The suite's two normal sinks are both unreadable on this core - the SCC
transmits nothing that reaches the HPS, and GIO slot 0 has no test device on it
- so console-memlog.patch adds a third that writes into main memory. This is
the other end of it.

BYTE ORDER IS THE ONLY SUBTLE PART, and getting it wrong produces a log that
looks like line noise rather than an error. The core numbers its bytes
big-endian within a 64-bit doubleword - the byte at `addr + i` is
`data[63-8i -: 8]` - and the ARM reads the same doubleword little-endian. So
the guest's byte at offset i lands at ARM offset (7 - i) within each group of
eight, and reading the log is a byte-reverse of every doubleword. The same rule
is why ddr3_peek.py's hexdump of the PROM reads backwards in fours.

Addresses are ARM physical. rtl/sgi/sgi_indy.sv puts guest RAM at 0x08000000
and rtl/mister/ddr3_mux.sv puts the base of that region at 0x30000000, so
guest physical 0x08100000 is ARM 0x30100000.

Usage (on the MiSTer):
    read_log.py              print the log, then the exception record if any
    read_log.py --raw        no formatting, just the bytes
"""
import argparse
import importlib.util
import os
import sys

PEEK = "/media/fat/sgidbg/ddr3_peek.py"

RAM_ARM   = 0x30000000            # guest physical 0x08000000
MEMLOG    = RAM_ARM + 0x100000    # guest 0xA8100000
MEMLOG_MAGIC = 0x494C4F47         # 'ILOG'
MEMLOG_CAP   = 0x80000
EXCREC    = RAM_ARM + 0x180000    # guest 0xA8180000, promstub.S writes it
EXCMAGIC  = 0x45584350            # 'EXCP'


def load_peek():
    spec = importlib.util.spec_from_file_location("peek", PEEK)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def guest_bytes(peek, arm_addr, length):
    """Read `length` guest bytes starting at a doubleword-aligned ARM address."""
    pad = (8 - (length % 8)) % 8
    raw = peek.read_phys(arm_addr, length + pad)
    out = bytearray()
    for i in range(0, len(raw), 8):
        out += raw[i:i + 8][::-1]
    return bytes(out[:length])


def u32(b, off):
    return int.from_bytes(b[off:off + 4], "big")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", action="store_true")
    a = ap.parse_args()
    peek = load_peek()

    hdr = guest_bytes(peek, MEMLOG, 8)
    magic, length = u32(hdr, 0), u32(hdr, 4)

    if magic != MEMLOG_MAGIC:
        print("no log: magic at 0x%08x is 0x%08x, expected 0x%08x ('ILOG')"
              % (MEMLOG, magic, MEMLOG_MAGIC))
        print("the suite never reached its first con_putc - see the exception "
              "record below, and note that a blank one means it never ran at all")
    else:
        if length > MEMLOG_CAP:
            print("log length 0x%x is past the buffer; truncating" % length)
            length = MEMLOG_CAP - 8
        text = guest_bytes(peek, MEMLOG + 8, length)
        sys.stdout.write(text.decode("latin1") if a.raw else
                         text.decode("latin1").replace("\r\n", "\n"))
        sys.stdout.write("\n")
        print("---- %d bytes of log ----" % length)

    rec = guest_bytes(peek, EXCREC, 24)
    if u32(rec, 0) == EXCMAGIC:
        names = {0x200: "TLB refill", 0x280: "XTLB refill",
                 0x300: "cache error", 0x380: "general"}
        vec = u32(rec, 20)
        cause = u32(rec, 4)
        print("\n!! TOOK AN EXCEPTION BEFORE THE SUITE INSTALLED ITS HANDLERS")
        print("   vector   0x%03x  %s (BEV=1, still the PROM's)"
              % (vec, names.get(vec, "?")))
        print("   Cause    0x%08x  ExcCode=%u" % (cause, (cause >> 2) & 0x1f))
        print("   EPC      0x%08x" % u32(rec, 8))
        print("   BadVAddr 0x%08x" % u32(rec, 12))
        print("   Status   0x%08x" % u32(rec, 16))


if __name__ == "__main__":
    sys.exit(main())
