#!/usr/bin/env python3
"""Look inside an SGI disk image's partition, and find a file's first bytes.

WHY. When the PROM says a file it just installed has the wrong magic number,
the question is whether the bytes on the medium are wrong (the write path) or
whether they were fine and came back wrong (the read path). A SCSI image on this
core is an ordinary file on the SD card, so both can be answered without the
core in the loop - but only if something can find the file inside the
filesystem the guest wrote.

IRIX 5.3's installer puts its miniroot in the SWAP partition and boots
partition(1)/unix.IP22 out of it, so the filesystem to walk is EFS.

EFS, only as much of it as this needs:
  * the superblock is at byte offset 512 of the partition (basic block 1),
    magic 0x00072959 (EFS_MAGIC) or 0x0007295A (EFS_NEWMAGIC);
  * sb_firstcg / sb_cgfsize / sb_cgisize give the cylinder-group layout, and
    inodes live at the start of each group;
  * an inode is 128 bytes: di_mode, di_nlink, di_uid, di_gid, di_size, three
    times, then 12 extents of 8 bytes each. An extent is
    {bb:24, ex:8, offset:24, nbytes:8} packed big-endian;
  * a directory block is 512 bytes: magic 0xBEEF, firstused, slots, then
    offsets, with each entry being {inum:4, namelen:1, name[]}.

    python3 efspeek.py IMAGE PART_FIRST_LBN [NAME]

PART_FIRST_LBN is the partition's first block from sgivh.py. With no NAME it
lists the root directory; with one it prints that file's size, its first extent
and the first 64 bytes of its contents.
"""
import struct
import sys

BB = 512


def rd(fh, off, n):
    fh.seek(off)
    return fh.read(n)


def main():
    path = sys.argv[1]
    base = int(sys.argv[2]) * BB
    want = sys.argv[3] if len(sys.argv) > 3 else None
    fh = open(path, "rb")

    sb = rd(fh, base + BB, BB)
    magic = struct.unpack_from(">I", sb, 0x48)[0]
    # sb_magic sits at 0x48 in the EFS superblock; probe a little either way if
    # this image was made by a version that laid it out differently.
    if magic not in (0x00072959, 0x0007295A):
        found = None
        for off in range(0, BB - 4, 4):
            v = struct.unpack_from(">I", sb, off)[0]
            if v in (0x00072959, 0x0007295A):
                found = off
                break
        if found is None:
            print("no EFS superblock in the first block of the partition")
            print("partition first 64 bytes: %s" % rd(fh, base, 64).hex())
            print("block 1     first 64 bytes: %s" % sb[:64].hex())
            return
        print("(superblock magic found at offset 0x%x, not the expected 0x48)" % found)
        magic = struct.unpack_from(">I", sb, found)[0]

    size, firstcg, cgfsize = struct.unpack_from(">iii", sb, 0)
    cgisize, sectors, heads, ncg = struct.unpack_from(">hhhh", sb, 12)
    print("EFS superblock magic 0x%08X" % magic)
    print("  size %d bb, firstcg %d, cgfsize %d, cgisize %d, ncg %d"
          % (size, firstcg, cgfsize, cgisize, ncg))

    def inode(num):
        # Inodes are packed cgisize basic blocks at the head of each cylinder
        # group, 4 to a block.
        ipbb = BB // 128
        cg = num // (cgisize * ipbb)
        idx = num % (cgisize * ipbb)
        bb = firstcg + cg * cgfsize + idx // ipbb
        raw = rd(fh, base + bb * BB, BB)
        return raw[(idx % ipbb) * 128:(idx % ipbb) * 128 + 128]

    def extents(ino):
        out = []
        for i in range(12):
            w0, w1 = struct.unpack_from(">II", ino, 20 + i * 8)
            bb = (w0 >> 8) & 0xFFFFFF
            nbytes = w1 & 0xFF
            off = (w1 >> 8) & 0xFFFFFF
            if nbytes:
                out.append((bb, off, nbytes))
        return out

    root = inode(2)
    rsize = struct.unpack_from(">i", root, 8)[0]
    print("  root inode: mode 0x%04X size %d" % (struct.unpack_from(">H", root, 0)[0], rsize))

    names = {}
    for bb, off, n in extents(root):
        for k in range(n):
            blk = rd(fh, base + (bb + k) * BB, BB)
            if struct.unpack_from(">H", blk, 0)[0] != 0xBEEF:
                continue
            slots = blk[3]
            for s in range(slots):
                o = blk[4 + s] * 2
                if o < 4 or o >= BB - 5:
                    continue
                inum = struct.unpack_from(">I", blk, o)[0]
                nl = blk[o + 4]
                nm = blk[o + 5:o + 5 + nl].decode("latin1", "replace")
                if nm:
                    names[nm] = inum

    if want is None:
        print("\nroot directory:")
        for nm in sorted(names):
            print("  %-20s inode %d" % (nm, names[nm]))
        return

    if want not in names:
        print("\n%r is not in the root directory. It has: %s"
              % (want, ", ".join(sorted(names))))
        return

    ino = inode(names[want])
    fsize = struct.unpack_from(">i", ino, 8)[0]
    ex = extents(ino)
    print("\n%s: inode %d, size %d bytes, %d extents" % (want, names[want], fsize, len(ex)))
    for bb, off, n in ex[:4]:
        print("   extent bb %d (byte 0x%x)  offset %d  %d blocks"
              % (bb, base + bb * BB, off, n))
    if ex:
        head = rd(fh, base + ex[0][0] * BB, 64)
        print("\n  first 64 bytes of %s:" % want)
        print("   ", head.hex())
        print("    f_magic = 0x%04X" % struct.unpack_from(">H", head, 0)[0])


main()
