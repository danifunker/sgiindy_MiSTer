import sys, struct
def lines_at(d, off, maxw=64):
    runs=[]; i=off
    for _ in range(maxw):
        if i+2 > len(d): return None
        w = struct.unpack_from(">H", d, i)[0]; i += 2
        dur = (w>>8)&0x7f; eol = w>>15; absent = (w>>7)&1; sa = w & 0x7f
        sb = sc = None
        if not absent:
            if i+2 > len(d): return None
            w2 = struct.unpack_from(">H", d, i)[0]; i += 2
            if not (w2 & 0x80): return None       # bit 7 of SB/SC word must be 1
            if (w2>>15) != eol: return None
            sb = (w2>>8)&0x7f; sc = w2 & 0x7f
        if dur == 0: return None
        runs.append((dur, sa, sb, sc, eol))
        if eol: return runs, i
    return None
for path in sys.argv[1:]:
    d = open(path,"rb").read()
    hits = 0
    for off in range(0, len(d)-4, 2):
        r = lines_at(d, off)
        if r and len(r[0]) >= 4:
            tot = sum(x[0] for x in r[0])
            if tot == 841:
                hits += 1
                if hits < 40:
                    print(f"{path} off=0x{off:x} runs={len(r[0])} total={tot} durs={[x[0] for x in r[0]]}")
    print(path, "hits", hits)
