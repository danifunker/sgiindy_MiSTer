#!/usr/bin/env python3
"""Dump every bit of a frame buffer rectangle - both plane sets. RUNS ON THE DEVICE.

fbgrab.py keeps one byte per pixel, the colour index, which is enough to see a
picture and not enough to say what went wrong with one. A pixel that is wrong
in the frame buffer can be wrong in several ways that look alike as an index -
never written, written with the background, written with a stale value, a
partial read-modify-write - and they point at different parts of the write
path. This keeps the whole 32-bit slot of the drawing planes AND of the
auxiliary planes 8 MB above them, for a rectangle small enough to fetch fast.

LAYOUT (see fbgrab.py and np_rex3.sv): a 32-bit slot per pixel on a 2048-pixel
stride, little-endian as the ARM sees it, drawing planes at 0x34000000 and the
auxiliary planes at 0x34800000. The output is a 16-byte header of four
little-endian words (x0, y0, w, h), then the drawing slots row by row, then the
auxiliary slots row by row, all as the ARM read them.

Usage (on the MiSTer):
    python3 fbgrab32.py X0 Y0 W H OUT
"""
import importlib.util
import struct
import sys

spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

STRIDE, FB, AUX = 2048, 0x34000000, 0x34800000
x0, y0, w, h = (int(v, 0) for v in sys.argv[1:5])
with open(sys.argv[5], "wb") as out:
    out.write(struct.pack("<4I", x0, y0, w, h))
    for base in (FB, AUX):
        for y in range(y0, y0 + h):
            out.write(m.read_phys(base + (y * STRIDE + x0) * 4, w * 4))
print("ok")
