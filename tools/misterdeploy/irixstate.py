#!/usr/bin/env python3
"""Where is the IRIX boot? RUNS ON THE DEVICE. One line per call.

WHY. scripts/bootrate.sh classifies the PROM's diskless boot out of the frame
buffer (a dialog panel, or a PROM exception box). An IRIX boot ends
differently: the kernel either panics - "PANIC: init died (why = 2, what =
0xb)" on build 24, about one boot in three, docs/47 - or hands the screen to
X. Neither is a PROM panel, and a photograph cannot be counted, so this reads
the two things that separate them exactly:

  * the kernel's own `panicstr` (unix.ecoff: 0x881bd184; see ecoffsyms.py).
    It is NULL until panic() runs and then points at the message, so its
    value IS the verdict and the message's first line is the reason. Memory
    must be zeroed before the launch (memclear.py) or the previous boot's
    pointer is still there while the PROM runs.
  * the frame buffer's index histogram, sampled like classify.py (every 4th
    row): the IRIX boot screen is a gradient with a console panel whose
    background is index 9 (~37 % of the screen, 169 indices, calibrated on
    tests/out/hw/b22-boot1.raw); the X login screen is index 16 at ~61 %
    (23 indices, b22-login.raw) and the desktop index 16 at ~47 % (46
    indices, b22-desk.raw). Index 0xE7 is what fb_poke.py leaves - a screen
    still full of it never drew.

Verdicts, first word of the line:
  PANIC      panicstr set (the message follows)
  X-UP       X owns the screen (login screen or desktop), no panic
  BOOTING    the boot panel is up, no panic (yet)
  NEVER-DREW the fb_poke marker is still on screen
  UNKNOWN    none of the above

    python3 irixstate.py            one line
"""
import importlib.util
import struct
from collections import Counter

spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

RAM_ARM = 0x30000000          # SGI physical 0x08000000 (guestmem.py)
PANICSTR = 0x881bd184         # unix.ecoff `panicstr`, KSEG0
W, H, S, FB = 1280, 1024, 2048, 0x34000000


def guest_read(addr, length):
    """Bytes at a KSEG0/KSEG1 address in the guest's order (guestmem.py)."""
    phys = addr & 0x1FFFFFFF
    arm = RAM_ARM + (phys - 0x08000000)
    lo, hi = arm & ~7, (arm + length + 7) & ~7
    raw = m.read_phys(lo, hi - lo)
    out = bytearray()
    for i in range(0, len(raw), 8):
        out += raw[i:i + 8][::-1]
    off = arm - lo
    return bytes(out[off:off + length])


def guest_str(addr, limit=96):
    s = guest_read(addr, limit)
    s = s.split(b"\0", 1)[0].decode("latin-1")
    # the message starts "\n<0>PANIC: ..." - keep its first real line
    for line in s.replace("\r", "").split("\n"):
        line = line.strip()
        if line:
            return line[:limit]
    return ""


def fb_sample():
    c = Counter()
    for y in range(0, H, 4):
        c.update(m.read_phys(FB + (y * S) * 8, W * 8)[0::8])
    return c


def main():
    ps = struct.unpack(">I", guest_read(PANICSTR, 4))[0]
    c = fb_sample(); t = float(sum(c.values()))
    pct = lambda i: 100.0 * c.get(i, 0) / t
    panel, x16, mark, n = pct(9), pct(16), pct(0xE7), len(c)
    if ps and 0x88000000 <= ps < 0x8C000000:
        v, why = "PANIC", guest_str(ps)
    elif mark > 50:
        v, why = "NEVER-DREW", ""
    elif x16 > 30 and panel < 5:
        v, why = "X-UP", ""
    elif panel > 8:
        v, why = "BOOTING", ""
    else:
        v, why = "UNKNOWN", ""
    print("%-10s panicstr=0x%08x panel9 %4.1f%% idx16 %4.1f%% indices %3d marker %4.1f%% %s"
          % (v, ps, panel, x16, n, mark, why))


main()
