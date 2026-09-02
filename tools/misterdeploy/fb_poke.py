#!/usr/bin/env python3
"""Write a test pattern into Newport's frame buffer from the ARM. RUNS ON THE DEVICE.

This exists to cut the display path in half. The frame buffer is in the DDR3 the
HPS shares with the FPGA, so the ARM can put a known picture there without the
guest, REX3 or the bus arbiter being involved at all. If the pattern appears on
screen, everything from the frame buffer to the pixels is working and a wrong
picture is the rasteriser's; if it does not, the fault is on the read side and
what REX3 wrote never mattered.

LAYOUT. The drawing planes are a 32-BIT SLOT PER PIXEL on a 2048-pixel stride,
two pixels to a 64-bit word with the even pixel in the low half (np_rex3.sv):
    slot = FB_BASE + (((y << 11) + x) << 2)
The colour index is the low byte of the slot. The core numbers its bytes
big-endian within the doubleword while the ARM reads it little-endian, so as
the ARM sees it **the index of pixel x is byte (y * 2048 + x) * 4** - the first
byte of each four-byte group, linear in x. The auxiliary planes are a second
region 8 MB above and are left alone here.

Usage (on the MiSTer):
    fb_poke.py bars      # 16 vertical bars stepping the index by 16
    fb_poke.py ramp      # index = x & 0xFF, a horizontal ramp
    fb_poke.py fill 0x40 # one index everywhere
    fb_poke.py sig       # a per-lane signature: byte j = 0xE0 + j

Every mode also ZEROES THE AUXILIARY REGION for the whole 2048-pixel stride.
The display's auxiliary line cache skips lines whose overlay and popup bits
are all zero, and a region left holding a previous build's bytes would keep
every line flagged until something overwrote it.
"""
import mmap, os, sys

FB, W, H, STRIDE, PAGE = 0x34000000, 1280, 1024, 2048, 4096
BPP = 4
AUX = FB + 0x00800000


def mapping(phys, length):
    base = phys & ~(PAGE - 1)
    span = ((phys - base + length + PAGE - 1) // PAGE) * PAGE
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        m = mmap.mmap(fd, span, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    finally:
        os.close(fd)
    return m, phys - base


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "bars"
    arg = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x40

    # one row of W pixels x BPP bytes, rebuilt per row only when it depends on y
    for y in range(H):
        row = bytearray(W * BPP)
        for x in range(W):
            if mode == "bars":
                v = (x * 16 // W) * 16
            elif mode == "ramp":
                v = x & 0xFF
            elif mode == "fill":
                v = arg & 0xFF
            elif mode == "sig":
                row[x * BPP:x * BPP + BPP] = bytes((0xE0 + j) & 0xFF for j in range(BPP))
                continue
            else:
                sys.exit("mode: bars | ramp | fill <n> | sig")
            row[x * BPP] = v
        m, off = mapping(FB + (y * STRIDE) * BPP, W * BPP)
        m[off:off + W * BPP] = bytes(row)
        m.close()
    # The auxiliary planes: the full stride, all zero, in one mapping.
    m, off = mapping(AUX, STRIDE * H * BPP)
    m[off:off + STRIDE * H * BPP] = bytes(STRIDE * H * BPP)
    m.close()
    print(f"wrote {mode} over {W}x{H}, auxiliary planes zeroed")


if __name__ == "__main__":
    main()
