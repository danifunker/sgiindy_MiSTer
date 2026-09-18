#!/usr/bin/env python3
"""rx3trace.py - write, read and synthesise RX3TRACE files: REX3 bus traces.

The format is shared by IRIS's trace writer and the core's replay,
verilator/tb_newport_replay.cpp (`make -C verilator newportreplay`).
Little-endian throughout:

  header  16 bytes: the ASCII bytes "RX3TRACE", u32 version = 1,
          u32 record size = 24
  record  u8 kind, u8 flags, u16 reserved, u32 offset, u64 data, u64 stamp
  kind    0 CPU write 32   1 CPU write 64   2 CPU read 32   3 CPU read 64
          4 DMA write 64   5 DMA read 64    6 MARKER
  offset  byte offset in REX3's 8 KB window as addressed, the GO alias bit
          0x800 included; 8-aligned for the 64-bit kinds
  data    writes: the value (a 32-bit one in bits 31:0; a 64-bit one with
          bits 63:32 = the word at the lower address); reads: the value IRIS
          returned; MARKER: the dump index
  stamp   monotonic, informational

At a MARKER the two plane sets are dumped as 2048 x 1024 u32 little-endian
each, IRIS's fb_rgb / fb_aux layout: pixel (x, y) at y * 2048 + x.

  python3 tools/rx3trace.py synth OUTDIR
      OUTDIR/synth.rx3, and OUTDIR/iris_rgb_NNNN.bin / iris_aux_NNNN.bin:
      the frame buffers IRIS would dump at each of its markers. Marker 0 is a
      filled block and some register reads, marker 1 an image drawn and read
      back by VDMA, marker 2 GL's shapes: a 64-bit XYSTARTI+XYENDI|GO and a
      64-bit colour pair. On the RTL as it is, marker 2 differs (docs/design/rex3-source-audit.md 3.1)
      unless the replay is given --split64.
  python3 tools/rx3trace.py print TRACE [-n N]
      the records, one a line, and a count of each kind
  python3 tools/rx3trace.py stress TRACE [--records N] [--mix draw|regs] [--no-display]
      a large trace for measuring the replay's speed: VC2 loaded with a
      1680 x 1065 timing table over the DCB so the display fetches as it does
      in a real boot trace, then X/GL-like drawing (or register traffic only)
"""
import argparse
import array
import os
import struct
import sys

MAGIC = b"RX3TRACE"
VERSION = 1
RECSIZE = 24
REC = struct.Struct("<BBHIQQ")
KINDS = ["CPU write 32", "CPU write 64", "CPU read 32", "CPU read 64",
         "DMA write 64", "DMA read 64", "MARKER"]
CPU_WR32, CPU_WR64, CPU_RD32, CPU_RD64, DMA_WR64, DMA_RD64, MARKER = range(7)
GO = 0x800

