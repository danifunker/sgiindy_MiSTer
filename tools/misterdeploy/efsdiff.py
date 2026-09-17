#!/usr/bin/env python3
"""efsdiff.py USED.img PRISTINE.img [--part N] [--src PATH ...] [--max N]

RUNS ON THE BOARD (python3, read-only). Finds every EFS basic block that differs
between a used image and the pristine image it was restored from, and says whose
block it is - so a write that went to the wrong place shows up as a file that
changed although nothing wrote it.

For each differing block:
  * its owner in the USED image and in PRISTINE (inode number and path, or
    "free", "inode table", "bitmap/superblock");
  * the verdict: a block of a file whose inode is identical in both images but
    for the access time (same size, same extents, same mtime) and whose data
    changed anyway is FOREIGN - nothing that went through the file system
    wrote it.
With --copies SRC DST..., each DST is also compared with SRC in the used image
(a write that went elsewhere leaves its intended block stale).
For every FOREIGN block, the used image's content is searched for in the files
named with --src (e.g. /unix, which the stress run copies): a hit gives the
file and byte offset the block's data really belongs to.

Needs efsread.py beside it only for the path conventions; the EFS walk here is
self-contained (inode tables, direct and indirect extents, directories).

IT RUNS ON A 1 GB BOARD. Owners are recorded only for the blocks that differ -
a dict over every allocated block is 1.9 million entries per image, and asking
for two of those wedged the MiSTer for a quarter of an hour (2026-09-17).
"""
import bisect
import hashlib
import struct
import sys
from collections import defaultdict

BB = 512
IFMT, IFDIR, IFREG, IFLNK = 0xF000, 0x4000, 0x8000, 0xA000


