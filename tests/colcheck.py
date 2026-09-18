#!/usr/bin/env python3
"""colcheck.py SCREEN.png FB.raw - does the monitor show the frame buffer
column for column?

SCREEN.png is scripts/grab.sh's capture of the MiSTer scaler's output
(1280x1024 RGB); FB.raw is tools/misterdeploy/fbgrab.py's colour-index plane,
frame buffer columns 0..1279 of rows 0..1023, one byte a pixel. IRIX draws the
desktop in frame buffer columns 8..1287 (bt445_bug_xbias = 8), and since
build 44 the display window is exactly those 1280 columns, so screen column X
must be frame buffer column X + 8 everywhere. Before build 44 the display
enable was 1318 pixels wide and the scaler squeezed it into 1280, dropping a
column every ~34 - which looked like damaged glyphs (docs/design/rex3-source-audit.md 3.6).

The palette is learned from the pictures themselves - each colour index is
given the screen colour it shows most often at the offset being tried - so
nothing about XMAP9 or CMAP needs to be known. Then, per band of 32 screen
columns, the offset (screen X shows frame buffer X + d) that explains the most
pixels is reported. One offset across every band is a clean display; an
offset that steps from band to band is a dropped (or doubled) column.

Pixels no frame buffer column can explain are expected in small numbers: the
cursor and anything in the overlay or popup planes, which fbgrab.py does not
read. They are counted, not failed.

Exit 0 when every band with enough content agrees on the expected offset
(--want, default 8), else 1.
"""
import argparse
import sys

import numpy as np
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("screen")
    ap.add_argument("fb")
    ap.add_argument("--want", type=int, default=8, help="expected offset d (screen X = fb X + d)")
    ap.add_argument("--band", type=int, default=32)
    ap.add_argument("--dy", type=int, default=0, help="screen row Y shows fb row Y + dy")
    a = ap.parse_args()

    im = Image.open(a.screen).convert("RGB")
    scr = np.asarray(im).astype(np.uint32)
    H, W = scr.shape[0], scr.shape[1]
    S = (scr[:, :, 0] << 16) | (scr[:, :, 1] << 8) | scr[:, :, 2]
    fb = np.fromfile(a.fb, dtype=np.uint8)
    if fb.size != 1280 * 1024:
        sys.exit("%s: %d bytes, expected 1280x1024" % (a.fb, fb.size))
    fb = fb.reshape(1024, 1280).astype(np.int64)
    print("screen %dx%d, frame buffer 1280x1024 (columns 0..1279)" % (W, H))

    rows = slice(max(0, -a.dy), min(H, 1024 - a.dy))
    frows = slice(rows.start + a.dy, rows.stop + a.dy)

    def aligned(d):
        """(screen, fb) pixel arrays for screen X = fb X + d, over the overlap."""
        x0 = max(0, -d)
        x1 = min(W, 1280 - d)
        return S[rows, x0:x1], fb[frows, x0 + d:x1 + d], x0

    # The palette, learned at the expected offset: each index's most common
    # screen colour. A dropped column misaligns a minority of pixels, so the
    # majority still names the right colour.
    s, f, _ = aligned(a.want)
    pal = {}
    key = (f << 24) | s
    vals, counts = np.unique(key.ravel(), return_counts=True)
    best = {}
    for v, c in zip(vals.tolist(), counts.tolist()):
        i = v >> 24
        if i not in best or c > best[i][1]:
            best[i] = (v & 0xFFFFFF, c)
    lut = np.full(256, -1, dtype=np.int64)
    for i, (rgb, _) in best.items():
        lut[i] = rgb
    print("palette: %d indices seen" % len(best))

    # Per band: which offset explains the most pixels, among the columns that
    # carry something other than the band's background (a flat band says
    # nothing about alignment).
    offsets = range(a.want - 6, a.want + 7)
    bands = []
    for bx in range(0, W, a.band):
        cols = slice(bx, min(W, bx + a.band))
        sb = S[rows, cols]
        # informative pixels: horizontal edges in the screen image
        edge = np.zeros(sb.shape, dtype=bool)
        edge[:, 1:] = sb[:, 1:] != sb[:, :-1]
        n_info = int(edge.sum())
        if n_info < 50:
            bands.append((bx, None, 0, n_info))
            continue
        scores = []
        for d in offsets:
            fx0, fx1 = bx + d, min(W, bx + a.band) + d
            if fx0 < 0 or fx1 > 1280:
                scores.append(-1)
                continue
            pred = lut[fb[frows, fx0:fx1]]
            scores.append(int(((pred == sb) & edge).sum()))
        # Repeating text (the probe's "hhhh" rows) scores an offset a whole
        # glyph cell away as well as the right one; a tie goes to the
        # expected offset, so only a strictly better explanation fails.
        k = int(np.argmax(scores))
        kw = list(offsets).index(a.want)
        if scores[kw] == scores[k]:
            k = kw
        bands.append((bx, offsets[k], scores[k], n_info))

    bad = [b for b in bands if b[1] is not None and b[1] != a.want]
    flat = sum(1 for b in bands if b[1] is None)
    print("bands of %d columns: %d with content, %d flat" % (a.band, len(bands) - flat, flat))
    line = []
    for bx, d, sc, n in bands:
        line.append("." if d is None else ("=" if d == a.want else "%+d" % (d - a.want)))
    print("offset by band ('=' is +%d, '.' flat): %s" % (a.want, " ".join(line)))
    for bx, d, sc, n in bad[:12]:
        print("  band at x=%d: offset %+d explains %d of %d edge pixels" % (bx, d, sc, n))

    # Whole-picture agreement at the expected offset.
    s, f, _ = aligned(a.want)
    pred = lut[f]
    miss = int((pred != s).sum())
    print("at offset %+d: %d of %d pixels differ from their frame buffer column's colour"
          % (a.want, miss, s.size))
    if bad:
        print("COLCHECK: FAIL - %d band(s) show a different column than frame buffer X + %d"
              % (len(bad), a.want))
        return 1
    print("COLCHECK: PASS - every band with content shows frame buffer column X + %d" % a.want)
    return 0


if __name__ == "__main__":
    sys.exit(main())
