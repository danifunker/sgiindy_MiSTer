"""binload.py - load the guest binaries (ELF32 MSB .so/exec, IRIX ECOFF kernel,
raw PROM) into one shape: code ranges, a byte reader by VA, function starts
with names, data symbols, gp value, and (ELF) the source file of each proc."""
import struct
import re

WT = "C:/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e"
SP = ("C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer"
      "--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")


class Image:
    def __init__(self, name):
        self.name = name
        self.segs = []        # (va, bytes, is_code, secname)
        self.funcs = {}       # va -> name
        self.srcfile = {}     # func va -> source file
        self.dsyms = {}       # data va -> name
        self.gp = None
        self.got = None       # (lo, hi)
        self.pic = False

    def read(self, va, n):
        for sva, b, code, nm in self.segs:
            if sva <= va and va + n <= sva + len(b):
                return b[va - sva:va - sva + n]
        return None

    def word(self, va):
        b = self.read(va, 4)
        return None if b is None else struct.unpack(">I", b)[0]

    def secname(self, va):
        for sva, b, code, nm in self.segs:
            if sva <= va < sva + len(b):
                return nm
        return None

    def code_ranges(self):
        return [(sva, b) for sva, b, code, nm in self.segs if code]


def _mdebug_procs(d, off, img):
    h = struct.unpack(">hh23i", d[off:off + 96])
    (magic, vstamp, ilineMax, cbLine, cbLineOffset, idnMax, cbDnOffset,
     ipdMax, cbPdOffset, isymMax, cbSymOffset, ioptMax, cbOptOffset,
     iauxMax, cbAuxOffset, issMax, cbSsOffset, issExtMax, cbSsExtOffset,
     ifdMax, cbFdOffset, crfd, cbRfdOffset, iextMax, cbExtOffset) = h
    if magic != 0x7009:
        return
    for ifd in range(ifdMax):
        fo = cbFdOffset + ifd * 72
        (adr, rss, issBase, cbSs, isymBase, csym, ilineBase, cline,
         ioptBase, copt, ipdFirst, cpd, iauxBase, caux, rfdBase, crfd_,
         bf, cbLO, cbL) = struct.unpack(">10ihh4i3i", d[fo:fo + 72])
        e = d.find(b"\0", cbSsOffset + issBase + rss)
        fname = d[cbSsOffset + issBase + rss:e].decode("latin1") if rss >= 0 else "?"
        for i in range(csym):
            so = cbSymOffset + (isymBase + i) * 12
            iss, value, sbf = struct.unpack(">iiI", d[so:so + 12])
            st = (sbf >> 26) & 0x3F
            if st in (6, 14):
                e = d.find(b"\0", cbSsOffset + issBase + iss)
                name = d[cbSsOffset + issBase + iss:e].decode("latin1")
                va = value & 0xFFFFFFFF
                img.funcs.setdefault(va, name)
                img.srcfile[va] = fname


