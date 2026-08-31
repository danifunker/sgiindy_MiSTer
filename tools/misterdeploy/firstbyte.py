#!/usr/bin/env python3
"""Where does the wrong first byte of each written block come from?

imgdiff.py established that the guest's copy differs from its source almost
entirely at offset 0 of the 512-byte block - roughly 38,000 blocks out of
51,200, each with exactly one bad byte and 511 good ones. That is not noise and
it is not a byte-lane error; it is something wrong at the START of every block
the target buffers.

The question this answers is which byte lands there instead, because the answer
names the mechanism:

  * source[N-1][0]  - the buffer kept the PREVIOUS block's first byte, so the
                      first byte of each block was never written at all;
  * source[N][1]    - the block was written one byte early, i.e. the write
                      pointer started at -1 and the first byte fell off;
  * source[N+k][0]  - the stream ran ahead by k blocks before the first byte
                      was latched;
  * something else  - report it rather than forcing a story onto it.

Only blocks whose ONLY difference is at offset 0 are counted. Blocks that
differ everywhere are a separate population (the installer does not copy the
whole miniroot verbatim) and would drown the signal.

    python3 firstbyte.py SRC SRC_OFF DST DST_OFF LEN
"""
import sys
from collections import Counter

BS = 512


def main():
    src, dst = sys.argv[1], sys.argv[3]
    src_off, dst_off = int(sys.argv[2], 0), int(sys.argv[4], 0)
    length = int(sys.argv[5], 0)

    fs, fd = open(src, "rb"), open(dst, "rb")
    fs.seek(src_off)
    fd.seek(dst_off)
    s = fs.read(length)
    d = fd.read(length)
    n = min(len(s), len(d)) // BS
    print("comparing %d blocks of %d bytes" % (n, BS))

    only0 = []
    for b in range(n):
        so = s[b * BS:(b + 1) * BS]
        do = d[b * BS:(b + 1) * BS]
        if so == do:
            continue
        if so[0] != do[0] and so[1:] == do[1:]:
            only0.append(b)

    print("blocks whose ONLY wrong byte is offset 0: %d" % len(only0))
    if not only0:
        return

    # Which candidate explains the byte that actually landed there?
    cands = Counter()
    for b in only0:
        got = d[b * BS]
        for k in range(-4, 5):
            j = b + k
            if 0 <= j < n and s[j * BS] == got:
                cands["source[N%+d][0]" % k] += 1
        if s[b * BS + 1] == got:
            cands["source[N][1]"] += 1
        if b > 0 and d[(b - 1) * BS] == got:
            cands["disk[N-1][0]"] += 1
        if got == 0:
            cands["zero"] += 1

    print("\nwhat the byte at offset 0 actually was, over those %d blocks:" % len(only0))
    for name, c in cands.most_common(12):
        print("  %-18s %7d   (%.1f%%)" % (name, c, 100.0 * c / len(only0)))

    print("\nfirst 16 of them, block: source[0] -> disk[0], with the source's")
    print("neighbouring first bytes for context (N-2 N-1 N N+1 N+2):")
    for b in only0[:16]:
        ctx = " ".join("%02x" % s[(b + k) * BS] if 0 <= b + k < n else "--"
                       for k in (-2, -1, 0, 1, 2))
        print("  block %6d: %02x -> %02x    [%s]" % (b, s[b * BS], d[b * BS], ctx))


main()
