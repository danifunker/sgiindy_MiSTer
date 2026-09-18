"""Field decoders for REX3 control registers, per REX3 spec rev 1.0 section 3.1.1."""

OPC = ["NOOP", "READ", "DRAW", "SCR2SCR"]
ADR = {0: "SPAN", 1: "BLOCK", 2: "I_LINE", 3: "F_LINE", 4: "A_LINE"}
DM0_BITS = [(5, "DOSETUP"), (6, "COLORHOST"), (7, "ALPHAHOST"), (8, "STOPONX"), (9, "STOPONY"),
            (10, "SKIPFIRST"), (11, "SKIPLAST"), (12, "ENZPATTERN"), (13, "ENLSPATTERN"),
            (14, "LSADVLAST"), (15, "LENGTH32"), (16, "ZPOPAQUE"), (17, "LSOPAQUE"),
            (18, "SHADE"), (19, "LRONLY"), (20, "XYOFFSET"), (21, "CICLAMP"),
            (22, "ENDPTFILTER"), (23, "YSTRIDE")]
PLANES = {0: "none", 1: "RGB/CI", 2: "RGBA", 4: "OLAY", 5: "PUP", 6: "CID", 3: "planes3?", 7: "planes7?"}
DEPTH = ["4", "8", "12", "24"]
HDEPTH = ["4", "8", "12", "32"]
LOGIC = ["ZERO", "AND", "ANDR", "SRC", "ANDI", "DST", "XOR", "OR", "NOR", "XNOR", "NDST",
         "ORR", "NSRC", "ORI", "NAND", "ONE"]
SF = ["ZERO", "ONE", "DC", "MDC", "SA", "MSA", "sf6?", "sf7?"]
DF = ["ZERO", "ONE", "SC", "MSC", "SA", "MSA", "df6?", "df7?"]


def dm0(v):
    s = [OPC[v & 3], ADR.get((v >> 2) & 7, "adr%d?" % ((v >> 2) & 7))]
    s += [n for b, n in DM0_BITS if v >> b & 1]
    if v >> 24:
        s.append("hi=0x%x?" % (v >> 24))
    return "|".join(s)


def dm1(v):
    s = ["PL=" + PLANES[v & 7], "DD=" + DEPTH[(v >> 3) & 3]]
    if v >> 5 & 1:
        s.append("DBLSRC")
    if v >> 6 & 1:
        s.append("YFLIP")
    if v >> 7 & 1:
        s.append("RWPACKED")
    s.append("HD=" + HDEPTH[(v >> 8) & 3])
    if v >> 10 & 1:
        s.append("RWDOUBLE")
    if v >> 11 & 1:
        s.append("SWAPENDIAN")
    cmp = (v >> 12) & 7
    if cmp != 7:
        s.append("CMP=%d" % cmp)
    if v >> 15 & 1:
        s.append("RGBMODE")
    if v >> 16 & 1:
        s.append("DITHER")
    if v >> 17 & 1:
        s.append("FASTCLEAR")
    if v >> 18 & 1:
        s.append("BLEND(%s,%s)" % (SF[(v >> 19) & 7], DF[(v >> 22) & 7]))
    elif (v >> 19) & 0x3F:
        s.append("sf/df=%s,%s(off)" % (SF[(v >> 19) & 7], DF[(v >> 22) & 7]))
    if v >> 25 & 1:
        s.append("BACKBLEND")
    if v >> 26 & 1:
        s.append("PREFETCH")
    if v >> 27 & 1:
        s.append("BLENDALPHA")
    s.append("LO=" + LOGIC[(v >> 28) & 15])
    return "|".join(s)


def lsmode(v):
    return "RCOUNT=%d REPEAT=%d RCNTSAVE=%d LENGTH=%d%s" % (
        v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, ((v >> 24) & 15) + 17 if (v >> 24) & 15 else 17,
        "" if not v >> 28 else " hi=0x%x?" % (v >> 28))


def clipmode(v):
    en = v & 0x1F
    cid = (v >> 9) & 15
    s = "ENSMASK=0x%x CIDMATCH=0x%x" % (en, cid)
    if cid == 0xF:
        s += "(no CID test)"
    if (v >> 5) & 15:
        s += " rsvd[8:5]=0x%x" % ((v >> 5) & 15)
    if v >> 13:
        s += " hi=0x%x?" % (v >> 13)
    return s


def config(v):
    return ("GIO32MODE=%d BUSWIDTH=%d EXTREGXCVR=%d BFIFODEPTH=%d BFIFOABOVEINT=%d "
            "GFIFODEPTH=%d GFIFOABOVEINT=%d TIMEOUT=%d VREFRESH=%d FB_TYPE=%d%s") % (
        v & 1, v >> 1 & 1, v >> 2 & 1, (v >> 3) & 15, v >> 7 & 1, (v >> 8) & 31, v >> 13 & 1,
        (v >> 14) & 7, (v >> 17) & 7, v >> 20 & 1, "" if not v >> 21 else " hi=0x%x?" % (v >> 21))


DCBDEV = {0: "VC2", 1: "CMAP01", 2: "CMAP0", 3: "CMAP1", 4: "XMAP01", 5: "XMAP0", 6: "XMAP1",
          7: "RAMDAC", 8: "CC1", 9: "AB1", 12: "PCD", 15: "dev15(reset val)"}
DW = ["4B", "1B", "2B", "3B"]


def dcbmode(v):
    s = "%s CRS=%d DW=%s" % (DCBDEV.get((v >> 7) & 15, "dev%d" % ((v >> 7) & 15)), (v >> 4) & 7, DW[v & 3])
    if v >> 2 & 1:
        s += " DATAPACK"
    if v >> 3 & 1:
        s += " CRSINC"
    if v >> 11 & 1:
        s += " SYNCACK"
    if v >> 12 & 1:
        s += " ASYNCACK"
    s += " CSW=%d CSH=%d CSS=%d" % ((v >> 13) & 31, (v >> 18) & 31, (v >> 23) & 31)
    if v >> 28 & 1:
        s += " SWAPENDIAN"
    if v >> 29:
        s += " hi=0x%x?" % (v >> 29)
    return s


def xy(v):
    x = (v >> 16) & 0xFFFF
    y = v & 0xFFFF
    sx = x - 0x10000 if x & 0x8000 else x
    sy = y - 0x10000 if y & 0x8000 else y
    return "x=%d y=%d" % (sx, sy)


def wrmask(v):
    tags = {0xFFFFFF: "all24", 0x000FFF: "low12(buf0 12bpp/aux)", 0xFFF000: "high12(buf1 12bpp)",
            0x0000FF: "low8", 0x00FF00: "byte1", 0xFF0000: "byte2", 0x00000F: "low4",
            0x0000F0: "nib1", 0x249249: "phys-G", 0x492492: "phys-R", 0x924924: "phys-B",
            0x000000: "none", 0xFFFFFFFF: "all32", 0x00FFFF: "low16"}
    return tags.get(v, "0x%06x" % v)


DECODE = {"DRAWMODE0": dm0, "DRAWMODE1": dm1, "LSMODE": lsmode, "CLIPMODE": clipmode,
          "CONFIG": config, "DCBMODE": dcbmode, "XYWIN": xy, "WRMASK": wrmask,
          "TOPSCAN": lambda v: "row %d%s" % (v & 0x3FF, "" if not v >> 10 else " hi=0x%x" % (v >> 10)),
          "COLORVRAM": lambda v: "0x%08x" % v}
