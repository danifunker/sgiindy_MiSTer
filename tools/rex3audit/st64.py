"""st64.py ELF [ELF...] - count the doubleword stores (sdc1, sd) and loads
(ldc1, ld) in each ELF32 big-endian MIPS object's executable sections, and
name the functions that hold the stores, from .symtab/.dynsym.

A 64-bit store to REX3 is two register writes (IRIS rex3.rs write64); the
core's newport.sv keeps one word of a doubleword and drops the other. The
question is whether the Newport GL libraries issue them at all.
"""
import struct
import sys
from bisect import bisect_right
from collections import Counter

OPS = {0x3D: "sdc1", 0x3F: "sd", 0x35: "ldc1", 0x37: "ld"}


def parse(path):
    d = open(path, "rb").read()
    assert d[:4] == b"\x7fELF" and d[4] == 1 and d[5] == 2, "want ELF32 MSB"
    shoff, = struct.unpack_from(">I", d, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from(">HHH", d, 0x2E)
    secs = []
    for i in range(shnum):
        nm, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from(">10I", d, shoff + i * shentsize)
        secs.append(dict(nm=nm, typ=typ, flags=flags, addr=addr, off=off,
                         size=size, link=link, entsize=entsize))
    shstr = secs[shstrndx]
    name = lambda s: d[shstr["off"] + s["nm"]:].split(b"\0", 1)[0].decode()
    for s in secs:
        s["name"] = name(s)
    syms = []
    for s in secs:
        if s["typ"] in (2, 11):                    # SYMTAB, DYNSYM
            strs = secs[s["link"]]
            for k in range(s["size"] // 16):
                st_name, st_value, st_size, st_info, st_other, st_shndx = \
                    struct.unpack_from(">IIIBBH", d, s["off"] + k * 16)
                if st_info & 0xF == 2 and st_value:  # STT_FUNC
                    n = d[strs["off"] + st_name:].split(b"\0", 1)[0].decode()
                    syms.append((st_value, n))
    syms = sorted(set(syms))
    return d, secs, syms


for path in (sys.argv[1:] if __name__ == "__main__" else []):
    d, secs, syms = parse(path)
    addrs = [a for a, _ in syms]
    tot = Counter()
    per = Counter()
    for s in secs:
        if not (s["flags"] & 4) or s["typ"] != 1:  # SHF_EXECINSTR, PROGBITS
            continue
        for k in range(0, s["size"] - 3, 4):
            w, = struct.unpack_from(">I", d, s["off"] + k)
            op = w >> 26
            if op in OPS:
                tot[OPS[op]] += 1
                if OPS[op] in ("sdc1", "sd"):
                    i = bisect_right(addrs, s["addr"] + k) - 1
                    per[syms[i][1] if i >= 0 else "?"] += 1
    print(f"== {path.split('/')[-1]}: {dict(tot)}; stores in {len(per)} functions")
    for fn, n in per.most_common(25):
        print(f"   {n:5d}  {fn}")
