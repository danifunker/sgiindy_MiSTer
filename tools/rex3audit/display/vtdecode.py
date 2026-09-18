"""Decode a VC2 video timing table out of the PROM image: frame table at FRAME
(file offset), line table at LINES (file offset, = VC2 RAM word 0 of the table)."""
import struct, sys
d = open(sys.argv[1], "rb").read()
FRAME = int(sys.argv[2], 0); LINES = int(sys.argv[3], 0)
SA = ["VIS_LN","HPOS","DSPLY_EN","SER_EN","TX_REQ","CSYNC_DAC","CBLANK_DAC"]
SB = ["HBLANK_AB","EOF_AB","CBLANK_CMAP","SET_TSC","ODDFIELD","EOF_VC","VPOS"]
SC = ["VERT_INT","VSYNC_ARC","HSYNC_ARC","CSYNC_ARC","VERT_STAT","spare","CBLANK_XMAP"]
def w(a): return struct.unpack_from(">H", d, LINES + 2*a)[0]
def line(ptr, sb, sc):
    runs = []; pos = 0; a = ptr
    while True:
        w1 = w(a); a += 1
        dur = (w1 >> 8) & 0x7f; sa = w1 & 0x7f; eol = w1 >> 15
        if not (w1 & 0x80):
            w2 = w(a); a += 1; sb = (w2 >> 8) & 0x7f; sc = w2 & 0x7f
        runs.append((pos, dur*2, sa, sb, sc)); pos += dur*2
        if eol: break
    return runs, w(a), sb, sc, pos
def active(runs, grp, bit):
    """list of [start,end) pixel spans where the active-low channel is asserted"""
    spans = []; cur = None
    for pos, n, sa, sb, sc in runs:
        v = {"A": sa, "B": sb, "C": sc}[grp]
        on = not (v >> bit) & 1
        if on and cur is None: cur = pos
        if not on and cur is not None: spans.append((cur, pos)); cur = None
    if cur is not None: spans.append((cur, runs[-1][0] + runs[-1][1]))
    return spans
chans = [("A",i,n) for i,n in enumerate(SA)] + [("B",i,n) for i,n in enumerate(SB)] + [("C",i,n) for i,n in enumerate(SC)]
sb = sc = 0x7f; fa = FRAME; lineno = 0
seen = {}
while True:
    ptr, cnt = struct.unpack_from(">HH", d, fa); fa += 4
    if cnt == 0: break
    runs, nxt, sb2, sc2, total = line(ptr, sb, sc)
    desc = "  ".join(f"{n}={active(runs,g,b)}" for g,b,n in chans if active(runs,g,b))
    print(f"lines {lineno:4d}..{lineno+cnt-1:4d} (x{cnt:4d}) line@0x{ptr:04x} next=0x{nxt:04x} total={total}px")
    print("     " + desc)
    sb, sc = sb2, sc2; lineno += cnt
print("total lines", lineno)
