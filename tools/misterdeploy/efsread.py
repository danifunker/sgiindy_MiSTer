#!/usr/bin/env python3
"""Read files out of an EFS filesystem inside an SGI disk image, on the host.

WHY. When the core dies late in an IRIX boot, the most useful evidence is
usually something the guest already wrote to its own disk - a crash report,
/var/adm/SYSLOG, the kernel it relinked. Booting a second machine just to read
those files is slow and mutates the image you wanted to inspect. This reads
them straight out of the image file, read-only, with nothing emulated.

    python3 efsread.py IMAGE ls   /var/adm/crash
    python3 efsread.py IMAGE cat  /var/adm/crash/analysis.0
    python3 efsread.py IMAGE get  /unix ./unix
    python3 efsread.py IMAGE find /var/adm            # recursive listing

The partition is located from the SGI volume header, so no LBN is needed:
partition 0 is taken as the root filesystem unless --part says otherwise.

EFS, as much as this needs:
  * volume header at block 0, magic 0x0BE5A941, partition table at 0x138,
    entries of (blocks, first, type) big-endian int32 x 3;
  * the superblock is at byte 512 of the partition; sb_magic is at 0x1C
    (0x00072959 / 0x0007295A), preceded by size, firstcg, cgfsize (int32),
    then cgisize, sectors, heads, ncg (int16);
  * inodes are 128 bytes, four to a 512-byte block, packed cgisize blocks at
    the head of each cylinder group;
  * AN EXTENT IS  {magic:8, bn:24}{length:8, offset:24}  - both words are
    (byte, 24-bit) and NOT (24-bit, byte). tools/misterdeploy/efspeek.py has
    these two fields the other way round, which is why it reads a zero-length
    directory block and stops before listing anything;
  * di_numextents > 12 means the 12 slots are indirect: each points at blocks
    that are themselves arrays of 8-byte extents.
  * a directory block is 512 bytes of {magic:0xBEEF, firstused, slots,
    offsets[]}, each offset in 2-byte units, each entry {inum:4, len:1, name}.
"""
import struct
import sys

BB = 512
IFMT, IFDIR, IFREG, IFLNK = 0xF000, 0x4000, 0x8000, 0xA000


class Efs:
    def __init__(self, path, part=0):
        self.fh = open(path, "rb")
        vh = self._rd(0, BB)
        if struct.unpack_from(">I", vh, 0)[0] != 0x0BE5A941:
            raise SystemExit("not an SGI volume header")
        blocks, first, _ptype = struct.unpack_from(">iii", vh, 0x138 + part * 12)
        if blocks <= 0:
            raise SystemExit("partition %d is empty" % part)
        self.base = first * BB
        sb = self._rd(self.base + BB, BB)
        if struct.unpack_from(">I", sb, 0x1C)[0] not in (0x00072959, 0x0007295A):
            raise SystemExit("no EFS superblock in partition %d" % part)
        self.size, self.firstcg, self.cgfsize = struct.unpack_from(">iii", sb, 0)
        self.cgisize, _sec, _hd, self.ncg = struct.unpack_from(">hhhh", sb, 12)

    def _rd(self, off, n):
        self.fh.seek(off)
        return self.fh.read(n)

    def _blk(self, bb, n=1):
        return self._rd(self.base + bb * BB, n * BB)

    def inode(self, num):
        ipbb = BB // 128                       # 4 inodes per basic block
        per_cg = self.cgisize * ipbb
        cg, idx = num // per_cg, num % per_cg
        bb = self.firstcg + cg * self.cgfsize + idx // ipbb
        raw = self._blk(bb)
        return raw[(idx % ipbb) * 128:(idx % ipbb) * 128 + 128]

    @staticmethod
    def _ex(w0, w1):
        # {magic:8, bn:24} {length:8, offset:24} -> (bn, length, offset)
        return (w0 & 0xFFFFFF, w1 >> 24, w1 & 0xFFFFFF)

    def extents(self, ino):
        numex = struct.unpack_from(">h", ino, 0x1C)[0]   # di_numextents
        raw = [struct.unpack_from(">II", ino, 0x20 + i * 8) for i in range(12)]
        direct = [self._ex(*w) for w in raw]
        if numex <= 12:
            return [e for e in direct[:numex] if e[1]]
        out = []
        for bn, length, _off in direct:
            if not length:
                continue
            data = self._blk(bn, length)
            for i in range(0, len(data) - 7, 8):
                w0, w1 = struct.unpack_from(">II", data, i)
                e = self._ex(w0, w1)
                if e[1]:
                    out.append(e)
        return out

    def read(self, ino):
        size = struct.unpack_from(">i", ino, 8)[0]
        buf = bytearray(size)
        for bn, length, off in self.extents(ino):
            data = self._blk(bn, length)
            start = off * BB
            if start >= size:
                continue
            n = min(len(data), size - start)
            buf[start:start + n] = data[:n]
        return bytes(buf)

    def listdir(self, ino):
        out = {}
        for bn, length, _off in self.extents(ino):
            data = self._blk(bn, length)
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

    def resolve(self, path):
        num = 2                                    # root inode
        ino = self.inode(num)
        for part in [p for p in path.strip("/").split("/") if p]:
            if (struct.unpack_from(">H", ino, 0)[0] & IFMT) != IFDIR:
                raise SystemExit("%s: not a directory" % part)
            ents = self.listdir(ino)
            if part not in ents:
                raise SystemExit("%s: not found (dir has: %s)"
                                 % (part, ", ".join(sorted(ents))[:400]))
            num = ents[part]
            ino = self.inode(num)
        return num, ino