REGS = {
    0x0000: "DRAWMODE1", 0x0004: "DRAWMODE0", 0x0008: "LSMODE", 0x000C: "LSPATTERN",
    0x0010: "LSPATSAVE", 0x0014: "ZPATTERN", 0x0018: "COLORBACK", 0x001C: "COLORVRAM",
    0x0020: "ALPHAREF", 0x0024: "STALL0", 0x0028: "SMASK0X", 0x002C: "SMASK0Y",
    0x0030: "SETUP", 0x0034: "STEPZ", 0x0038: "LSRESTORE", 0x003C: "LSSAVE",
    0x0100: "XSTART", 0x0104: "YSTART", 0x0108: "XEND", 0x010C: "YEND",
    0x0110: "XSAVE", 0x0114: "XYMOVE", 0x0118: "BRESD", 0x011C: "BRESS1",
    0x0120: "BRESOCTINC1", 0x0124: "BRESRNDINC2", 0x0128: "BRESE1", 0x012C: "BRESS2",
    0x0130: "AWEIGHT0", 0x0134: "AWEIGHT1", 0x0138: "XSTARTF", 0x013C: "YSTARTF",
    0x0140: "XENDF", 0x0144: "YENDF", 0x0148: "XSTARTI", 0x014C: "XENDF1",
    0x0150: "XYSTARTI", 0x0154: "XYENDI", 0x0158: "XSTARTENDI",
    0x0200: "COLORRED", 0x0204: "COLORALPHA", 0x0208: "COLORGRN", 0x020C: "COLORBLUE",
    0x0210: "SLOPERED", 0x0214: "SLOPEALPHA", 0x0218: "SLOPEGRN", 0x021C: "SLOPEBLUE",
    0x0220: "WRMASK", 0x0224: "COLORI", 0x0228: "COLORX", 0x022C: "SLOPERED1",
    0x0230: "HOSTRW0", 0x0234: "HOSTRW1", 0x0238: "DCBMODE", 0x0240: "DCBDATA0",
    0x0244: "DCBDATA1", 0x1300: "SMASK1X", 0x1304: "SMASK1Y", 0x1308: "SMASK2X",
    0x130C: "SMASK2Y", 0x1310: "SMASK3X", 0x1314: "SMASK3Y", 0x1318: "SMASK4X",
    0x131C: "SMASK4Y", 0x1320: "TOPSCAN", 0x1324: "XYWIN", 0x1328: "CLIPMODE",
    0x132C: "STALL1", 0x1330: "CONFIG", 0x1338: "STATUS", 0x133C: "USER_STATUS",
    0x1340: "DCBRESET",
}


def reg_name(off):
    return REGS.get(off & ~GO & 0x1FFC, "?") + ("|GO" if off & GO else "")


class TraceWriter:
    def __init__(self, path):
        self.f = open(path, "wb")
        self.f.write(MAGIC + struct.pack("<II", VERSION, RECSIZE))
        self.stamp = 0

    def rec(self, kind, off, data=0, flags=0):
        self.stamp += 1
        self.f.write(REC.pack(kind, flags, 0, off, data & 0xFFFFFFFFFFFFFFFF, self.stamp))

    def wr32(self, off, v):   self.rec(CPU_WR32, off, v & 0xFFFFFFFF)
    def wr64(self, off, v):   self.rec(CPU_WR64, off, v)
    def rd32(self, off, v):   self.rec(CPU_RD32, off, v & 0xFFFFFFFF)
    def rd64(self, off, v):   self.rec(CPU_RD64, off, v)
    def dma_wr(self, off, v): self.rec(DMA_WR64, off, v)
    def dma_rd(self, off, v): self.rec(DMA_RD64, off, v)
    def marker(self, idx):    self.rec(MARKER, 0, idx)

    def close(self):
        self.f.close()


class Planes:
    """IRIS's fb_rgb and fb_aux: 2048 x 1024 u32 each, (x, y) at y * 2048 + x."""
    W, H = 2048, 1024

    def __init__(self):
        assert array.array("I").itemsize == 4
        self.rgb = array.array("I", bytes(4 * self.W * self.H))
        self.aux = array.array("I", bytes(4 * self.W * self.H))

    def set(self, x, y, v):
        self.rgb[y * self.W + x] = v

    def dump(self, rgb_path, aux_path):
        for plane, path in ((self.rgb, rgb_path), (self.aux, aux_path)):
            a = array.array("I", plane)
            if sys.byteorder != "little":
                a.byteswap()
            with open(path, "wb") as f:
                a.tofile(f)


def xy(x, y):
    return ((x & 0xFFFF) << 16) | (y & 0xFFFF)


