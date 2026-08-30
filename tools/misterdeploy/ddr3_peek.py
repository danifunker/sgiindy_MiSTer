#!/usr/bin/env python3
"""Read the core's DDR3 window from the MiSTer's ARM side. RUNS ON THE DEVICE.

The FPGA and the HPS share one DDR3. A core's DDRAM port addresses it with the
same physical addresses Linux uses, so anything the core has put in memory can
be read from the ARM with an mmap of /dev/mem - main memory, the frame buffer,
and the PROM the framework uploaded. That makes the machine's memory as
inspectable on hardware as it is under Verilator, which is the whole point.

`read()` on /dev/mem gives EFAULT over the reserved window; mmap does not, so
this mmaps and memcpys out of the mapping. Busybox `devmem` reads zeroes here
and is not a substitute - it is silently wrong rather than loudly broken.

ADDRESSES ARE ARM PHYSICAL. rtl/mister/ddr3_mux.sv puts REGION at
DDRAM_ADDR[28:25] = 4'b0011 and DDRAM_ADDR counts 64-BIT WORDS, so the window
starts at byte 0x30000000 and the three regions inside it are:

    0x30000000  main memory  (64 MB, sized for the largest OSD selection)
    0x34000000  frame buffer (16 MB)
    0x35000000  boot PROM    (512 KB)

Usage (on the MiSTer):
    ddr3_peek.py 0x35000000 0x40            # hex dump 64 bytes
    ddr3_peek.py 0x34000000 0x100000 -o fb  # write a megabyte to a file
    ddr3_peek.py 0x30000000 0x1000 --stats  # nonzero byte count only
"""
import argparse
import mmap
import os
import sys

PAGE = 4096


def read_phys(phys, length):
    base = phys & ~(PAGE - 1)
    off = phys - base
    span = ((off + length + PAGE - 1) // PAGE) * PAGE
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    finally:
        os.close(fd)
    try:
        return m[off:off + length]
    finally:
        m.close()


def hexdump(data, base):
    for i in range(0, len(data), 16):
        row = data[i:i + 16]
        hexs = " ".join(f"{b:02x}" for b in row)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"{base + i:08x}  {hexs:<47}  |{text}|")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addr")
    ap.add_argument("length")
    ap.add_argument("-o", "--out", help="write raw bytes to this file instead")
    ap.add_argument("--stats", action="store_true",
                    help="print nonzero byte count and the distinct values seen")
    a = ap.parse_args()
    phys = int(a.addr, 0)
    length = int(a.length, 0)

    # Read in chunks: one mapping of 16 MB is fine, but a whole region is not.
    CH = 1 << 20
    out = open(a.out, "wb") if a.out else None
    nonzero = 0
    values = set()
    first = None
    done = 0
    while done < length:
        n = min(CH, length - done)
        buf = read_phys(phys + done, n)
        if first is None:
            first = buf[:min(256, len(buf))]
        if out:
            out.write(buf)
        if a.stats:
            nonzero += sum(1 for b in buf if b)
            values.update(buf)
        done += n
    if out:
        out.close()
        print(f"wrote {done} bytes from 0x{phys:08x} to {a.out}")
    if a.stats:
        print(f"0x{phys:08x}+0x{length:x}: {nonzero} nonzero bytes "
              f"({100.0 * nonzero / max(1, length):.3f}%), "
              f"{len(values)} distinct values")
        if len(values) <= 16:
            print("  values:", " ".join(f"{v:02x}" for v in sorted(values)))
    if not out and not a.stats:
        hexdump(first[:length], phys)


if __name__ == "__main__":
    sys.exit(main())
