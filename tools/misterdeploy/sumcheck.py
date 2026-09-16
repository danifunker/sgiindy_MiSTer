#!/usr/bin/env python3
"""Check files IRIX checksummed and wrote against the disk image itself. RUNS ON THE DEVICE.

scripts/diskcheck.sh has IRIX run `sum` and `sum -r` over a few files and copy
one of them, then halts the machine. This reads the same files straight out of
the image with efsread.py - no emulated CPU, SCSI or DMA in the path - and says
whether what IRIX computed matches the bytes on disk (the DATA IN path) and
whether the copy IRIX wrote is byte-identical to its source (the DATA OUT
path).

    sumcheck.py IMAGE SUMS_FILE_IN_IMAGE SRC COPY FILE...
"""
import hashlib
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def sysv_sum(data):
    """SysV `sum`: byte sum folded to 16 bits, 512-byte blocks."""
    s = sum(data) & 0xFFFFFFFF
    r = (s & 0xFFFF) + (s >> 16)
    r = (r & 0xFFFF) + (r >> 16)
    return r, (len(data) + 511) // 512


def bsd_sum(data):
    """BSD `sum -r`: 16-bit rotate-and-add. IRIX's prints 512-byte blocks."""
    c = 0
    for b in data:
        c = (c >> 1) + ((c & 1) << 15)
        c = (c + b) & 0xFFFF
    return c, (len(data) + 511) // 512


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    image, sums_path, src, copy = sys.argv[1:5]
    files = sys.argv[5:]
    tmp = tempfile.mkdtemp(prefix="sumcheck")
    ok = True

    def get(path):
        out = os.path.join(tmp, os.path.basename(path) + "." + hashlib.md5(path.encode()).hexdigest()[:6])
        rc = os.system("python3 %s %s get %s %s >/dev/null 2>&1" % (
            os.path.join(HERE, "efsread.py"), image, path, out))
        if rc != 0 or not os.path.exists(out):
            return None
        with open(out, "rb") as f:
            return f.read()

    sums = get(sums_path)
    print("---- what IRIX computed (%s) ----" % sums_path)
    print(sums.decode(errors="replace") if sums else "(missing)")
    if sums is None:
        ok = False
    lines = sums.decode(errors="replace").splitlines() if sums else []

    print("---- the same files read off the image ----")
    for path in files:
        data = get(path)
        if data is None:
            print("%s: not readable from the image" % path)
            ok = False
            continue
        sv, sb = sysv_sum(data)
        bv, bb = bsd_sum(data)
        want_sysv = "%d %d %s" % (sv, sb, path)
        want_bsd = "%05d %5d %s" % (bv, bb, path)
        hit_sysv = any(l.split()[:2] == [str(sv), str(sb)] and l.split()[-1] == path for l in lines if len(l.split()) >= 3)
        hit_bsd = any(len(l.split()) >= 3 and l.split()[0].isdigit() and int(l.split()[0]) == bv and
                      l.split()[1] == str(bb) and l.split()[-1] == path for l in lines)
        if len(data) < 512 and not (hit_sysv or hit_bsd):
            print("%s: only %d bytes in the image - a symlink? `sum` follows links, efsread does not" % (path, len(data)))
        print("%s: %d bytes, md5 %s; sysv %s [%s]; bsd %s [%s]" % (
            path, len(data), hashlib.md5(data).hexdigest(),
            want_sysv, "IRIX agrees" if hit_sysv else "NO MATCH in IRIX's output",
            want_bsd, "IRIX agrees" if hit_bsd else "NO MATCH in IRIX's output"))
        if not (hit_sysv and hit_bsd):
            ok = False

    a, b = get(src), get(copy)
    if a is None or b is None:
        print("copy check: %s or %s not readable from the image" % (src, copy))
        ok = False
    elif a == b:
        print("copy check: %s is byte-identical to %s (%d bytes)" % (copy, src, len(a)))
    else:
        first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        print("copy check: %s DIFFERS from %s (%d vs %d bytes, first difference at offset %d)" % (
            copy, src, len(b), len(a), first))
        ok = False

    print("DISKCHECK %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
