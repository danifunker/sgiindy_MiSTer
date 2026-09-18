import re, zlib, sys
path = sys.argv[1]
data = open(path,"rb").read()
objs = {}
for m in re.finditer(rb"(?<![0-9])(\d+)\s+0\s+obj\b", data):
    objs[int(m.group(1))] = m.end()
def objtext(n):
    s = objs[n]
    e = data.find(b"endobj", s)
    return data[s:e]
def stream(n):
    t = objtext(n)
    i = t.find(b"stream")
    if i < 0: return None
    j = i+6
    if t[j:j+2]==b"\r\n": j+=2
    elif t[j:j+1] in (b"\n",b"\r"): j+=1
    hdr = t[:i]
    m = re.search(rb"/Length\s+(\d+)(\s+0\s+R)?", hdr)
    if m.group(2):
        L = int(re.search(rb"(\d+)", objtext(int(m.group(1)))).group(1))
    else:
        L = int(m.group(1))
    raw = t[j:j+L]
    if b"FlateDecode" in hdr:
        return zlib.decompress(raw)
    return raw
# find root pages
root = None
for n in objs:
    t = objtext(n)
    if re.search(rb"/Type\s*/Pages", t) and b"/Parent" not in t:
        root = n
pages = []
def walk(n):
    t = objtext(n)
    if re.search(rb"/Type\s*/Pages", t):
        kids = re.search(rb"/Kids\s*\[([^\]]*)\]", t).group(1)
        for k in re.findall(rb"(\d+)\s+0\s+R", kids):
            walk(int(k))
    else:
        pages.append(n)
walk(root)
print("pages", len(pages), file=sys.stderr)
pno = int(sys.argv[2])
t = objtext(pages[pno-1])
print(t[:400].decode('latin1'), file=sys.stderr)
cont = re.search(rb"/Contents\s*(\[[^\]]*\]|\d+\s+0\s+R)", t).group(1)
out = b""
for k in re.findall(rb"(\d+)\s+0\s+R", cont):
    out += stream(int(k))
sys.stdout.buffer.write(out)
