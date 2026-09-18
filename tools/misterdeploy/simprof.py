#!/usr/bin/env python3
"""Read a simulator --prof file: clocks per kernel function, and call sites.

verilator/sim_cputest.cpp --prof FILE charges every clock to the decode PC
(stalled clocks counted separately) and, with --prof-callers, records the PC
in front of each entry to the listed addresses - the call's delay slot, so
the call instruction is four bytes before it. This folds both through
unix.ecoff's procedure table (ecoffsyms.py), the same way profan.py folds the
board's samples.

    python simprof.py PROF [--unix unix.ecoff] [--top 40]
"""
import argparse
import bisect
import collections
import os
import re
import subprocess
import sys

IDLE = ((0x88012adc, 0x88012b64), (0x8802befc, 0x8802bfa0))


def kernel_procs(unix):
    here = os.path.dirname(os.path.abspath(__file__))
    tool = os.path.join(here, "ecoffsyms.py")
    procs = {}
    for mode in ("syms", "lsyms"):
        out = subprocess.run([sys.executable, tool, unix, mode],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = re.match(r"([0-9a-f]{8})\s+(?:proc\s+|st=proc\s+sc=\s*\d+\s+)(\S+)", line)
            if m:
                procs.setdefault(int(m.group(1), 16), m.group(2))
    addrs = sorted(procs)
    return addrs, [procs[a] for a in addrs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prof")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--unix", default=os.path.normpath(os.path.join(here, "..", "..", "unix.ecoff")),
                    help="IRIX's kernel: extract it from the system disk image with tools/misterdeploy/efsread.py IMAGE get /unix unix.ecoff")
    ap.add_argument("--top", type=int, default=40)
    a = ap.parse_args()
    kaddr, kname = kernel_procs(a.unix)

    def name(pc):
        for lo, hi in IDLE:
            if lo <= pc < hi:
                return "(idle)"
        if pc >= 0x80000000:
            i = bisect.bisect_right(kaddr, pc) - 1
            return kname[i] if i >= 0 else "?k"
        return "(user %03x00000)" % (pc >> 20)

    fn = collections.defaultdict(lambda: [0, 0])
    edges = collections.defaultdict(int)
    total = stalled = 0
    for line in open(a.prof):
        p = line.split()
        if p[0] == "caller":
            target, site, n = int(p[1], 16), int(p[2], 16), int(p[3])
            edges[(target, name(site - 4 if site >= 4 else site), site - 4)] += n
            continue
        pc, c, s = int(p[0], 16), int(p[1]), int(p[2])
        f = fn[name(pc)]
        f[0] += c
        f[1] += s
        total += c
        stalled += s
    print("%.1f M clocks, %.1f %% stalled" % (total / 1e6, 100.0 * stalled / max(total, 1)))
    for k, (c, s) in sorted(fn.items(), key=lambda kv: -kv[1][0])[:a.top]:
        print("  %5.2f %%  %-32s stalled %4.1f %%" % (100.0 * c / total, k[:32], 100.0 * s / max(c, 1)))
    if edges:
        print("\ncall sites (target <- caller function @ call instruction: entries)")
        for (t, f, site), n in sorted(edges.items(), key=lambda kv: -kv[1])[:a.top]:
            print("  %08x <- %-28s @ %08x : %d" % (t, f[:28], site, n))


if __name__ == "__main__":
    main()
