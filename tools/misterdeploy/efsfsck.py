#!/usr/bin/env python3
"""efsfsck.py IMAGE [--part N] [--who BLOCK...] - read-only EFS consistency check.

RUN IT ON THE HOST, not on the board: it keeps an owner for every allocated
block, which is ~400 MB for this 2 GB image, and the MiSTer has 492 MB and no
swap (docs/design/scsi-sync-negotiation.md §7). Copy the image over, or check the pristine one here.

Walks every in-use inode, collects the basic blocks its extents (and indirect
extent blocks) claim, and compares them with the free-block bitmap:
  * blocks claimed by an inode but marked FREE in the bitmap (the dangerous
    kind: the kernel may hand them to a new file),
  * blocks claimed by two inodes,
  * the bitmap's free count against the superblock's fs_tfree.
Names are resolved for the inodes involved by walking the directory tree.
"""
import struct
import sys
from collections import defaultdict

BB = 512
IFMT, IFDIR, IFREG, IFLNK = 0xF000, 0x4000, 0x8000, 0xA000


def main():
    img = sys.argv[1]
    part = int(sys.argv[sys.argv.index("--part") + 1]) if "--part" in sys.argv else 0
    fh = open(img, "rb")

    def rd(off, n):
        fh.seek(off)
        return fh.read(n)

    vh = rd(0, BB)
    assert struct.unpack_from(">I", vh, 0)[0] == 0x0BE5A941
    blocks, first, _t = struct.unpack_from(">iii", vh, 0x138 + part * 12)
    base = first * BB
    sb = rd(base + BB, BB)
    size, firstcg, cgfsize = struct.unpack_from(">iii", sb, 0)
    cgisize, sectors, heads, ncg, dirty = struct.unpack_from(">hhhhh", sb, 12)
    fstime, magic = struct.unpack_from(">iI", sb, 0x18)
    bmsize, tfree, tinode, bmblock, replsb, lastialloc = struct.unpack_from(">iiiiii", sb, 0x2C)
    print("partition %d: first bb %d, %d bbs; fs_size %d firstcg %d cgfsize %d cgisize %d ncg %d dirty %d magic %#x"
          % (part, first, blocks, size, firstcg, cgfsize, cgisize, ncg, dirty, magic))
    print("bmsize %d tfree %d tinode %d bmblock %d replsb %d lastialloc %d"
          % (bmsize, tfree, tinode, bmblock, replsb, lastialloc))
    bm_bb = bmblock if (magic == 0x0007295A and bmblock) else 2
    bitmap = rd(base + bm_bb * BB, bmsize)

    # WHICH BIT ORDER? A set bit means FREE in EFS, and the two orders are told
    # apart by the data: the one that calls no allocated block free is right
    # (msb-first contradicts 4,725 of them on the pristine image, lsb-first
    # none).
    def bit_msb(bn):
        return (bitmap[bn >> 3] >> (7 - (bn & 7))) & 1

    def bit_lsb(bn):
        return (bitmap[bn >> 3] >> (bn & 7)) & 1

    total_set = sum(bin(b).count("1") for b in bitmap)
    print("bitmap at bb %d: %d bits set (tfree says %d)" % (bm_bb, total_set, tfree))

    def inode_raw(num):
        ipbb = BB // 128
        per_cg = cgisize * ipbb
        cg, idx = num // per_cg, num % per_cg
        bb = firstcg + cg * cgfsize + idx // ipbb
        raw = rd(base + bb * BB, BB)
        return raw[(idx % ipbb) * 128:(idx % ipbb) * 128 + 128]

    def ex(w0, w1):
        return (w0 & 0xFFFFFF, w1 >> 24, w1 & 0xFFFFFF)

    owner = defaultdict(list)     # bn -> [inode]
    inodes = {}
    per_cg = cgisize * 4
    for num in range(ncg * per_cg):
        ino = inode_raw(num)
        mode = struct.unpack_from(">H", ino, 0)[0]
        if mode == 0:
            continue
        nlink = struct.unpack_from(">h", ino, 2)[0]
        fsize = struct.unpack_from(">i", ino, 8)[0]
        numex = struct.unpack_from(">h", ino, 0x1C)[0]
        if (mode & IFMT) == 0x2000 or (mode & IFMT) == 0x6000:   # devices: no extents
            inodes[num] = (mode, fsize, [])
            continue
        raw = [struct.unpack_from(">II", ino, 0x20 + i * 8) for i in range(12)]
        direct = [ex(*w) for w in raw]
        exts = []
        claim = []
        if numex <= 12:
            exts = [e for e in direct[:numex] if e[1]]
        else:
            nind = direct[0][2]   # for indirect, offset field of first holds the count of indirect extents
            for bn, length, _off in direct[:max(1, nind)]:
                if not length:
                    continue
                claim += list(range(bn, bn + length))
                data = rd(base + bn * BB, length * BB)
                for i in range(0, min(len(data), numex * 8), 8):
                    w0, w1 = struct.unpack_from(">II", data, i)
                    e = ex(w0, w1)
                    if e[1]:
                        exts.append(e)
        for bn, length, _off in exts:
            claim += list(range(bn, bn + length))
        for bn in claim:
            owner[bn].append(num)
        inodes[num] = (mode, fsize, exts)

    print("%d inodes in use, %d blocks claimed" % (len(inodes), len(owner)))
    for name, bit in (("msb-first", bit_msb), ("lsb-first", bit_lsb)):
        bad = sum(1 for bn in owner if bn < size and bit(bn))
        print("  bit order %s: %d claimed blocks marked free" % (name, bad))
    # choose the order with fewer contradictions
    bad_msb = [bn for bn in owner if bn < size and bit_msb(bn)]
    bad_lsb = [bn for bn in owner if bn < size and bit_lsb(bn)]
    bit, bad = (bit_msb, bad_msb) if len(bad_msb) <= len(bad_lsb) else (bit_lsb, bad_lsb)
    dups = {bn: o for bn, o in owner.items() if len(o) > 1}
    out_of_range = [bn for bn in owner if bn >= size]

    # names
    names = {2: "/"}
    def listdir(num):
        out = {}
        for bn, length, _off in inodes.get(num, (0, 0, []))[2]:
            data = rd(base + bn * BB, length * BB)
            for b in range(length):
                blk = data[b * BB:(b + 1) * BB]
                if len(blk) < 4 or struct.unpack_from(">H", blk, 0)[0] != 0xBEEF:
                    continue
                for s in range(blk[3]):
                    o = blk[4 + s] * 2
                    if o < 4 or o + 5 > BB:
                        continue
                    inum = struct.unpack_from(">I", blk, o)[0]
                    nl = blk[o + 4]
                    nm = blk[o + 5:o + 5 + nl].decode("latin1", "replace")
                    if nm and inum:
                        out[nm] = inum
        return out
    stack = [2]
    seen = set()
    while stack:
        d = stack.pop()
        if d in seen:
            continue
        seen.add(d)
        for nm, n in listdir(d).items():
            if nm in (".", ".."):
                continue
            if n not in names:
                names[n] = names[d].rstrip("/") + "/" + nm
            m = inodes.get(n, (0,))[0]
            if (m & IFMT) == IFDIR:
                stack.append(n)

    print("claimed-but-free blocks: %d" % len(bad))
    by_ino = defaultdict(list)
    for bn in sorted(bad):
        for n in owner[bn]:
            by_ino[n].append(bn)
    for n, bns in sorted(by_ino.items(), key=lambda kv: -len(kv[1]))[:40]:
        print("  inode %d %s: %d blocks free in bitmap, e.g. %s" % (n, names.get(n, "?"), len(bns), bns[:8]))
    print("blocks claimed twice: %d" % len(dups))
    pairs = defaultdict(int)
    for bn, o in dups.items():
        pairs[tuple(sorted(o))] += 1
    for o, cnt in sorted(pairs.items(), key=lambda kv: -kv[1])[:40]:
        print("  %d blocks shared by %s" % (cnt, ", ".join("%d %s" % (n, names.get(n, "?")) for n in o)))
    print("claimed blocks beyond fs_size: %d" % len(out_of_range))
    free_bits = sum(1 for bn in range(size) if bit(bn))
    print("free bits within fs_size (chosen order): %d, tfree %d" % (free_bits, tfree))
    if "--who" in sys.argv:
        for a in sys.argv[sys.argv.index("--who") + 1:]:
            bn = int(a, 0)
            print("block %d: owners %s, bitmap free=%d" % (bn, [(n, names.get(n)) for n in owner.get(bn, [])], bit(bn)))


main()
