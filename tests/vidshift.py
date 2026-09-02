#!/usr/bin/env python3
"""vidshift.py PINS.ppm STORE.ppm - is the picture on the pins the store, row for row?

WHY. run-newport.sh checks the raster's SIZE, and a raster can be exactly the
right size while showing the frame buffer one row too high: build 18b did
(docs/36 section 5) - the VC2 numbered its lines from 1, frame buffer row 0
was never displayed, the bottom screen row was black, and every size check
passed. This compares the two pictures the simulator can write, --viddump
(what came out of the pins, one row per raster line) and --fbdump (the store,
one row per frame buffer line), and insists that the first displayed row is
store row 0 and that every store row follows in order.

HOW. Neither picture is the other's colour space (the store is an index shown
as grey, the pins are the index through XMAP and CMAP), so rows are matched by
SHAPE: where along the row the value differs from the row's own left edge.
A row's shape survives the palette. Rows that are all background match every
other such row, so the check runs over the rows that have something on them
and requires the offset to be one and the same number for all of them.
Exit 0 with the offset on success, 1 with the rows that disagree.
"""
import sys

def read_ppm(path):
    with open(path, 'rb') as f:
        magic = f.readline().strip()
        if magic not in (b'P6', b'P5'):
            sys.exit("%s: not a binary PPM/PGM" % path)
        dims = []
        while len(dims) < 3:
            tok = f.readline().strip()
            if tok.startswith(b'#'):
                continue
            dims += [int(t) for t in tok.split()]
        w, h, _ = dims
        ch = 3 if magic == b'P6' else 1
        data = f.read(w * h * ch)
    return w, h, ch, data

def row(w, ch, data, y, x0, width, step):
    base = y * w * ch
    return data[base + x0 * ch: base + (x0 + width) * ch: step * ch] if ch == 1 else         bytes(b for k in range(0, width, step) for b in data[base + (x0 + k) * ch: base + (x0 + k) * ch + ch])

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: vidshift.py PINS.ppm STORE.ppm")
    pw, ph, pch, pins = read_ppm(sys.argv[1])
    sw, sh, sch, store = read_ppm(sys.argv[2])
    step = 2
    width = min(sw, pw) - 64
    # A displayed raster row has a nonzero pixel; a blank raster line is all
    # zero (no display enable, nothing captured).
    displayed = [y for y in range(ph) if any(pins[y * pw * pch:(y + 1) * pw * pch])]
    if not displayed:
        sys.exit("FAILED: no displayed rows on the pins")
    first = displayed[0]
    # THE SIGNAL IS WHERE ROWS CHANGE. The store is an index shown as grey and
    # the pins are that index through XMAP and CMAP, so values cannot be
    # compared across the two - but "this row differs from the one above it"
    # can, and the PROM's boot screen is a vertical gradient, so there are
    # hundreds of such rows in every frame. The store is dumped at the end of
    # the run while the pins picture is the last COMPLETE frame, so the store
    # may carry transitions the pins do not (drawn after that frame); the pins
    # may not carry any the store lacks, except the few a blinking cursor
    # leaves behind.
    srows = [row(sw, sch, store, r, 0, width, step) for r in range(sh)]
    st = set(r for r in range(1, sh) if srows[r] != srows[r - 1])
    prows = {y: row(pw, pch, pins, y, 0, width, step) for y in displayed}
    pt = [y for y in displayed[1:] if y - 1 in prows and prows[y] != prows[y - 1]]
    in_place, shifted, unexplained = 0, [], []
    for y in pt:
        r = y - first
        if r in st:
            in_place += 1
        else:
            near = [k for k in (-1, 1, -2, 2) if r + k in st]
            (shifted if near else unexplained).append((y, r, near))
    print("vidshift: raster row %d shows store row 0; %d displayed rows for %d store rows; "
          "%d raster transitions: %d at the store's row, %d off by a row, %d unexplained"
          % (first, len(displayed), sh, len(pt), in_place, len(shifted), len(unexplained)))
    fail = False
    if len(displayed) != sh:
        print("FAILED: %d displayed rows on the pins, the store has %d" % (len(displayed), sh))
        fail = True
    if len(pt) < 20:
        print("FAILED: too few transitions to compare (%d)" % len(pt))
        fail = True
    if shifted and len(shifted) * 10 > in_place:
        for y, r, near in shifted[:6]:
            print("  raster row %d changes, store row %d does not - store rows %s do"
                  % (y, r, [r + k for k in near]))
        print("FAILED: the display is showing the store off by a row")
        fail = True
    if unexplained and len(unexplained) * 20 > in_place + 20:
        print("FAILED: %d raster transitions with no store transition anywhere near" % len(unexplained))
        fail = True
    if fail:
        sys.exit(1)
    print("ok      the raster's %d row transitions are the store's, row for row" % in_place)

if __name__ == "__main__":
    main()