class Fs:
    def __init__(self, path, part):
        self.fh = open(path, "rb")
        vh = self.rd(0, BB)
        if struct.unpack_from(">I", vh, 0)[0] != 0x0BE5A941:
            raise SystemExit("%s: not an SGI volume header" % path)
        _blocks, first, _t = struct.unpack_from(">iii", vh, 0x138 + part * 12)
        self.base = first * BB
        sb = self.rd(self.base + BB, BB)
        self.size, self.firstcg, self.cgfsize = struct.unpack_from(">iii", sb, 0)
        self.cgisize, _s, _h, self.ncg = struct.unpack_from(">hhhh", sb, 12)
        self.magic = struct.unpack_from(">I", sb, 0x1C)[0]
        self.bmsize, _tf, _ti, self.bmblock = struct.unpack_from(">iiii", sb, 0x2C)
        self.ino_raw = {}
        self.owner = {}          # only for the blocks in self.watch
        self.watch = []          # sorted block numbers worth an owner
        self.inodes = {}
        self.names = {2: "/"}

    def claim(self, bn, length, num, off):
        """Record ownership only where it overlaps the watched blocks."""
        i = bisect.bisect_left(self.watch, bn)
        while i < len(self.watch) and self.watch[i] < bn + length:
            self.owner[self.watch[i]] = (num, off + (self.watch[i] - bn) * BB if off >= 0 else -1)
            i += 1

    def rd(self, off, n):
        self.fh.seek(off)
        return self.fh.read(n)

    def blk(self, bn, n=1):
        return self.rd(self.base + bn * BB, n * BB)

    def load(self):
        per_cg = self.cgisize * 4
        for cg in range(self.ncg):
            table = self.blk(self.firstcg + cg * self.cgfsize, self.cgisize)
            for idx in range(per_cg):
                raw = table[idx * 128:idx * 128 + 128]
                mode = struct.unpack_from(">H", raw, 0)[0]
                if mode == 0:
                    continue
                num = cg * per_cg + idx
                self.ino_raw[num] = raw
                fmt = mode & IFMT
                if fmt in (0x2000, 0x6000, 0x1000, 0xC000):
                    self.inodes[num] = []
                    continue
                numex = struct.unpack_from(">h", raw, 0x1C)[0]
                direct = []
                for i in range(12):
                    w0, w1 = struct.unpack_from(">II", raw, 0x20 + i * 8)
                    direct.append((w0 & 0xFFFFFF, w1 >> 24, w1 & 0xFFFFFF))
                exts = []
                if numex <= 12:
                    exts = [e for e in direct[:max(numex, 0)] if e[1]]
                else:
                    nind = max(1, direct[0][2])
                    left = numex
                    for bn, length, _o in direct[:nind]:
                        if not length:
                            continue
                        self.claim(bn, length, num, -1)   # the indirect extent block itself
                        data = self.blk(bn, length)
                        for i in range(0, len(data) - 7, 8):
                            if left <= 0:
                                break
                            w0, w1 = struct.unpack_from(">II", data, i)
                            left -= 1
                            if w1 >> 24:
                                exts.append((w0 & 0xFFFFFF, w1 >> 24, w1 & 0xFFFFFF))
                for bn, length, off in exts:
                    self.claim(bn, length, num, off * BB)
                self.inodes[num] = exts
        stack, seen = [2], set()
        while stack:
            d = stack.pop()
            if d in seen:
                continue
            seen.add(d)
            for nm, n in self.listdir(d).items():
                if nm in (".", ".."):
                    continue
                self.names.setdefault(n, self.names[d].rstrip("/") + "/" + nm)
                raw = self.ino_raw.get(n)
                if raw and (struct.unpack_from(">H", raw, 0)[0] & IFMT) == IFDIR:
                    stack.append(n)

    def listdir(self, num):
        out = {}
        for bn, length, _o in self.inodes.get(num, []):
            data = self.blk(bn, length)
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
        num = 2
        for part in [p for p in path.strip("/").split("/") if p]:
            ents = self.listdir(num)
            if part not in ents:
                return None
            num = ents[part]
        return num

    def read_file(self, num):
        raw = self.ino_raw[num]
        size = struct.unpack_from(">i", raw, 8)[0]
        buf = bytearray(size)
        for bn, length, off in self.inodes[num]:
            data = self.blk(bn, length)
            s = off * BB
            if s >= size:
                continue
            n = min(len(data), size - s)
            buf[s:s + n] = data[:n]
        return bytes(buf)

    def what(self, bn):
        if bn in self.owner:
            num, off = self.owner[bn]
            where = "indirect extents" if off < 0 else "+%#x" % off
            return "inode %d %s %s" % (num, self.names.get(num, "?"), where)
        if bn < self.firstcg:
            return "superblock/bitmap area"
        rel = (bn - self.firstcg) % self.cgfsize
        if rel < self.cgisize:
            cg = (bn - self.firstcg) // self.cgfsize
            first = cg * self.cgisize * 4 + rel * 4
            return "inode table (inodes %d-%d: %s)" % (
                first, first + 3,
                ", ".join(self.names.get(first + k, "-") for k in range(4)))
        return "free"