def mode_str(m):
    t = {IFDIR: "d", IFREG: "-", IFLNK: "l"}.get(m & IFMT, "?")
    bits = "".join((c if m & (1 << (8 - i)) else "-")
                   for i, c in enumerate("rwxrwxrwx"))
    return t + bits


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    img, cmd = sys.argv[1], sys.argv[2]
    path = sys.argv[3] if len(sys.argv) > 3 else "/"
    part = 0
    if "--part" in sys.argv:
        part = int(sys.argv[sys.argv.index("--part") + 1])
    fs = Efs(img, part)

    if cmd == "ls":
        _num, ino = fs.resolve(path)
        m = struct.unpack_from(">H", ino, 0)[0]
        if (m & IFMT) != IFDIR:
            print("%s %9d  %s" % (mode_str(m),
                                  struct.unpack_from(">i", ino, 8)[0], path))
            return
        for nm, n in sorted(fs.listdir(ino).items()):
            i = fs.inode(n)
            im = struct.unpack_from(">H", i, 0)[0]
            sz = struct.unpack_from(">i", i, 8)[0]
            print("%s %9d  %-28s inode %d" % (mode_str(im), sz, nm, n))
    elif cmd == "cat":
        _n, ino = fs.resolve(path)
        sys.stdout.buffer.write(fs.read(ino))
    elif cmd == "get":
        _n, ino = fs.resolve(path)
        open(sys.argv[4], "wb").write(fs.read(ino))
        print("wrote %s (%d bytes)"
              % (sys.argv[4], struct.unpack_from(">i", ino, 8)[0]))
    elif cmd == "find":
        def walk(p, num, depth=0):
            if depth > 6:
                return
            for nm, n in sorted(fs.listdir(fs.inode(num)).items()):
                if nm in (".", ".."):
                    continue
                i = fs.inode(n)
                m = struct.unpack_from(">H", i, 0)[0]
                sz = struct.unpack_from(">i", i, 8)[0]
                full = p.rstrip("/") + "/" + nm
                print("%s %9d  %s" % (mode_str(m), sz, full))
                if (m & IFMT) == IFDIR:
                    walk(full, n, depth + 1)
        num, _ino = fs.resolve(path)
        walk(path, num)
    else:
        raise SystemExit("commands: ls | cat | get | find")


main()
