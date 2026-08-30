#!/usr/bin/env python3
"""Render a frame buffer grab (1280x1024 colour indices, one byte each) as PNG.

WHY THIS EXISTS. The PROM's console is drawn into the frame buffer, so the only
way to read what the machine said is to read the pixels. A screenshot off the
MiSTer's HDMI works for "did it draw", but the text is small, the scaler has
been at it, and the OSD is not captured at all. `fbgrab.py` on the board writes
the raw index plane; this turns it into something legible.

Two renderings, because they answer different questions:

  --mode text   index 7 (the PROM's console text) black on white, everything
                else white. This is the one to READ. A panic box and a healthy
                prompt are both a few hundred to a few thousand black pixels,
                and the words come out crisp because no antialiasing was ever
                involved - the store holds an index, not a colour.
  --mode grey   the raw index as grey. This is the one for "what is on the
                screen at all", and it is what shows a boot screen that drew.

--crop X,Y,W,H trims first, because a 1280x1024 page of mostly-background
scaled to fit is unreadable and the console lives in a known band.
"""
import argparse, sys
from PIL import Image

W, H = 1280, 1024

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw"); ap.add_argument("out")
    ap.add_argument("--mode", default="text", choices=["text", "grey", "index"])
    ap.add_argument("--crop", default=None, help="X,Y,W,H")
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--index", type=int, default=7, help="the index --mode text inks")
    a = ap.parse_args()

    data = open(a.raw, "rb").read()
    if len(data) < W * H:
        sys.exit("short grab: %d bytes, want %d" % (len(data), W * H))
    img = Image.frombytes("L", (W, H), data[:W * H])

    if a.crop:
        x, y, w, h = (int(v) for v in a.crop.split(","))
        img = img.crop((x, y, x + w, y + h))

    if a.mode == "text":
        img = img.point(lambda v: 0 if v == a.index else 255)
    elif a.mode == "grey":
        # spread the low indices the PROM actually uses over the whole range
        img = img.point(lambda v: min(255, v * 12))

    if a.scale != 1.0:
        img = img.resize((int(img.width * a.scale), int(img.height * a.scale)),
                         Image.NEAREST)
    img.convert("L").save(a.out)
    print("wrote %s  %dx%d" % (a.out, img.width, img.height))

main()
