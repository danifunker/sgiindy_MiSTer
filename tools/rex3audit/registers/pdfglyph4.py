import re, zlib, sys
exec(open("rexaudit/pdfglyph2.py").read().split("for k,s in streams.items():")[0])
for k in (163,173):
    s = streams[k]
    print("== stream", k)
    font=None
    for m in re.finditer(rb"/(R\d+)\s+[\d.]+\s+Tf|\((.*?)\)\s*(Tj|')", s, re.S):
        if m.group(1): font=m.group(1).decode(); continue
        t=m.group(2)
        print(font, t)