def load_elf(path, name=None):
    d = open(path, "rb").read()
    assert d[:4] == b"\x7fELF" and d[4] == 1 and d[5] == 2
    img = Image(name or path.split("/")[-1])
    shoff, = struct.unpack_from(">I", d, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from(">HHH", d, 0x2E)
    secs = []
    for i in range(shnum):
        nm, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from(">10I", d, shoff + i * shentsize)
        secs.append(dict(nm=nm, typ=typ, flags=flags, addr=addr, off=off,
                         size=size, link=link))
    shstr = secs[shstrndx]
    for s in secs:
        s["name"] = d[shstr["off"] + s["nm"]:].split(b"\0", 1)[0].decode()
    text_secs = []
    for s in secs:
        if s["typ"] == 1 and s["addr"] and s["size"]:
            code = bool(s["flags"] & 4)
            img.segs.append((s["addr"], d[s["off"]:s["off"] + s["size"]], code, s["name"]))
            if code:
                text_secs.append(s)
        if s["typ"] == 8 and s["addr"] and s["size"]:   # NOBITS
            img.segs.append((s["addr"], bytes(s["size"]), False, s["name"]))
        if s["name"] == ".reginfo":
            img.gp, = struct.unpack_from(">I", d, s["off"] + 20)
        if s["name"] == ".got":
            img.got = (s["addr"], s["addr"] + s["size"])
    for s in secs:
        if s["typ"] in (2, 11):
            strs = secs[s["link"]]
            for k in range(s["size"] // 16):
                st_name, st_value, st_size, st_info, st_other, st_shndx = \
                    struct.unpack_from(">IIIBBH", d, s["off"] + k * 16)
                if not st_value:
                    continue
                n = d[strs["off"] + st_name:].split(b"\0", 1)[0].decode("latin1")
                intext = any(t["addr"] <= st_value < t["addr"] + t["size"] for t in text_secs)
                typ = st_info & 0xF
                if intext and (typ == 2 or (typ == 0 and st_shndx != 0)):
                    img.funcs.setdefault(st_value, n)
                elif typ in (1, 0) and not intext:
                    img.dsyms.setdefault(st_value, n)
    for s in secs:
        if s["name"] == ".mdebug":
            _mdebug_procs(d, s["off"], img)
    img.pic = True
    return img


def load_ecoff(path, name=None):
    d = open(path, "rb").read()
    img = Image(name or path.split("/")[-1])
    (f_magic, f_nscns, f_timdat, f_symptr, f_nsyms, f_opthdr, f_flags) = \
        struct.unpack(">HHiiiHH", d[:20])
    a = struct.unpack(">hhiiiiiiiIIIIII", d[20:20 + 56])
    img.gp = a[14] & 0xFFFFFFFF
    off = 20 + f_opthdr
    for i in range(f_nscns):
        (s_name, s_paddr, s_vaddr, s_size, s_scnptr, s_relptr, s_lnnoptr,
         s_nreloc, s_nlnno, s_flags) = struct.unpack(">8siiiiiiHHi", d[off:off + 40])
        off += 40
        nm = s_name.rstrip(b"\0").decode()
        va = s_vaddr & 0xFFFFFFFF
        if not va:
            continue
        if s_scnptr:
            img.segs.append((va, d[s_scnptr:s_scnptr + s_size], nm == ".text", nm))
        else:
            img.segs.append((va, bytes(s_size), False, nm))
    # symbols
    h = struct.unpack(">hh23i", d[f_symptr:f_symptr + 96])
    (magic, vstamp, ilineMax, cbLine, cbLineOffset, idnMax, cbDnOffset,
     ipdMax, cbPdOffset, isymMax, cbSymOffset, ioptMax, cbOptOffset,
     iauxMax, cbAuxOffset, issMax, cbSsOffset, issExtMax, cbSsExtOffset,
     ifdMax, cbFdOffset, crfd, cbRfdOffset, iextMax, cbExtOffset) = h
    for i in range(iextMax):
        o = cbExtOffset + i * 16
        res, ifd, iss, value, bf = struct.unpack(">hhiiI", d[o:o + 16])
        st = (bf >> 26) & 0x3F
        e = d.find(b"\0", cbSsExtOffset + iss)
        nm = d[cbSsExtOffset + iss:e].decode("latin1")
        va = value & 0xFFFFFFFF
        if st in (6, 14):
            img.funcs.setdefault(va, nm)
        elif st in (1, 2, 3) and va:
            img.dsyms.setdefault(va, nm)
    _mdebug_procs(d, f_symptr, img)
    return img


def load_rom(path, base=0xBFC00000, name="boot.rom", code_end=0x4C000):
    """IP24 PROM: code is the first 0x4C000 bytes (then strings/tables); the
    code reaches its own data through the cached alias 0x9FC00000."""
    d = open(path, "rb").read()
    img = Image(name)
    img.segs.append((base, d[:code_end], True, "rom"))
    img.segs.append((base + code_end, d[code_end:], False, "rom"))
    img.segs.append((0x9FC00000, d, False, "rom"))
    img.funcs[base] = "reset"
    img.pic = False
    return img


def all_images():
    gl = SP + "/gl/"
    return {
        "irisgl": lambda: load_elf(gl + "irisgl.so", "irisgl.so"),
        "glcore": lambda: load_elf(gl + "libGLcore.so", "libGLcore.so"),
        "opengl": lambda: load_elf(gl + "opengl.so", "opengl.so"),
        "libgd": lambda: load_elf(gl + "libgd.so", "libgd.so"),
        "xsgi": lambda: load_elf(gl + "Xsgi", "Xsgi"),
        "unix": lambda: load_ecoff(gl + "unix", "unix"),
        "prom": lambda: load_rom(WT + "/releases/boot.rom"),
    }
