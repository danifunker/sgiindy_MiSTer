#!/usr/bin/env python3
"""rex3_replay.py - replay REX3's command trace and check the frame buffer.

    tests/rex3_replay.py TRACE FRAMEBUFFER.ppm

The point of this test is that nothing else in the repository can tell a
rasteriser that draws the wrong thing from one that draws the right thing.
A boot with graphics fitted produces a picture, and a picture is only
inspectable by eye - which is how three separate defects survived a whole
session of work:

  * DRAWMODE1's logic op was read from bits [15:12] instead of [31:28], so
    every fill was OR-ed onto the destination instead of replacing it. The
    screen came out as bands of nearly-the-right grey.
  * REX3 had no graphics FIFO and no back-pressure, so the sixteen
    rex3SetAndGo(zpattern) writes Ng1TpDrawbitmap fires back to back landed
    on top of each other. Glyph rows picked up pixels from the row before.
  * USER_STATUS at 0x133C is an alias of STATUS and was answering a register
    of zero, so REX3WAIT never waited for anything.

None of those made the machine hang, fail POST or print anything wrong. All
three are one line of this script.

WHAT IT DOES. `make -C verilator cputest-rex3-debug` builds the simulator
with np_rex3.sv's REX3_DEBUG block enabled: one line per accepted GO with
every register the command depends on. This replays those lines into a model
frame buffer and compares it with the one the run dumped.

WHAT IT DOES NOT DO. The model covers the command set the PROM's console
actually issues - a painted block and a z-pattern-stippled span, both DRAW
BLOCK into the RGB planes with a SRC logic op. Anything else marks the pixels
in its bounding box as unchecked rather than guessing: the auxiliary-plane
passes of rex3Clear (which the dump does not show), the host-sourced reads and
writes of getfbdepth, and screen-to-screen copies. The count of unchecked
pixels is printed, and a run in which that count runs away is itself a
finding.
"""

import re
import sys

FB_STRIDE = 2048           # matches sim_devices.h's VRAM_STRIDE
FB_LINES = 1024
COORD_BIAS = 4096

LINE = re.compile(
    r'\[REX3\] (\d+) dm0=(\w+) dm1=(\w+) xy=\((-?\d+),(-?\d+)\)-\((-?\d+),(-?\d+)\) '
    r'sav=(-?\d+) oct=(\d+) zp=(\w+) ci=(\w+) wm=(\w+) clip=(\w+) s0x=(\w+) s0y=(\w+) '
    r'mv=(\w+) win=(\w+) ts=(\d+)')


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class Cmd:
    __slots__ = ('n', 'dm0', 'dm1', 'x0', 'y0', 'x1', 'y1', 'sav', 'oct', 'zp',
                 'ci', 'wm', 'clip', 's0x', 's0y', 'mv', 'win', 'ts')

    def __init__(self, m):
        g = m.groups()
        self.n = int(g[0])
        self.dm0 = int(g[1], 16)
        self.dm1 = int(g[2], 16)
        self.x0, self.y0 = int(g[3]), int(g[4])
        self.x1, self.y1 = int(g[5]), int(g[6])
        self.sav = int(g[7])
        self.oct = int(g[8])
        self.zp = int(g[9], 16)
        self.ci = int(g[10], 16)
        self.wm = int(g[11], 16)
        self.clip = int(g[12], 16)
        self.s0x, self.s0y = int(g[13], 16), int(g[14], 16)
        self.mv = int(g[15], 16)
        self.win = int(g[16], 16)
        self.ts = int(g[17])

    # ---- DRAWMODE0 -------------------------------------------------------
    @property
    def opcode(self):    return self.dm0 & 3
    @property
    def adrmode(self):   return (self.dm0 >> 2) & 7
    @property
    def dosetup(self):   return (self.dm0 >> 5) & 1
    @property
    def colorhost(self): return (self.dm0 >> 6) & 1
    @property
    def alphahost(self): return (self.dm0 >> 7) & 1
    @property
    def stoponx(self):   return (self.dm0 >> 8) & 1
    @property
    def stopony(self):   return (self.dm0 >> 9) & 1
    @property
    def skipfirst(self): return (self.dm0 >> 10) & 1
    @property
    def skiplast(self):  return (self.dm0 >> 11) & 1
    @property
    def enzp(self):      return (self.dm0 >> 12) & 1
    @property
    def enlsp(self):     return (self.dm0 >> 13) & 1
    @property
    def length32(self):  return (self.dm0 >> 15) & 1
    @property
    def zpopaque(self):  return (self.dm0 >> 16) & 1
    @property
    def shade(self):     return (self.dm0 >> 18) & 1
    @property
    def xyoffset(self):  return (self.dm0 >> 20) & 1
    @property
    def ystride(self):   return (self.dm0 >> 23) & 1

    # ---- DRAWMODE1 -------------------------------------------------------
    @property
    def planes(self):    return self.dm1 & 7
    @property
    def drawdepth(self): return (self.dm1 >> 3) & 3
    @property
    def rgbmode(self):   return (self.dm1 >> 15) & 1
    @property
    def dither(self):    return (self.dm1 >> 16) & 1
    @property
    def blend(self):     return (self.dm1 >> 18) & 1
    @property
    def logicop(self):   return (self.dm1 >> 28) & 15


