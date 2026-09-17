#!/usr/bin/env python3
"""A statistical profiler over the DDR3 beacon. RUNS ON THE DEVICE.

WHY. "IRIX feels slow" has four very different causes on this core - the CPU
waiting on DDR3 for a cache fill, the CPU busy in the kernel or in a program,
the machine idle waiting on a timeout or the disk, and the rasteriser drawing
one pixel per DDR3 transaction - and a stopwatch cannot tell them apart. The
beacon already carries what can: word 10 is {the PC entering decode, cop0
debug bits}, and bits 17:13 of the low half are the pipeline's stall vector
(stall4 & stall3 & stall2 & stall1, cpu_cop0.vhd dbg_cop0). Sampled at a
steady rate, the PC says WHERE the time goes (idle loop, a kernel function, a
user text segment) and the stall bits say HOW (advancing, or held on a fetch
or on a data access). No fit is needed; the beacon refreshes every 1344
clocks (~37 kHz), far above any rate this can sample at.

Each record is <d Q Q Q Q Q>: seconds since the start, then beacon words 0
(heartbeat), 10 (PC/cop0), 13 (REX3 VDMA beat counters), 15 (display line
cache counters) and 40 (from ver 13: register 31 at retirement and the PC
last retired - a sample inside a leaf routine names its caller). A full
snapshot of every beacon word is written at the start and at the end, so the
disk-time counters (words 16-20) and the performance counters (21-34 from ver
10, 35 from ver 11) bracket the window too. SGIPROF3 is this record; SGIPROF2
captures (no word 40) still read.
tools/misterdeploy/profan.py reads the file on the host.

    prof.py --out /tmp/p.bin --secs 60                # one minute at ~1 kHz
    prof.py --out /tmp/p.bin --secs 300 --min 5 --until-idle 4
            # stop as soon as the machine has been >= 90 % idle for 4 s
            # (after at least 5 s): the end of a benchmark, found without
            # reading the screen

Idle means the PC is inside wait_for_interrupt or idle in the IRIX 5.3
kernel of SGIIndy53 (unix.ecoff; ecoffsyms.py) - a different kernel needs
different ranges (--idle).
"""
import argparse
import collections
import mmap
import os
import struct
import time

BASE = 0x35800000
NWORDS = 43          # the beacon since ver 14 (build 40); older fits leave the rest stale
IDLE_DEFAULT = "0x88012adc-0x88012b64,0x8802befc-0x8802bfa0"
HDR = b"SGIPROF3"    # followed by <I nwords>, then the snapshot


def parse_ranges(s):
    out = []
    for part in s.split(","):
        lo, hi = part.split("-")
        out.append((int(lo, 0), int(hi, 0)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--secs", type=float, default=30.0, help="maximum duration")
    ap.add_argument("--min", type=float, default=0.0,
                    help="never stop on idle before this many seconds")
    ap.add_argument("--hz", type=float, default=1000.0)
    ap.add_argument("--until-idle", type=float, default=0.0,
                    help="stop once the trailing N seconds are >= 90%% idle")
    ap.add_argument("--idle", default=IDLE_DEFAULT)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    idle = parse_ranges(a.idle)

    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
    finally:
        os.close(fd)

    def snap():
        return struct.unpack_from("<%dQ" % NWORDS, m, 0)

    rec = struct.Struct("<dQQQQQ")
    period = 1.0 / a.hz
    trail = collections.deque()
    trail_idle = 0
    n = n_idle = 0
    stop_reason = "time"
    with open(a.out, "wb") as f:
        f.write(HDR)
        f.write(struct.pack("<I", NWORDS))
        f.write(struct.pack("<d%dQ" % NWORDS, time.time(), *snap()))
        t0 = time.monotonic()
        nxt = t0
        t = 0.0
        while True:
            t = time.monotonic() - t0
            if t >= a.secs:
                break
            w0 = struct.unpack_from("<Q", m, 0)[0]
            w10 = struct.unpack_from("<Q", m, 80)[0]
            w13 = struct.unpack_from("<Q", m, 104)[0]
            w15 = struct.unpack_from("<Q", m, 120)[0]
            w40 = struct.unpack_from("<Q", m, 320)[0]
            f.write(rec.pack(t, w0, w10, w13, w15, w40))
            pc = w10 >> 32
            is_idle = 0
            for lo, hi in idle:
                if lo <= pc < hi:
                    is_idle = 1
                    break
            n += 1
            n_idle += is_idle
            if a.until_idle > 0:
                trail.append((t, is_idle))
                trail_idle += is_idle
                while trail and trail[0][0] < t - a.until_idle:
                    trail_idle -= trail.popleft()[1]
                if (t >= a.min and t >= a.until_idle and len(trail) > 10 and
                        trail_idle >= 0.9 * len(trail)):
                    stop_reason = "idle"
                    break
            nxt += period
            d = nxt - time.monotonic()
            if d > 0:
                time.sleep(d)
            else:
                nxt = time.monotonic()
        f.write(HDR)
        f.write(struct.pack("<I", NWORDS))
        f.write(struct.pack("<d%dQ" % NWORDS, time.time(), *snap()))
    if not a.quiet:
        print("prof: %d samples in %.1f s (%.0f Hz), %.1f %% idle, stopped on %s -> %s"
              % (n, t, n / t if t else 0, 100.0 * n_idle / max(n, 1),
                 stop_reason, a.out))


if __name__ == "__main__":
    main()