def synth(outdir):
    os.makedirs(outdir, exist_ok=True)
    t = TraceWriter(os.path.join(outdir, "synth.rx3"))
    fb = Planes()

    def marker(n):
        t.marker(n)
        fb.dump(os.path.join(outdir, "iris_rgb_%04u.bin" % n),
                os.path.join(outdir, "iris_aux_%04u.bin" % n))

    # 8-bit colour index in the drawing planes, logic op SRC, alpha test off.
    CI8 = (3 << 28) | (7 << 12) | (1 << 3) | 1
    # DRAW, BLOCK, DOSETUP, STOPONX, STOPONY.
    BLOCK = 2 | (1 << 2) | (1 << 5) | (1 << 8) | (1 << 9)

    def ci8(v):
        # An 8-bit index lands in both buffers of its planes, byte 2 clear.
        return (v << 8) | v

    # ---- marker 0: a filled block, and register reads --------------------------
    t.wr32(0x1324, 0x10001000)       # XYWIN: the identity window
    t.wr32(0x1328, 0x00001E00)       # CLIPMODE: every window ID allowed
    t.wr32(0x1320, 0x000003FF)       # TOPSCAN
    t.wr32(0x0114, 0)                # XYMOVE
    t.wr32(0x0220, 0x00FFFFFF)       # WRMASK
    t.wr32(0x0000, CI8)
    t.wr32(0x0224, 0x5A)             # COLORI
    t.wr32(0x0004, BLOCK)
    t.wr32(0x0150, xy(10, 10))
    t.wr32(0x0154 | GO, xy(49, 29))
    for y in range(10, 30):
        for x in range(10, 50):
            fb.set(x, y, ci8(0x5A))
    t.rd32(0x0004, BLOCK)
    t.rd32(0x0220, 0x00FFFFFF)
    t.rd32(0x133C, 0x00000003)       # USER_STATUS, idle, as IRIS answers: VERSION 3
    t.rd64(0x0000, (CI8 << 32) | BLOCK)   # a doubleword load: {DRAWMODE1, DRAWMODE0}
    marker(0)

    # ---- marker 1: an image by VDMA, and the first row read back ----------------
    t.wr32(0x0000, CI8 | (1 << 7) | (1 << 8) | (1 << 10))   # RWPACKED, HOSTDEPTH 8, RWDOUBLE
    t.wr32(0x0004, 2 | (1 << 2) | (1 << 6) | (1 << 8) | (1 << 9))   # DRAW BLOCK COLORHOST
    t.wr32(0x0120, 0)                                        # BRESOCTINC1: x, y increasing
    t.wr32(0x0150, xy(100, 40))
    t.wr32(0x0154, xy(115, 43))

    def pix(x, y):
        return (0x80 + (x - 100) + 16 * (y - 40)) & 0xFF

    def beat(x0, y):
        b = 0
        for j in range(8):
            b = (b << 8) | pix(x0 + j, y)
        return b

    for y in range(40, 44):
        for x0 in (100, 108):
            t.dma_wr(0x0230 | GO, beat(x0, y))
            for j in range(8):
                fb.set(x0 + j, y, ci8(pix(x0 + j, y)))
    t.wr32(0x0004, 1 | (1 << 2) | (1 << 8) | (1 << 9))      # READ BLOCK STOPONX STOPONY
    t.wr32(0x0150, xy(100, 40))
    t.wr32(0x0154, xy(115, 40))
    for x0 in (100, 108):
        t.dma_rd(0x0230 | GO, beat(x0, 40))
    marker(1)

    # ---- marker 2: GL's doubleword stores --------------------------------------
    t.wr32(0x0000, CI8)
    t.wr32(0x0004, BLOCK)
    t.wr32(0x0224, 0x33)
    t.wr32(0x0154, xy(190, 55))      # a stale end point
    t.wr64(0x0150 | GO, (xy(200, 60) << 32) | xy(231, 69))
    for y in range(60, 70):
        for x in range(200, 232):
            fb.set(x, y, ci8(0x33))
    t.wr64(0x0208, (0x00012345 << 32) | 0x0006789A)          # COLORGRN + COLORBLUE
    t.rd32(0x0208, 0x00012345)
    t.rd32(0x020C, 0x0006789A)
    marker(2)
    t.close()
    print("rx3trace: wrote %s (%d records) and the frame buffers IRIS would dump at markers 0-2"
          % (os.path.join(outdir, "synth.rx3"), t.stamp))