def modelled(c):
    """Is this a command the model reproduces exactly?"""
    return (c.opcode == 2                      # DRAW
            and c.adrmode == 1                 # BLOCK
            and c.planes == 1                  # the RGB drawing planes
            and c.logicop == 3                 # SRC
            and c.drawdepth in (1, 3)          # 8-bit colour index, or 24-bit
            and not c.rgbmode                  # colour comes from COLORI
            and not c.colorhost and not c.alphahost
            and not c.zpopaque and not c.enlsp
            and not c.shade and not c.dither and not c.blend
            and (c.clip & 0x1E) == 0)          # SMASK1..4 are not traced


def walk(c):
    """Yield (x, y) in frame buffer coordinates for every pixel written.

    This follows np_rex3.sv's DR_SETUP/DR_STEP exactly, including the order in
    which row_done and the octant comparisons are evaluated, because an
    off-by-one in either is the whole point of the test.
    """
    win_x, win_y = s16(c.win >> 16), s16(c.win & 0xFFFF)
    move_x, move_y = s16(c.mv >> 16), s16(c.mv & 0xFFFF)
    move = c.xyoffset

    if c.dosetup:
        dx, dy = c.x1 - c.x0, c.y1 - c.y0
        xdec, ydec = dx < 0, dy < 0
    else:
        xdec, ydec = bool(c.oct & 2), bool(c.oct & 1)

    cx, cy = c.x0, c.y0
    cx_save = c.sav
    zbit = 31
    span_left = 32
    span_clamped = c.length32 and abs(c.x1 - c.x0) >= 32
    y_incr = 2 if c.ystride else 1
    first = True

    ensmask0 = c.clip & 1
    m0x0, m0x1 = s16(c.s0x >> 16), s16(c.s0x & 0xFFFF)
    m0y0, m0y1 = s16(c.s0y >> 16), s16(c.s0y & 0xFFFF)

    # A malformed command must not spin forever; the engine cannot either,
    # because its counters are finite, but the model's are not.
    for _ in range(FB_STRIDE * FB_LINES + 16):
        x_at_end = cx <= c.x1 if xdec else cx >= c.x1
        y_at_end = cy <= c.y1 if ydec else cy >= c.y1
        row_done = c.stoponx and (x_at_end or (span_clamped and span_left <= 1))

        dst_x = cx + win_x + (move_x if move else 0) - COORD_BIAS
        dst_y = (cy + win_y + (move_y if move else 0)
                 - COORD_BIAS - c.ts - 1) % FB_LINES

        clip_ok = 0 <= dst_x < FB_STRIDE
        if ensmask0 and not (m0x0 <= cx <= m0x1 and m0y0 <= cy <= m0y1):
            clip_ok = False

        skip = ((first and c.skipfirst)
                or (row_done and c.skiplast)
                or not clip_ok
                or (c.enzp and not ((c.zp >> zbit) & 1)))
        if not skip:
            yield dst_x, dst_y
        first = False
        if span_left:
            span_left -= 1

        if row_done:
            cx = cx_save
            zbit = 31
            cy = cy - y_incr if ydec else cy + y_incr
            span_left = 32
            if not c.stopony or y_at_end:
                return
        else:
            zbit = 31 if zbit == 0 else zbit - 1
            cx = cx - 1 if xdec else cx + 1
            if not c.stoponx:
                return


