#!/usr/bin/env python3
"""Find the source of something the guest wrote, and diff it byte for byte.

THIS IS THE TOOL THAT SEPARATES A WRITE FAULT FROM A READ FAULT, and nothing
else this project has can do it. A SCSI image on this core is an ordinary file
on the MiSTer's SD card, so when the guest copies data from the CD to the disk
BOTH ends are files the ARM can read with the core entirely out of the loop:

  * if the copy on the disk differs from the copy on the CD, the write path
    corrupted it;
  * if they are identical and the guest still reads it back wrong, the read
    path did.

Given a chunk of the destination, it looks for that chunk in the source by its
first bytes, then compares the whole run.

    python3 imgdiff.py SRC DST DST_OFF LEN [--sig N] [--max-report N]

SRC      the file the data came from (an ISO, say)
DST      the file it was written to (a disk image)
DST_OFF  byte offset in DST where the run starts
LEN      how many bytes to compare

--sig N  how many bytes of DST to use as the search key (default 64). Too few
         and it matches noise; too many and a corrupted first block hides the
         match entirely, which is exactly the case being investigated - so if
         the default finds nothing, try 16.
"""
import sys

CHUNK = 1 << 20


def main():
    src, dst = sys.argv[1], sys.argv[2]
    dst_off = int(sys.argv[3], 0)
    length = int(sys.argv[4], 0)
    sig = 64
    maxrep = 24
    a = sys.argv[5:]
    while a:
        if a[0] == "--sig":
            sig = int(a[1]); a = a[2:]
        elif a[0] == "--max-report":
            maxrep = int(a[1]); a = a[2:]
        else:
            sys.exit("unknown argument %r" % a[0])

    with open(dst, "rb") as fh:
        fh.seek(dst_off)
        key = fh.read(sig)
    print("key (%d bytes from %s+0x%x): %s" % (sig, dst, dst_off, key[:32].hex()))

    # Search the source for the key, streaming with an overlap so a match that
    # straddles a chunk boundary is not missed.
    hits = []
    with open(src, "rb") as fh:
        pos = 0
        tail = b""
        while True:
            buf = fh.read(CHUNK)
            if not buf:
                break
            hay = tail + buf
            base = pos - len(tail)
            i = hay.find(key)
            while i >= 0:
                hits.append(base + i)
                if len(hits) >= 8:
                    break
                i = hay.find(key, i + 1)
            if len(hits) >= 8:
                break
            pos += len(buf)
            tail = buf[-(sig - 1):] if sig > 1 else b""
    if not hits:
        print("NOT FOUND in %s - the guest did not copy this verbatim, or the "
              "first %d bytes are themselves corrupt (try --sig 16)" % (src, sig))
        return 2
    print("found at: %s" % ", ".join("0x%x" % h for h in hits))

    src_off = hits[0]
    print("\ncomparing %d bytes: %s+0x%x  vs  %s+0x%x"
          % (length, src, src_off, dst, dst_off))
    bad = 0
    first = []
    hist = {}
    blocks = set()
    with open(src, "rb") as fs, open(dst, "rb") as fd:
        fs.seek(src_off)
        fd.seek(dst_off)
        done = 0
        while done < length:
            n = min(CHUNK, length - done)
            x = fs.read(n)
            y = fd.read(n)
            if len(x) < n or len(y) < n:
                n = min(len(x), len(y))
                x, y = x[:n], y[:n]
                if n == 0:
                    print("(ran off the end of a file after %d bytes)" % done)
                    break
            if x != y:
                for k in range(n):
                    if x[k] != y[k]:
                        bad += 1
                        o = done + k
                        hist[o & 511] = hist.get(o & 511, 0) + 1
                        blocks.add(o >> 9)
                        if len(first) < maxrep:
                            first.append((done + k, x[k], y[k]))
            done += n

    print("compared %d bytes, %d differ (%.3g%%)"
          % (done, bad, 100.0 * bad / done if done else 0))

    # WHERE IN A BLOCK THE DAMAGE FALLS IS THE WHOLE DIAGNOSIS. A transfer that
    # is wrong everywhere is a byte-lane or endianness fault; one that is wrong
    # only at particular offsets within a 512-byte block is a boundary fault in
    # whatever moves the block, and the offset says which boundary.
    if bad:
        print("\n  differing bytes by offset within the 512-byte block:")
        top = sorted(hist.items(), key=lambda kv: -kv[1])[:12]
        for off, n in top:
            print("    +0x%03x  %8d" % (off, n))
        others = bad - sum(n for _, n in top)
        if others > 0:
            print("    (%d more across %d other offsets)"
                  % (others, len(hist) - len(top)))
        print("  blocks touched: %d of %d  (%d clean)"
              % (len(blocks), done // 512, done // 512 - len(blocks)))

    if first:
        print("\n  run offset   disk byte-offset   source  disk   xor")
        for off, sb, db in first:
            print("  0x%08x   0x%010x      0x%02x    0x%02x   0x%02x"
                  % (off, dst_off + off, sb, db, sb ^ db))
    return 1 if bad else 0


sys.exit(main())