def main():
    used_p, pri_p = sys.argv[1], sys.argv[2]
    part = int(sys.argv[sys.argv.index("--part") + 1]) if "--part" in sys.argv else 0
    maxshow = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 60
    srcs = []
    if "--src" in sys.argv:
        for a in sys.argv[sys.argv.index("--src") + 1:]:
            if a.startswith("--"):
                break
            srcs.append(a)
    copies = []
    if "--copies" in sys.argv:
        for a in sys.argv[sys.argv.index("--copies") + 1:]:
            if a.startswith("--"):
                break
            copies.append(a)
    used, pri = Fs(used_p, part), Fs(pri_p, part)

    # 1. block-level diff of the partition, 1 MB at a time
    diff = []
    CH = 2048
    total = pri.size
    for start in range(0, total, CH):
        n = min(CH, total - start)
        a, b = used.blk(start, n), pri.blk(start, n)
        if a == b:
            continue
        for k in range(n):
            if a[k * BB:(k + 1) * BB] != b[k * BB:(k + 1) * BB]:
                diff.append(start + k)
    print("%d basic blocks differ (of %d)" % (len(diff), total))
    cap = int(sys.argv[sys.argv.index("--diffmax") + 1]) if "--diffmax" in sys.argv else 400000
    if len(diff) > cap:
        print("  (more than %d: only the first %d are given owners)" % (cap, cap))
        diff = diff[:cap]

    used.watch = diff            # owners are resolved for these blocks only
    pri.watch = diff
    used.load()
    pri.load()

    # 2. classify
    foreign = []
    groups = defaultdict(int)
    for bn in diff:
        u, p = used.what(bn), pri.what(bn)
        un = used.owner.get(bn, (None,))[0]
        pn = pri.owner.get(bn, (None,))[0]
        # Everything but di_atime (bytes 12-15): reading a file - `sum` does -
        # updates it, and a file that was only read is exactly the victim this
        # is looking for.
        ur, pr = used.ino_raw.get(un), pri.ino_raw.get(un)
        same_inode = (un is not None and un == pn and ur is not None and pr is not None
                      and ur[:12] == pr[:12] and ur[16:] == pr[16:])
        if same_inode and used.owner[bn][1] < 0 and used.inodes.get(un) == pri.inodes.get(un):
            # An indirect extent block whose extents all read the same: IRIX
            # writes the block back from its in-core copy when the inode is
            # updated (an atime change is enough), and the unused tail of the
            # 512 bytes carries whatever that buffer held. Seen on the Sep 1
            # images - not a misplaced write.
            groups["extent block tail rewritten " + u] += 1
        elif same_inode:
            foreign.append(bn)
            groups["FOREIGN " + u.rsplit(" +", 1)[0]] += 1
        else:
            groups["%s  <-  %s" % (u.rsplit(" +", 1)[0], p.rsplit(" +", 1)[0])] += 1
    print("\nchanged blocks by owner (used <- pristine):")
    for k, v in sorted(groups.items(), key=lambda kv: -kv[1])[:maxshow]:
        print("  %6d  %s" % (v, k))

    bad_copies = 0
    if len(copies) >= 2:
        sn = used.resolve(copies[0])
        ref = used.read_file(sn) if sn is not None else None
        print("\ncopies of %s (%s bytes):" % (copies[0], len(ref) if ref is not None else "?"))
        for dst in copies[1:]:
            dn = used.resolve(dst)
            if dn is None or ref is None:
                print("  %s: not found" % dst)
                bad_copies += 1
                continue
            got = used.read_file(dn)
            if got == ref:
                print("  %s: identical" % dst)
                continue
            bad_copies += 1
            blocks = sorted({i // BB for i in range(min(len(got), len(ref))) if got[i] != ref[i]})
            print("  %s: DIFFERS (%d bytes vs %d), %d blocks: %s"
                  % (dst, len(got), len(ref), len(blocks), blocks[:20]))
            for b in blocks[:3]:
                blk = got[b * BB:(b + 1) * BB]
                k = ref.find(blk)
                print("      block %d holds %s" % (b, ("the source's +%#x" % k) if k >= 0
                                                  else blk[:24].hex()))

    print("\nFOREIGN blocks (the inode is identical in both images, the data is not): %d"
          % len(foreign))
    if not foreign:
        print("EFSDIFF CLEAN" if not bad_copies else "EFSDIFF BADCOPY %d" % bad_copies)
        return

    # 3. where did the data come from?
    index = {}
    for s in srcs:
        num = used.resolve(s)
        if num is None:
            print("  (source %s not found)" % s)
            continue
        data = used.read_file(num)
        for off in range(0, len(data) - BB + 1, BB):
            index.setdefault(hashlib.md5(data[off:off + BB]).digest(), (s, off))
    for bn in foreign[:maxshow]:
        a, b = used.blk(bn), pri.blk(bn)
        nd = sum(1 for i in range(BB) if a[i] != b[i])
        src = index.get(hashlib.md5(a).digest())
        # the same content anywhere else among the changed blocks?
        print("  bb %d  %s  %d bytes differ; used data %s"
              % (bn, used.what(bn), nd,
                 ("= %s +%#x" % src) if src else "not found in sources"))
        print("      used     %s" % a[:24].hex())
        print("      pristine %s" % b[:24].hex())
    print("EFSDIFF FOREIGN %d%s" % (len(foreign), (" BADCOPY %d" % bad_copies) if bad_copies else ""))


main()
