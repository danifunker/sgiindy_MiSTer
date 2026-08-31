#!/usr/bin/env python3
"""Parse an SGI disk image's volume header. RUNS ANYWHERE - it is just a file.

WHY THIS IS THE RIGHT FIRST TOOL FOR A BAD READ-BACK. A SCSI image mounted on
this core is an ordinary file on the MiSTer's SD card, so what the guest wrote
can be read WITHOUT the core in the loop. That separates the two halves of any
"the data came back wrong" question - if the bytes on the card are already
wrong the write path corrupted them, and if they are right the read path did -
and nothing else this project has can separate those two.

The volume header is block 0 and it is 512 bytes with a checksum over the whole
of it, which makes it a free integrity test of one block the guest wrote:

    0x000  vh_magic     0x0BE5A941
    0x004  vh_rootpt    root partition number
    0x006  vh_swappt    swap partition number
    0x008  vh_bootfile  16 bytes, the default standalone program
    0x018  vh_dp        48 bytes of device parameters
    0x048  vh_vd[15]    volume directory: 8-byte name, lbn, nbytes
    0x138  vh_pt[16]    partition table: nblks, firstlbn, type
    0x1F8  vh_csum      32-bit sum of the 128 words, must be zero
    0x1FC  vh_fill

All big-endian, because the machine is.

    python3 sgivh.py /media/fat/games/SGIIndy/indy1GB.img
"""
import struct
import sys

PTYPE = {0: "VOLHDR", 1: "TRKREPL", 2: "SECREPL", 3: "RAW(swap)", 4: "BSD4.2",
         5: "SYSV", 6: "VOLUME", 7: "EFS", 8: "LVOL", 9: "RLVOL", 10: "XFS",
         11: "XFSLOG", 12: "XLV", 13: "XVM"}


def main():
    path = sys.argv[1]
    with open(path, "rb") as fh:
        vh = fh.read(512)
    if len(vh) < 512:
        sys.exit("short read")

    magic, rootpt, swappt = struct.unpack_from(">IhH", vh, 0)
    print("magic      0x%08X  %s" % (magic, "OK" if magic == 0x0BE5A941 else "NOT AN SGI VOLUME HEADER"))
    if magic != 0x0BE5A941:
        print("first 64 bytes:", vh[:64].hex())
        return
    print("rootpt     %d" % rootpt)
    print("swappt     %d" % swappt)
    print("bootfile   %r" % vh[8:24].split(b"\0")[0].decode("latin1"))

    # The checksum is over the header as 128 big-endian words and must sum to 0.
    words = struct.unpack_from(">128i", vh, 0)
    print("checksum   %s (sum 0x%08X)"
          % ("VALID" if (sum(words) & 0xFFFFFFFF) == 0 else "*** BAD ***",
             sum(words) & 0xFFFFFFFF))

    print("\nvolume directory (standalone files living outside any filesystem):")
    any_vd = False
    for i in range(15):
        off = 0x48 + i * 16
        name = vh[off:off + 8].split(b"\0")[0].decode("latin1")
        lbn, nbytes = struct.unpack_from(">ii", vh, off + 8)
        if name:
            any_vd = True
            print("  %-8s lbn %8d  %9d bytes  (byte offset 0x%x)"
                  % (name, lbn, nbytes, lbn * 512))
    if not any_vd:
        print("  (empty)")

    print("\npartition table:")
    for i in range(16):
        off = 0x138 + i * 12
        nblks, first, ptype = struct.unpack_from(">iii", vh, off)
        if nblks:
            print("  %2d  %10d blocks  first %9d  type %2d %-10s  (bytes 0x%x..0x%x)"
                  % (i, nblks, first, ptype, PTYPE.get(ptype, "?"),
                     first * 512, (first + nblks) * 512))


main()
