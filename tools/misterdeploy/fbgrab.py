#!/usr/bin/env python3
"""Grab the colour-index plane of Newport's frame buffer out of DDR3. RUNS ON THE DEVICE.

Reads the drawing planes straight out of the DDR3 the HPS shares with the FPGA
and writes one byte per pixel - the colour index - to /tmp/fb.raw, 1280x1024,
which tools/misterdeploy/fbpng.py turns into a picture on the host. It bypasses
the whole display pipeline, so "the login screen is in the grab" is NOT "the
login screen is on the monitor" - always take scripts/grab.sh too (docs/33).

LAYOUT. A 32-bit slot per pixel on a 2048-pixel stride, two pixels to a 64-bit
word with the even pixel in the low half (np_rex3.sv). As the ARM sees it the
index of pixel x is byte (y * 2048 + x) * 4 - linear in x - and fb_poke.py
writes the same shape.

Usage (on the MiSTer):
    python3 fbgrab.py            # -> /tmp/fb.raw
    python3 fbgrab.py OUT        # -> OUT
"""
import importlib.util, sys
spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W, H, S, FB, BPP = 1280, 1024, 2048, 0x34000000, 4
out = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/fb.raw", "wb")
for y in range(H):
    out.write(m.read_phys(FB + (y * S) * BPP, W * BPP)[0::BPP])
out.close()
print("ok")
