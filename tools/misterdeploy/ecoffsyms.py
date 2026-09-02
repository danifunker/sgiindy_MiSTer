#!/usr/bin/env python3
"""Symbols and code out of an IRIX ECOFF kernel, on the host.

WHY. When the guest wedges inside the KERNEL, the debug beacon's PC (word 10)
is a bare number - and IRIX 5.3's /unix is ECOFF, which no modern binutils on
this box will read, so there was no way to turn that number into a function
name or a wait condition. This reads the ECOFF symbol tables directly:
`efsread.py IMAGE get /unix ./unix` fetches the kernel off any boot image,
then this maps addresses to names and cuts instruction ranges for disbin.py.

It found the fsck wedge's second half in one pass: beacon said pc=0x880b2154,
`syms`/`lsyms` said that is inside handle_intr (wd93.c), and the dump showed
the three-instruction `ASR & 0x30` spin the paused target's bus BSY could
never satisfy. See docs/31.

    python ecoffsyms.py unix syms  [regex]    # external symbols
    python ecoffsyms.py unix lsyms [regex]    # static procs (per-FD locals)
    python ecoffsyms.py unix dump 0x880b2124 0x684 out.bin
    python disbin.py out.bin 0x880b2124       # then disassemble

Format notes, as much as this needs: filehdr magic 0x0160/0x0163 (MIPSEB /
MIPSEB-mips2); f_symptr -> HDRR (magic 0x7009), whose cbExtOffset holds EXTR
entries {reserved:16, ifd:16, SYMR} with names in the external string table;
static procedures are SYMR st=6/14 entries in each file descriptor's local
symbol run, names via the FD's issBase into the LOCAL string table. Section
vaddrs are signed in struct terms - mask them or 0x88xxxxxx never matches.
"""
import re
import struct
import sys

f = open(sys.argv[1], "rb")
data = f.read()

# filehdr: f_magic, f_nscns, f_timdat, f_symptr, f_nsyms, f_opthdr, f_flags
(f_magic, f_nscns, f_timdat, f_symptr, f_nsyms, f_opthdr,
 f_flags) = struct.unpack(">HHiiiHH", data[:20])
assert f_magic in (0x0160, 0x0163), hex(f_magic)  # MIPSEB / MIPSEB mips2

# section headers follow filehdr + opthdr
scns = []
off = 20 + f_opthdr
for i in range(f_nscns):
    (s_name, s_paddr, s_vaddr, s_size, s_scnptr, s_relptr, s_lnnoptr,
     s_nreloc, s_nlnno, s_flags) = struct.unpack(">8siiiiiiHHi",
                                                 data[off:off + 40])
    scns.append((s_name.rstrip(b"\0").decode(), s_vaddr & 0xFFFFFFFF,
                 s_size, s_scnptr))
    off += 40

# HDRR symbolic header at f_symptr
h = struct.unpack(">hh23i", data[f_symptr:f_symptr + 96])
(magic, vstamp, ilineMax, cbLine, cbLineOffset, idnMax, cbDnOffset,
 ipdMax, cbPdOffset, isymMax, cbSymOffset, ioptMax, cbOptOffset,
 iauxMax, cbAuxOffset, issMax, cbSsOffset, issExtMax, cbSsExtOffset,
 ifdMax, cbFdOffset, crfd, cbRfdOffset, iextMax, cbExtOffset) = h
assert magic == 0x7009, hex(magic)

def ext_syms():
    for i in range(iextMax):
        o = cbExtOffset + i * 16
        res, ifd, iss, value, bf = struct.unpack(">hhiiI", data[o:o + 16])
        st = (bf >> 26) & 0x3F
        sc = (bf >> 21) & 0x1F
        e = data.find(b"\0", cbSsExtOffset + iss)
        name = data[cbSsExtOffset + iss:e].decode("latin1")
        yield name, value, st, sc

def local_procs():
    """Walk every file descriptor's local symbols; yield procs/staticprocs."""
    for ifd in range(ifdMax):
        o = cbFdOffset + ifd * 72
        (adr, rss, issBase, cbSs, isymBase, csym, ilineBase, cline,
         ioptBase, copt, ipdFirst, cpd, iauxBase, caux, rfdBase, crfd,
         bf, cbLO, cbL) = struct.unpack(">10ihh4i3i", data[o:o + 72])
        for i in range(csym):
            so = cbSymOffset + (isymBase + i) * 12
            iss, value, sbf = struct.unpack(">iiI", data[so:so + 12])
            st = (sbf >> 26) & 0x3F
            if st in (6, 14):  # Proc, StaticProc
                e = data.find(b"\0", cbSsOffset + issBase + iss)
                name = data[cbSsOffset + issBase + iss:e].decode("latin1")
                yield name, value & 0xFFFFFFFF

if sys.argv[2] == "lsyms":
    pat = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
    for name, value in local_procs():
        if pat is None or pat.search(name):
            print("%08x proc %s" % (value, name))
elif sys.argv[2] == "syms":
    pat = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
    ST = {1: "nil", 6: "proc", 2: "global", 3: "static", 14: "staticproc"}
    for name, value, st, sc in ext_syms():
        if pat is None or pat.search(name):
            print("%08x st=%-10s sc=%2d %s" % (value & 0xFFFFFFFF,
                                               ST.get(st, st), sc, name))
elif sys.argv[2] == "dump":
    va = int(sys.argv[3], 0)
    ln = int(sys.argv[4], 0)
    out = sys.argv[5]
    for name, vaddr, size, scnptr in scns:
        if vaddr <= va < vaddr + size:
            o = scnptr + (va - vaddr)
            open(out, "wb").write(data[o:o + ln])
            print("wrote %s: %d bytes from section %s (file off 0x%x)"
                  % (out, ln, name, o))
            break
    else:
        print("va 0x%x not in any section" % va)
        for s in scns:
            print("  %-8s va=0x%08x size=0x%x" % (s[0], s[1] & 0xFFFFFFFF, s[2]))
