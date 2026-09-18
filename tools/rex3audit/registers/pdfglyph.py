import re, zlib, sys
data = open(r"C:/Temp/mistercore/SGI_Indy_Core_DE1/SGI Indy Hardware Docs/rex3.pdf","rb").read()
print(data[:200])
# find objects
objs = {}
for m in re.finditer(rb"(\d+)\s+(\d+)\s+obj(.*?)endobj", data, re.S):
    objs[int(m.group(1))] = m.group(3)
print(len(objs), "objects")
# fonts
for k,v in objs.items():
    if b"/Type /Font" in v or b"/Type/Font" in v:
        print(k, v[:300])
