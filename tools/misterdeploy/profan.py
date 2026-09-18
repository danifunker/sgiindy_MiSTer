#!/usr/bin/env python3
"""Read a prof.py capture on the host: where the time went, and how.

Every sample is classified twice:

  WHERE  idle (the PC in wait_for_interrupt / idle), kernel (a named /unix
         procedure), or user (a shared library's text by so_locations, or
         the program's own text below 0x10000000).
  HOW    advancing (stall vector clear), or held: stall1 = the fetch stage
         (an instruction-cache fill, an uncached fetch, or an instruction
         mini-TLB walk), stall3 = execute (a data-cache fill, an uncached
         load/store - which includes every device register - a data TLB
         walk, a multiply/divide), stall2 / stall4 = decode / writeback.
         Bits 10/11 of word 10 say a TLB walk is in progress.

    python profan.py CAPTURE.bin [--unix unix.ecoff] [--so so_locations]
                     [--top 25] [--series 10]

The kernel symbol table comes from ecoffsyms.py, reading the kernel the
capture was taken under - extract it from the disk image with
`efsread.py IMAGE get /unix unix.ecoff`. so_locations comes off the image the
same way (efsread.py IMAGE get /usr/lib/so_locations so_locations).
"""
import argparse
import bisect
import os.path as _p
import sys as _s
_s.path.insert(0, _p.dirname(_p.abspath(__file__)))
import collections
import os
import re
import struct
import subprocess
import sys

HDR = b"SGIPROF1"
NWORDS = 21
IDLE = ((0x88012adc, 0x88012b64), (0x8802befc, 0x8802bfa0))
CLK_HZ = 50_000_000


def load_capture(path):
    """(start snapshot, records, end snapshot). A snapshot is (time, w0, w1..);
    a record is (time, w0, w10, w13, w15, w40), w40 = 0 before SGIPROF3.
    SGIPROF1 captures carry 21 words; SGIPROF2/3 name their word count."""
    data = open(path, "rb").read()
    hdr = data[:8]
    assert hdr in (b"SGIPROF1", b"SGIPROF2", b"SGIPROF3"), "not a prof.py capture"
    if hdr == b"SGIPROF1":
        nwords, pre = NWORDS, 8
    else:
        nwords, pre = struct.unpack_from("<I", data, 8)[0], 12
    snap_fmt = "<d%dQ" % nwords
    snap_len = struct.calcsize(snap_fmt)
    start = struct.unpack_from(snap_fmt, data, pre)
    off = pre + snap_len
    end_hdr = data.rfind(hdr)
    rec = struct.Struct("<dQQQQQ" if hdr == b"SGIPROF3" else "<dQQQQ")
    recs = []
    while off + rec.size <= end_hdr:
        r = rec.unpack_from(data, off)
        recs.append(r if len(r) == 6 else r + (0,))
        off += rec.size
    end = struct.unpack_from(snap_fmt, data, end_hdr + pre) if end_hdr > 8 else None
    return start, recs, end