def bounding_box(c):
    """Every pixel an unmodelled command could have touched, generously."""
    win_x, win_y = s16(c.win >> 16), s16(c.win & 0xFFFF)
    xs = sorted((c.x0, c.x1, c.sav))
    ys = sorted((c.y0, c.y1))
    x0 = max(0, xs[0] + win_x - COORD_BIAS)
    x1 = min(FB_STRIDE - 1, xs[-1] + win_x - COORD_BIAS)
    for y in range(ys[0], ys[-1] + 1):
        yy = (y + win_y - COORD_BIAS - c.ts - 1) % FB_LINES
        for x in range(x0, x1 + 1):
            yield x, yy


def read_ppm(path):
    with open(path, 'rb') as f:
        assert f.readline().strip() == b'P6', 'not a binary PPM'
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = map(int, line.split())
        f.readline()
        return w, h, f.read()


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    trace_path, fb_path = argv[1], argv[2]

    w, h, data = read_ppm(fb_path)

    # The model, as an index per pixel, and a mask of pixels no modelled
    # command is responsible for. Both are dense: 1280x1024 of bytes is 1.3 MB
    # and the alternative - a dictionary - is forty times that.
    model = bytearray(w * h)
    unchecked = bytearray(w * h)

    def put(x, y, val):
        if 0 <= x < w and 0 <= y < h:
            model[y * w + x] = val

    def taint(x, y):
        if 0 <= x < w and 0 <= y < h:
            unchecked[y * w + x] = 1

    n_cmd = n_model = n_skip = 0
    skipped_kinds = {}
    with open(trace_path) as f:
        for line in f:
            if not line.startswith('[REX3]'):
                continue
            m = LINE.match(line)
            if not m:
                print('unparsable trace line: %s' % line.strip(), file=sys.stderr)
                return 2
            c = Cmd(m)
            n_cmd += 1
            if c.opcode == 0:            # NOOP moves the position, draws nothing
                continue
            # The auxiliary planes are not in the dump at all, so a command
            # that writes them is neither modelled nor a reason to stop
            # checking a pixel.
            if c.planes in (4, 5, 6):
                continue
            if not modelled(c):
                n_skip += 1
                key = 'dm0=%08x dm1=%08x' % (c.dm0, c.dm1)
                skipped_kinds[key] = skipped_kinds.get(key, 0) + 1
                for x, y in bounding_box(c):
                    taint(x, y)
                continue
            n_model += 1
            if c.drawdepth == 1:
                v = c.ci & 0xFF
                src = v | (v << 8) | (v << 16)
            else:
                src = c.ci & 0xFFFFFF
            wm = c.wm & 0xFFFFFF
            for x, y in walk(c):
                if 0 <= x < w and 0 <= y < h:
                    old = model[y * w + x]
                    # The dump only shows the low byte of the 24-bit pixel,
                    # which is the colour index the display path reads.
                    model[y * w + x] = ((old & ~wm) | (src & wm)) & 0xFF
                    unchecked[y * w + x] = 0

    bad = 0
    checked = 0
    n_unchecked = 0
    examples = []
    for y in range(h):
        row = y * w
        for x in range(w):
            i = row + x
            if unchecked[i]:
                n_unchecked += 1
                continue
            checked += 1
            actual = data[i * 3]        # red byte; the model replicates
            if actual != model[i]:
                bad += 1
                if len(examples) < 10:
                    examples.append((x, y, model[i], actual))

    print('commands: %d traced, %d replayed, %d skipped' % (n_cmd, n_model, n_skip))
    for k, v in sorted(skipped_kinds.items(), key=lambda kv: -kv[1])[:6]:
        print('  skipped %6d x %s' % (v, k))
    print('pixels: %d checked, %d unchecked (%.2f%% of the frame)'
          % (checked, n_unchecked, 100.0 * n_unchecked / (w * h)))
    if bad:
        print('MISMATCH: %d pixels differ from the replay' % bad)
        for x, y, want, got in examples:
            print('  (%4d,%4d) model %02x, frame buffer %02x' % (x, y, want, got))
        return 1
    print('every checked pixel matches the command trace')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
