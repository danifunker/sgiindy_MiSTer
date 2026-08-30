#!/usr/bin/env python3
"""Zero the core's MAIN MEMORY window from the ARM. RUNS ON THE DEVICE.

THIS EXISTS BECAUSE THE MACHINE'S OWN MEMORY CLEAR IS A LIE. The PROM clears
memory through the MC's GIO DMA engine, and in this core that engine is a stub:
its registers behave, a start reports instant completion, and no data moves. So
the guest's "cleared" RAM is whatever DDR3 held when the core started - which,
because DDR3 survives a core reload and a warm reboot of the HPS, is whatever
the PREVIOUS run left behind.

That is not a theoretical hazard. A machine that had drawn its whole boot screen
stopped dead at rex3Clear for a whole evening, through three identical
relaunches and a reboot, on a bitstream that was md5-verified against the
release three ways. Zeroing this region and relaunching the SAME bitstream
brought the boot screen back on the first try: 1 colour index in the frame
buffer became 168. See docs/08-resume-prompt.md.

So: run this before a launch you intend to draw conclusions from, the same way
fb_poke.py marks the frame buffer. A boot on inherited memory is not a boot of
the build you think you are testing.

MAIN MEMORY ONLY - 0x30000000..0x34000000. The frame buffer at 0x34000000 is
fb_poke.py's job, and zeroing the PROM at 0x35000000 would stop the machine
booting at all. Addresses are ARM physical; see ddr3_peek.py for the map.

Usage (on the MiSTer):
    memclear.py            # zero it
    memclear.py 0xa5       # fill with a marker instead, to prove the converse
"""
import mmap
import os
import sys

BASE = 0x30000000
SIZE = 64 << 20
CHUNK = 1 << 22


def main():
    fill = (int(sys.argv[1], 0) & 0xFF) if len(sys.argv) > 1 else 0
    chunk = bytes([fill]) * CHUNK
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        done = 0
        while done < SIZE:
            n = min(CHUNK, SIZE - done)
            # One mapping per chunk: a single 64 MB mapping of /dev/mem over the
            # reserved window is refused on this kernel, and chunking is free.
            m = mmap.mmap(fd, n, mmap.MAP_SHARED,
                          mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE + done)
            try:
                m[0:n] = chunk[:n]
            finally:
                m.close()
            done += n
    finally:
        os.close(fd)
    print(f"filled 0x{BASE:08x}+0x{SIZE:x} with 0x{fill:02x}")


if __name__ == "__main__":
    sys.exit(main())
