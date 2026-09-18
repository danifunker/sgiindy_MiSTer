import re, zlib, sys
exec(open("rexaudit/pdfglyph2.py").read().split("for k,s in streams.items():")[0])
for k,s in streams.items():
    if b"immediate action" in s or b"Registers other than" in s or b"STALL0" in s or b"XYMOVE" in s:
        print("== stream", k)
        font=None
        for m in re.finditer(rb"/(R\d+)\s+[\d.]+\s+Tf|\((.*?)\)\s*(Tj|')", s, re.S):
            if m.group(1): font=m.group(1).decode(); continue
            t=m.group(2)
            if font in ('R17','R193') or (b"Type" in t) or b"Registers other" in t or b"Writes to" in t or b"0x00" in t or b"0x01" in t:
                print(font, t)
