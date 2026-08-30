#!/usr/bin/env python3
"""Hammer the shared DDR3 from the ARM. RUNS ON THE DEVICE.

The CPU test suite passes on this board, and a PROM boot fails about four times
in ten. The largest difference between them is not the CPU: it is how many
masters are on the memory. The suite never programs Newport, so the display's
frame buffer reader is idle and the CPU has DDR3 to itself. A boot programs it,
and docs/18 measures that reader saturating the port.

So this adds a second heavy reader while the suite runs. It is not the same
master - it contends at the HPS end rather than through ddr3_mux's arbiter -
but it competes for the same controller, and if memory pressure is what breaks
the machine then 2160 checks are a far better detector of it than a boot that
only fails 40% of the time.

READS ONLY, and out of the frame buffer region, which the suite does not touch.
Writing anywhere near the suite's image would prove nothing except that this
script can corrupt memory.
"""
import mmap
import os
import sys
import time

FB   = 0x34000000
SPAN = 16 << 20
CH   = 1 << 22


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 180.0
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    maps = []
    try:
        for off in range(0, SPAN, CH):
            maps.append(mmap.mmap(fd, CH, mmap.MAP_SHARED, mmap.PROT_READ,
                                  offset=FB + off))
    finally:
        os.close(fd)

    # Say so IMMEDIATELY, and flush. The caller checks this log to decide
    # whether the run it just did was actually contended, and a generator that
    # only speaks when it finishes leaves an empty file for the whole run - so
    # "no log" reads as "never started" when it means "still going". That
    # ambiguity turned a null result into a reported pass once.
    print("hammering %d MB from 0x%08x" % (SPAN >> 20, FB), flush=True)

    end = time.time() + seconds
    passes = 0
    try:
        while time.time() < end:
            for m in maps:
                # Touch one byte per 64-byte line: the point is transactions,
                # not bytes, and a full copy would spend its time in memcpy.
                m[0:CH:64]
            passes += 1
    finally:
        for m in maps:
            m.close()
    print("hammered %d MB x %d passes" % (SPAN >> 20, passes))


if __name__ == "__main__":
    sys.exit(main())
