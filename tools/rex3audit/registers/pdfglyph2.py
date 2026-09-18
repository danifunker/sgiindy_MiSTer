import re, zlib, sys
data = open(r"C:/Temp/mistercore/SGI_Indy_Core_DE1/SGI Indy Hardware Docs/rex3.pdf","rb").read()
objs = {}
for m in re.finditer(rb"(\d+)\s+(\d+)\s+obj(.*?)endobj", data, re.S):
    objs[int(m.group(1))] = m.group(3)
def length_of(d):
    m = re.search(rb"/Length\s+(\d+)(\s+0\s+R)?", d)
    if not m: return None
    if m.group(2):
        return int(re.search(rb"(\d+)", objs[int(m.group(1))]).group(1))
    return int(m.group(1))
streams = {}
for k,v in objs.items():
    i = v.find(b"stream")
    if i < 0: continue
    j = i + 6
    if v[j:j+2] == b"\r\n": j += 2
    elif v[j:j+1] in (b"\n", b"\r"): j += 1
    L = length_of(v[:i])
    raw = v[j:j+L] if L else v[j:]
    try:
        streams[k] = zlib.decompress(raw)
    except Exception as e:
        pass
for k,s in streams.items():
    if b"DCBRESET" in s or b"DCBMODE" in s or b"USER_STATUS" in s:
        print("stream", k, len(s))
        open("rexaudit/stream_%d.txt"%k,"wb").write(s)
