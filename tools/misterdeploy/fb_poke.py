#!/usr/bin/env python3
"""Write a test pattern into Newport's frame buffer from the ARM. RUNS ON THE DEVICE.

This exists to cut the display path in half. The frame buffer is in the DDR3 the
HPS shares with the FPGA, so the ARM can put a known picture there without the
guest, REX3 or the bus arbiter being involved at all. If the pattern appears on
screen, everything from the frame buffer to the pixels is working and a wrong
picture is the rasteriser's; if it does not, the fault is on the read side and
what REX3 wrote never mattered.

LAYOUT. newport.sv reads one 64-BIT WORD PER PIXEL:
    fbr_addr = FB_BASE + (((y << 11) + x) << 3)
so the stride is 2048 pixels and a pixel is eight bytes. The colour index is
`pix_word[7:0]`, and the core numbers its bytes big-endian within the
doubleword while the ARM reads it little-endian, so **the index is the FIRST
byte of each eight-byte group as the ARM sees it**.

Usage (on the MiSTer):
    fb_poke.py bars      # 16 vertical bars stepping the index by 16
    fb_poke.py ramp      # index = x & 0xFF, a horizontal ramp
    fb_poke.py fill 0x40 # one index everywhere
    fb_poke.py sig       # a per-lane signature: byte j = 0xE0 + j
"""
import mmap, os, sys

FB, W, H, STRIDE, PAGE = 0x34000000, 1280, 1024, 2048, 4096


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

    # one row of W pixels x 8 bytes, rebuilt per row only when it depends on y
    for y in range(H):
        row = bytearray(W * 8)
        for x in range(W):
            if mode == "bars":
                v = (x * 16 // W) * 16
            elif mode == "ramp":
                v = x & 0xFF
            elif mode == "fill":
                v = arg & 0xFF
            elif mode == "sig":
                row[x * 8:x * 8 + 8] = bytes((0xE0 + j) & 0xFF for j in range(8))
                continue
            else:
                sys.exit("mode: bars | ramp | fill <n> | sig")
            row[x * 8] = v
        m, off = mapping(FB + (y * STRIDE) * 8, W * 8)
        m[off:off + W * 8] = bytes(row)
        m.close()
    print(f"wrote {mode} over {W}x{H}")


if __name__ == "__main__":
    main()
