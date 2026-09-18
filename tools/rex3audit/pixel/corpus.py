import re, collections, sys
src = open(r"C:/Temp/mistercore/iris/src/rex3_shaders.rs", encoding="utf-8").read()
rows = re.findall(r"/// dm0=0x([0-9a-f]+) dm1=0x([0-9a-f]+) cm=0x([0-9a-f]+)", src)
rows = [(int(a,16), int(b,16), int(c,16)) for a,b,c in rows]
print("rows", len(rows))
def f(v, hi, lo): return (v >> lo) & ((1 << (hi-lo+1)) - 1)
PL = {0:'none',1:'RGB/CI',2:'RGBA',3:'?3',4:'OLAY',5:'PUP',6:'CID',7:'?7'}
DD = {0:4,1:8,2:12,3:24}
OPC = {0:'NOOP',1:'READ',2:'DRAW',3:'S2S'}
AM = {0:'SPAN',1:'BLOCK',2:'ILINE',3:'FLINE',4:'ALINE'}
combos = collections.Counter()
feat = collections.Counter()
blend = collections.Counter()
lop = collections.Counter()
comp = collections.Counter()
for dm0, dm1, cm in rows:
    planes = f(dm1,2,0); dd = f(dm1,4,3); dbl = f(dm1,5,5); rgb = f(dm1,15,15)
    dith = f(dm1,16,16); fc = f(dm1,17,17); bl = f(dm1,18,18)
    sf = f(dm1,21,19); df = f(dm1,24,22); bb = f(dm1,25,25); ba = f(dm1,27,27)
    lo = f(dm1,31,28); cmp_ = f(dm1,14,12)
    op = f(dm0,1,0); am = f(dm0,4,2); ch = f(dm0,6,6); ah = f(dm0,7,7); shade=f(dm0,18,18); ciclamp=f(dm0,21,21)
    hd = f(dm1,9,8)
    combos[(OPC[op], PL[planes], DD[dd], 'RGB' if rgb else 'CI', 'dbl' if dbl else '-')] += 1
    if bl: blend[(OPC[op], PL[planes], DD[dd], 'RGB' if rgb else 'CI', 'sf',sf,'df',df,'bb',bb,'ba',ba, 'ch',ch,'ah',ah, 'dith',dith)] += 1
    if not bl and not fc: lop[(lo, OPC[op])] += 1
    comp[(cmp_, 'RGB' if rgb else 'CI', AM.get(am,am), OPC[op])] += 1
    if dith: feat[('dither', DD[dd], 'RGB' if rgb else 'CI')] += 1
    if fc: feat[('fastclear', PL[planes], DD[dd], 'RGB' if rgb else 'CI', 'lo', lo)] += 1
    if shade: feat[('shade', 'RGB' if rgb else 'CI', DD[dd], 'ciclamp', ciclamp)] += 1
    if ch or ah: feat[('host', 'ch',ch,'ah',ah, 'hd', hd, 'dd', DD[dd], 'RGB' if rgb else 'CI', OPC[op])] += 1
print("== (opcode, planes, depth, mode, dblsrc)")
for k,v in sorted(combos.items(), key=lambda x:-x[1]): print(v, k)
print("== blend shapes")
for k,v in sorted(blend.items(), key=lambda x:-x[1]): print(v, k)
print("== logic ops (non-blend, non-fastclear)")
for k,v in sorted(lop.items(), key=lambda x:-x[1]): print(v, k)
print("== compare")
for k,v in sorted(comp.items(), key=lambda x:-x[1]): print(v, k)
print("== features")
for k,v in sorted(feat.items(), key=lambda x:-x[1]): print(v, k)