def program_vc2(t):
    """Load VC2 with a 1680 x 1065 timing table through REX3's Display Control
    Bus, as the PROM does, and start it: the display then fetches the frame
    buffer on every visible line. The shape of np_timing.h's 1280 x 1024
    tables: VIS_LN (state A bit 0) 1296 pixels a line, DSPLY_EN (A bit 2)
    starting with it and running on to 1318 - so both the RTL that takes its
    display enable from DSPLY_EN and the one that takes it from VIS_LN see a
    picture (tb_newport.cpp's test 9 uses the same table)."""
    def reg(idx, val):
        t.wr32(0x0238, 0)                               # DCBMODE: VC2, CRS 0, one 32-bit transfer
        t.wr32(0x0240, (idx << 24) | (val << 8))        # DCBDATA0: index [28:24], data [23:8]

    def ram(addr, words):
        reg(0x07, addr)                                 # RAM_ADDR
        t.wr32(0x0238, (3 << 4) | 2)                    # DCBMODE: CRS 3 (the SRAM), 16 bits
        for w in words:
            t.wr32(0x0240, w << 16)                     # left-aligned; RAM_ADDR advances

    # Run words (vc2.pdf 3.4.1, verilator/tb_vc2.cpp): durations in two-pixel
    # clocks, the channels active low - display enable A[2], vsync C[1], hsync C[2].
    def w0(dur, a, has_bc, eol):
        return (0x8000 if eol else 0) | ((dur & 0x7F) << 8) | (0 if has_bc else 0x80) | (a & 0x7F)

    def w1(b, c, eol):
        return (0x8000 if eol else 0) | ((b & 0x7F) << 8) | 0x80 | (c & 0x7F)

    IDLE = 0x7F
    A_VIS = IDLE & ~(1 << 0) & ~(1 << 2)                # VIS_LN and DSPLY_EN
    A_EN = IDLE & ~(1 << 2)                             # DSPLY_EN alone
    C_HS = IDLE & ~(1 << 2)
    C_VS = IDLE & ~(1 << 1)
    C_HSVS = C_HS & ~(1 << 1)

    def line(vis, c_sync, c_rest):
        v = [w0(12, IDLE, True, False), w1(IDLE, c_rest, False),
             w0(57, IDLE, True, False), w1(IDLE, c_sync, False),
             w0(112, IDLE, True, False), w1(IDLE, c_rest, False)]
        for d in (127, 127, 127, 127, 127, 13):         # 648 units: 1296 pixels
            v.append(w0(d, A_VIS if vis else IDLE, False, False))
        v.append(w0(11, A_EN if vis else IDLE, True, True))   # 22 more: 1318
        v.append(w1(IDLE, c_rest, True))
        return v

    seqs = [line(False, C_HS, IDLE), line(False, C_HSVS, C_VS),
            line(False, C_HS, IDLE), line(True, C_HS, IDLE)]
    addr, starts = 0, []
    for s in seqs:                                      # each line points at itself
        starts.append(addr)
        ram(addr, s + [addr])
        addr += len(s) + 1
    ram(0x0400, [starts[0], 2, starts[1], 3, starts[2], 36, starts[3], 1024, 0, 0])
    reg(0x00, 0x0400)                                   # VIDEO_ENTRY: the frame table
    reg(0x1F, 0x0001)                                   # CONFIG: release soft reset
    reg(0x10, 0x0004)                                   # DC_CONTROL: video timing on


