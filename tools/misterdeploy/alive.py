#!/usr/bin/env python3
"""Is the guest CPU still running? RUNS ON THE DEVICE.

WHY THIS IS NEEDED. Once Newport is fitted the console is the frame buffer, so
a machine that has hung after clearing the screen and a machine that is quietly
working both look like the same black rectangle. classify.py answers "did it
draw"; nothing answered "is it still executing".

WHAT IT MEASURES. The PROM's data and stack live around 0xa8740000, which is
KSEG1 over SGI physical 0x08740000, and rtl/sgi/sgi_indy.sv's RAM_BASE makes
that ARM physical 0x30740000. A MIPS core executing anything at all writes its
stack; a wedged one does not. So: two samples of that window a few seconds
apart, and the count of bytes that moved.

A nonzero count means the CPU is executing. Zero across several seconds means
it is spinning in registers, halted, or dead - which are not distinguishable
from here, but all three are "not making progress".
"""
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

BASE = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x30740000
SPAN = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x10000
GAP  = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0

a = m.read_phys(BASE, SPAN)
time.sleep(GAP)
b = m.read_phys(BASE, SPAN)
diff = sum(1 for x, y in zip(a, b) if x != y)
first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), None)
print("%s over %.1fs at 0x%08x+0x%x: %d bytes moved%s"
      % ("ALIVE" if diff else "STATIC", GAP, BASE, SPAN, diff,
         "" if first is None else "  first at +0x%x" % first))
