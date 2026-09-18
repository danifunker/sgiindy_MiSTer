"""fb32ana.py FB32 - find damaged glyphs in an fbgrab32.py dump of the Console.

The Console is an 8-bit colour-index window: its pixel is the LOW BYTE of the
drawing slot; bits 23:8 hold whatever 24-bit drawing was there before (the
login screen) and differ across the window. So everything here works on
slot & 0xFF. The text grid is 8 x 15; its phase is found as the column and row
that hold the fewest text pixels (the gap between cells). Cells are compared
against the glyphs that occur often; a rare cell that is a near-subset of a
common glyph is a damaged copy of it, and the full slots at its differing
pixels say how it went wrong.
"""
import struct
import sys
from collections import Counter

d = open(sys.argv[1], "rb").read()
x0, y0, w, h = struct.unpack_from("<4I", d, 0)
n = w * h
rgb = struct.unpack_from(f"<{n}I", d, 16)
aux = struct.unpack_from(f"<{n}I", d, 16 + 4 * n)
at = lambda a, x, y: a[(y - y0) * w + (x - x0)]
ci = lambda x, y: at(rgb, x, y) & 0xFF

# The Console interior, well inside the rectangle.
IX0, IX1, IY0, IY1 = x0 + 45, x0 + w - 20, y0 + 45, y0 + h - 10
c = Counter(ci(x, y) for y in range(IY0, IY1) for x in range(IX0, IX1))
(bg, _), (fg, _) = c.most_common(2)
print(f"interior x {IX0}..{IX1} y {IY0}..{IY1}: index counts", dict(c.most_common(5)),
      f"-> background {bg:#04x}, text {fg:#04x}")
lit = lambda x, y: ci(x, y) == fg

colph = min(range(8), key=lambda p: sum(lit(x, y) for x in range(IX0, IX1) if (x - p) % 8 == 7
                                        for y in range(IY0, IY1)))
rowph = min(range(15), key=lambda p: sum(lit(x, y) for y in range(IY0, IY1) if (y - p) % 15 == 0
                                         for x in range(IX0, IX1)))
cx0 = IX0 + ((colph - IX0) % 8)
cy0 = IY0 + ((rowph - IY0) % 15)
print(f"cells start at x {cx0} (x%8={cx0 % 8}), y {cy0}; 8 x 15")

cells = {}
for cy in range(cy0, IY1 - 15, 15):
    for cx in range(cx0, IX1 - 8, 8):
        bm = tuple(tuple(lit(cx + i, cy + j) for i in range(8)) for j in range(15))
        if any(any(r) for r in bm):
            cells[(cx, cy)] = bm
freq = Counter(cells.values())
common = {bm: k for bm, k in freq.items() if k >= 5}
px = lambda bm: {(i, j) for j in range(15) for i in range(8) if bm[j][i]}
print(f"{len(cells)} non-empty cells, {len(common)} glyphs occurring >= 5 times:",
      sorted(common.values(), reverse=True)[:12])

damaged = []
for (cx, cy), bm in cells.items():
    if freq[bm] >= 3:
        continue
    p = px(bm)
    best = min(((len(px(g) ^ p), g) for g in common), default=None)
    if best is None or best[0] > 12:
        continue
    g = best[1]
    miss = sorted(px(g) - p)
    extra = sorted(p - px(g))
    damaged.append((cx, cy, miss, extra))

print(f"\n{len(damaged)} damaged cells (<= 12 pixels from a common glyph)")
xs = Counter()
for cx, cy, miss, extra in sorted(damaged, key=lambda t: (t[1], t[0])):
    col = (cx - cx0) // 8
    print(f"cell col {col:2d} x {cx} y {cy}: missing {[(i, j) for i, j in miss]} extra {[(i, j) for i, j in extra]}")
    for (i, j) in (miss + extra)[:6]:
        x, y = cx + i, cy + j
        nb = " ".join(f"{at(rgb, xx, y):08x}" for xx in (x - 1, x, x + 1))
        print(f"   {'MISS' if (i, j) in miss else 'XTRA'} ({x},{y}) x%2={x % 2} x%8={x % 8} "
              f"slots[x-1,x,x+1] {nb}  aux {at(aux, x, y):08x}")
        xs[x] += 1
print("\nmissing/extra pixel x histogram:", sorted(xs.items()))