def stress(path, records, display, mix, seed):
    """A large trace for measuring the replay's speed. `draw` is a rough
    stand-in for X and GL traffic - small blocks, short lines, VDMA images,
    REX3WAIT polls, register writes; `regs` has no drawing at all, which
    measures the cost of a record itself."""
    import random
    rnd = random.Random(seed)
    t = TraceWriter(path)
    if display:
        program_vc2(t)
    CI8 = (3 << 28) | (7 << 12) | (1 << 3) | 1
    STOP = (1 << 8) | (1 << 9)
    BLOCK = 2 | (1 << 2) | (1 << 5) | STOP
    LINE = 2 | (2 << 2) | (1 << 5) | STOP
    for off, v in ((0x1324, 0x10001000), (0x1328, 0x1E00), (0x1320, 0x3FF), (0x0114, 0),
                   (0x0220, 0xFFFFFF), (0x0000, CI8), (0x0120, 0)):
        t.wr32(off, v)
    while t.stamp < records:
        # `regs`: REX3WAIT polls and register writes only.
        r = rnd.random() if mix == "draw" else rnd.choice((0.80, 0.99))
        x, y = rnd.randrange(0, 1200), rnd.randrange(0, 1000)
        if r < 0.35:                                    # a small block
            t.wr32(0x0004, BLOCK)
            t.wr32(0x0224, rnd.randrange(256))
            t.wr32(0x0150, xy(x, y))
            t.wr32(0x0154 | GO, xy(x + rnd.randrange(64), y + rnd.randrange(16)))
        elif r < 0.55:                                  # a short line
            t.wr32(0x0004, LINE)
            t.wr32(0x0224, rnd.randrange(256))
            t.wr32(0x0150, xy(x, y))
            t.wr32(0x0154 | GO, xy(x + rnd.randrange(-40, 40), y + rnd.randrange(-20, 20)))
        elif r < 0.70:                                  # a 16 x 4 image by VDMA
            t.wr32(0x0000, CI8 | (1 << 7) | (1 << 8) | (1 << 10))
            t.wr32(0x0004, 2 | (1 << 2) | (1 << 6) | STOP)
            t.wr32(0x0150, xy(x, y))
            t.wr32(0x0154, xy(x + 15, y + 3))
            for _ in range(8):
                t.dma_wr(0x0230 | GO, rnd.getrandbits(64))
            t.wr32(0x0000, CI8)
        elif r < 0.85:                                  # REX3WAIT
            t.rd32(0x133C, 0x3)
        else:                                           # register writes that draw nothing
            t.wr32(rnd.choice((0x0018, 0x001C, 0x000C, 0x0014)),   # COLORBACK COLORVRAM
                   rnd.getrandbits(32))                            # LSPATTERN ZPATTERN
    t.marker(0)
    t.close()
    print("rx3trace: wrote %s (%d records, display %s, mix %s)"
          % (path, t.stamp, "on" if display else "off", mix))


def print_trace(path, limit):
    counts = {}
    with open(path, "rb") as f:
        hdr = f.read(16)
        if len(hdr) < 16 or hdr[:8] != MAGIC:
            sys.exit("%s: not an RX3TRACE file" % path)
        version, recsize = struct.unpack("<II", hdr[8:16])
        print("%s: version %d, %d-byte records" % (path, version, recsize))
        n = 0
        while True:
            b = f.read(recsize)
            if len(b) < recsize:
                if b:
                    print("(a partial record of %d bytes at the end)" % len(b))
                break
            kind, flags, _, off, data, stamp = REC.unpack(b[:24])
            counts[kind] = counts.get(kind, 0) + 1
            if limit is None or n < limit:
                name = KINDS[kind] if kind < len(KINDS) else "kind %d" % kind
                if kind == MARKER:
                    print("%8d  %-12s index %d  (stamp %d)" % (n, name, data, stamp))
                else:
                    width = 8 if kind in (CPU_WR32, CPU_RD32) else 16
                    print("%8d  %-12s 0x%04x %-16s %0*x  flags %02x  stamp %d"
                          % (n, name, off, reg_name(off), width, data, flags, stamp))
            n += 1
    print("%d records:" % n, ", ".join("%d %s" % (c, KINDS[k] if k < len(KINDS) else "kind %d" % k)
                                         for k, c in sorted(counts.items())))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("synth", help="write a synthetic trace and the dumps IRIS would make")
    s.add_argument("outdir")
    p = sub.add_parser("print", help="list a trace's records")
    p.add_argument("trace")
    p.add_argument("-n", type=int, default=None, help="records to list (default all)")
    st = sub.add_parser("stress", help="a large trace for measuring the replay's speed")
    st.add_argument("trace")
    st.add_argument("--records", type=int, default=1000000)
    st.add_argument("--mix", choices=("draw", "regs"), default="draw")
    st.add_argument("--no-display", action="store_true", help="leave VC2 unprogrammed")
    st.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    if a.cmd == "synth":
        synth(a.outdir)
    elif a.cmd == "stress":
        stress(a.trace, a.records, not a.no_display, a.mix, a.seed)
    else:
        print_trace(a.trace, a.n)


if __name__ == "__main__":
    main()