def kernel_procs(unix):
    here = os.path.dirname(os.path.abspath(__file__))
    tool = os.path.join(here, "ecoffsyms.py")
    procs = {}
    for mode in ("syms", "lsyms"):
        out = subprocess.run([sys.executable, tool, unix, mode],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = re.match(r"([0-9a-f]{8})\s+(?:proc\s+|st=proc\s+sc=\s*\d+\s+)(\S+)$", line)
            if not m:
                m = re.match(r"([0-9a-f]{8})\s+st=proc\s+sc=\s*\d+\s+(\S+)", line)
            if m:
                procs.setdefault(int(m.group(1), 16), m.group(2))
    addrs = sorted(procs)
    return addrs, [procs[a] for a in addrs]


def so_ranges(path):
    ranges = []
    if not path or not os.path.exists(path):
        return ranges
    name = None
    for line in open(path, encoding="latin-1"):
        m = re.match(r"^(\S+)\s*\\\s*$", line)
        if m:
            name = m.group(1)
            continue
        m = re.search(r"\.text\s+0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)", line)
        if m and name:
            lo, sz = int(m.group(1), 16), int(m.group(2), 16)
            ranges.append((lo, lo + sz, name))
    return sorted(ranges)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, "..", ".."))
    ap.add_argument("--unix", default=os.path.join(root, "unix.ecoff"),
                    help="%s" % "IRIX's kernel: extract it from the system disk image with tools/misterdeploy/efsread.py IMAGE get /unix unix.ecoff")
    ap.add_argument("--so", default=os.environ.get("SO_LOCATIONS", ""))
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--series", type=float, default=0.0,
                    help="print a time series in buckets of this many seconds")
    a = ap.parse_args()

    start, recs, end = load_capture(a.capture)
    if not recs:
        sys.exit("no samples")
    kaddr, kname = kernel_procs(a.unix)
    sor = so_ranges(a.so)
    so_lo = [r[0] for r in sor]

    def where(pc):
        for lo, hi in IDLE:
            if lo <= pc < hi:
                return "idle", "(idle)"
        # The PROM (kseg1 0xBFC..., and 0x9FC... where it runs cached) is not
        # in /unix's symbol table: without this its time goes to the last
        # kernel symbol below it (qt_dqrele).
        if pc >= 0xBFC00000 or 0x9FC00000 <= pc < 0xA0000000:
            return "kernel", "(PROM)"
        if pc >= 0x80000000:
            i = bisect.bisect_right(kaddr, pc) - 1
            return "kernel", (kname[i] if i >= 0 else "?k")
        i = bisect.bisect_right(so_lo, pc) - 1
        if i >= 0 and pc < sor[i][1]:
            return "user", sor[i][2]
        if pc < 0x10000000:
            return "user", "(program text %07x)" % (pc >> 16 << 16)
        return "user", "(user %08x)" % (pc >> 20 << 20)

    def how(w10):
        st = (w10 >> 13) & 0x1F
        if st == 0:
            return "run"
        if st & 0x04:
            return "exec-stall"
        if st & 0x01:
            return "fetch-stall"
        if st & 0x08:
            return "wb-stall"
        return "dec-stall"

    def tlbwalk(w10):
        return (w10 >> 10) & 3

    n = len(recs)
    dur = recs[-1][0] - recs[0][0]
    cls = collections.Counter()
    howc = collections.Counter()
    by_fn = collections.defaultdict(collections.Counter)
    n_tlb = 0
    split = collections.Counter()
    beats = set()
    for t, w0, w10, w13, w15, w40 in recs:
        pc = w10 >> 32
        c, fn = where(pc)
        h = how(w10)
        cls[c] += 1
        if c != "idle":
            howc[h] += 1
            tw = tlbwalk(w10)
            split[(h, "tlbi" if tw & 2 else "tlbd" if tw & 1 else "other")] += 1
        by_fn[(c, fn)][h] += 1
        if (w10 >> 10) & 3:
            n_tlb += 1
        beats.add(w0 & 0xFFFFFFFF)

    pct = lambda x, d=n: 100.0 * x / d if d else 0.0
    print("%s: %d samples over %.1f s (%.0f Hz), %d distinct beacon sweeps"
          % (os.path.basename(a.capture), n, dur, n / dur if dur else 0, len(beats)))
    busy = n - cls["idle"]
    print("  idle %.1f %%   kernel %.1f %%   user %.1f %%"
          % (pct(cls["idle"]), pct(cls["kernel"]), pct(cls["user"])))
    if busy:
        print("  of the busy time: running %.1f %%, fetch-stalled %.1f %%, "
              "exec-stalled %.1f %%, writeback-stalled %.1f %%, decode %.1f %%; "
              "TLB walk bits set in %.1f %% of all samples"
              % (pct(howc["run"], busy), pct(howc["fetch-stall"], busy),
                 pct(howc["exec-stall"], busy), pct(howc["wb-stall"], busy),
                 pct(howc["dec-stall"], busy), pct(n_tlb)))
        print("  busy time by stage and TLB walk (tlbi = instruction walk, tlbd = data walk): "
              + ", ".join("%s/%s %.1f %%" % (h, w, pct(split[(h, w)], busy))
                          for h in ("fetch-stall", "exec-stall", "wb-stall", "run")
                          for w in ("tlbi", "tlbd", "other") if split[(h, w)]))

    print("\n  top places (share of all samples; how that place spent it)")
    ranked = sorted(by_fn.items(), key=lambda kv: -sum(kv[1].values()))
    for (c, fn), hc in ranked[:a.top]:
        tot = sum(hc.values())
        print("  %5.1f %%  %-6s %-34s run %3.0f  fetch %3.0f  exec %3.0f  wb %3.0f"
              % (pct(tot), c, fn[:34], pct(hc["run"], tot), pct(hc["fetch-stall"], tot),
                 pct(hc["exec-stall"], tot), pct(hc["wb-stall"], tot)))

    # WHO CALLED IT (beacon ver 13, word 40 = register 31 at retirement). A
    # sample inside a leaf routine - us_delay, bcopy, bzero - leaves the return
    # address of the call that got there in r31; for anything else it is the
    # last call that routine made, which still says where it is.
    ver = ((start[1] >> 40) & 0xFF) if start and ((start[1] >> 48) & 0xFFFF) == 0xBEC0 else 0
    if ver >= 13 and any(r[5] for r in recs):
        callers = collections.defaultdict(collections.Counter)
        for t, w0, w10, w13, w15, w40 in recs:
            c, fn = where(w10 >> 32)
            if c != "kernel":
                continue
            ra = (w40 >> 32) & 0xFFFFFFFF
            rc, rfn = where(ra)
            i = bisect.bisect_right(kaddr, ra) - 1
            off_s = ("+0x%x" % (ra - kaddr[i])) if (rc == "kernel" and i >= 0
                                                    and not rfn.startswith("(")) else ""
            callers[fn]["%s%s" % (rfn, off_s)] += 1
        print("\n  callers of the top kernel places (register 31 beside the PC, beacon ver 13)")
        kranked = [(fn, hc) for (c, fn), hc in ranked if c == "kernel"][:a.top // 3 or 1]
        for fn, hc in kranked:
            tot = sum(hc.values())
            parts = ", ".join("%s %.0f%%" % (k, 100.0 * v / tot)
                              for k, v in callers[fn].most_common(4))
            print("  %5.1f %%  %-24s <- %s" % (pct(tot), fn[:24], parts))

    # counters integrated across the samples (they wrap)
    nd_wr = nd_rd = lc_miss = la_miss = 0
    prev = None
    for t, w0, w10, w13, w15, w40 in recs:
        cur = ((w13 >> 16) & 0xFFFF, (w13 >> 8) & 0xFF, (w15 >> 48) & 0xFFFF, (w15 >> 32) & 0xFFFF)
        if prev is not None:
            nd_wr += (cur[0] - prev[0]) & 0xFFFF
            nd_rd += (cur[1] - prev[1]) & 0xFF
            lc_miss += (cur[2] - prev[2]) & 0xFFFF
            la_miss += (cur[3] - prev[3]) & 0xFFFF
        prev = cur
    print("\n  VDMA beats into REX3: write %d, read %d;  display line-cache misses: rgb %d, aux %d"
          % (nd_wr, nd_rd, lc_miss, la_miss))
    if (end and start and len(start) >= 36 and ((start[1] >> 48) & 0xFFFF) == 0xBEC0
            and ((start[1] >> 40) & 0xFF) >= 10):
        import perfdiff
        ver = (start[1] >> 40) & 0xFF
        last = (41 if (len(start) >= 41 and ver >= 12)
                else 37 if (len(start) >= 37 and ver >= 11) else 36)
        words = lambda snap: " ".join("%d %d" % (w >> 32, w & 0xFFFFFFFF) for w in snap[22:last])
        ra = perfdiff.parse_line("perf %.3f beat=%d %s" % (start[0], start[1] & 0xFFFFFFFF, words(start)))
        rb = perfdiff.parse_line("perf %.3f beat=%d %s" % (end[0], end[1] & 0xFFFFFFFF, words(end)))
        print("\n  performance counters over the window (beacon ver %d):" % ((start[1] >> 40) & 0xFF))
        for line in perfdiff.report(ra, rb):
            print("    " + line)
    if end and start and ((start[1] >> 48) & 0xFFFF) == 0xBEC0:
        s, e = start[1:], end[1:]
        sec = lambda v: v * 64.0 / CLK_HZ
        b = lambda w, hi, lo: (w >> lo) & ((1 << (hi - lo + 1)) - 1)
        d = lambda i, hi, lo: (b(e[i], hi, lo) - b(s[i], hi, lo)) & ((1 << (hi - lo + 1)) - 1)
        print("  disk over the window: hps xact rd %d wr %d, target wait %.2f s, "
              "DATA %.2f s for %.2f MB, cache hits %d misses %d"
              % (d(16, 63, 32), d(16, 31, 0), sec(d(17, 31, 0)), sec(d(20, 63, 32)),
                 d(19, 63, 32) / 1e6, d(18, 63, 32), d(18, 31, 0)))
        if ((start[1] >> 40) & 0xFF) >= 14 and len(s) >= 43:
            # ver 14: DATA-phase clocks by whose turn it was (sgi_scsi dbg_stat 5-6)
            print("  DATA IN waiting on the initiator %.2f s, on the target %.2f s; "
                  "DATA OUT on the initiator %.2f s, on the target %.2f s"
                  % (sec(d(41, 63, 32)), sec(d(41, 31, 0)), sec(d(42, 63, 32)), sec(d(42, 31, 0))))

    if a.series > 0:
        print("\n  time series (%.0f s buckets): idle / kernel / user %%, and of busy: run / fetch / exec %%" % a.series)
        buckets = collections.defaultdict(collections.Counter)
        for t, w0, w10, w13, w15, w40 in recs:
            k = int(t // a.series)
            c, fn = where(w10 >> 32)
            buckets[k][c] += 1
            if c != "idle":
                buckets[k][how(w10)] += 1
        for k in sorted(buckets):
            bc = buckets[k]
            tot = bc["idle"] + bc["kernel"] + bc["user"]
            bz = tot - bc["idle"]
            print("  %6.0f s  idle %5.1f  kern %5.1f  user %5.1f | run %5.1f  fetch %5.1f  exec %5.1f"
                  % (k * a.series, pct(bc["idle"], tot), pct(bc["kernel"], tot), pct(bc["user"], tot),
                     pct(bc["run"], bz), pct(bc["fetch-stall"], bz), pct(bc["exec-stall"], bz)))


if __name__ == "__main__":
    main()
