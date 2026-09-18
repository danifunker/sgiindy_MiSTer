import struct, sys
for path in sys.argv[1:]:
    d = open(path,"rb").read()
    # descriptor structs: {?, 0x20, W, H, Hz, MHz, frameptr(9fc7xxxx), nframe, 0, lineptr, nline, 0, p3, p4, ...}
    for off in range(0, len(d)-40, 2):
        a, b, W, H, hz, mhz = struct.unpack_from(">6H", d, off)
        fp, = struct.unpack_from(">I", d, off+12)
        if b == 0x20 and 200 <= W <= 2048 and 200 <= H <= 1280 and 20 <= hz <= 200 and (fp >> 20) in (0x9fc, 0xbfc):
            nf, z, = struct.unpack_from(">HH", d, off+16)
            lp, = struct.unpack_from(">I", d, off+20)
            nl, = struct.unpack_from(">H", d, off+24)
            print(f"{path} desc@0x{off:x}: a=0x{a:x} {W}x{H}@{hz}Hz clk={mhz} frame=0x{fp:08x}({nf}w) lines=0x{lp:08x}({nl}w)")
