import struct, sys
from collections import Counter
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN
sys.path.insert(0, r"..")
md=Cs(CS_ARCH_MIPS, CS_MODE_MIPS32+CS_MODE_BIG_ENDIAN); md.skipdata=True
def text_ranges(path):
    data=open(path,"rb").read()
    if data[:4]==b"\x7fELF":
        from st64 import parse
        d,secs,syms=parse(path)
        return d,[(s["addr"],s["size"],s["off"]) for s in secs if (s["flags"]&4) and s["typ"]==1]
    f_magic,f_nscns,f_timdat,f_symptr,f_nsyms,f_opthdr,f_flags=struct.unpack(">HHiiiHH",data[:20])
    off=20+f_opthdr; out=[]
    for i in range(f_nscns):
        s=struct.unpack(">8siiiiiiHHi",data[off:off+40]); off+=40
        if s[0].rstrip(b"\0")==b".text": out.append((s[2]&0xffffffff,s[3],s[4]))
    return data,out
path=sys.argv[1]; target=int(sys.argv[2],0)
lo=int(sys.argv[3],0) if len(sys.argv)>3 else 0; hi=int(sys.argv[4],0) if len(sys.argv)>4 else 1<<32
data,rngs=text_ranges(path)
vals=Counter()
for va,size,ptr in rngs:
    regs={}
    for ins in md.disasm(data[ptr:ptr+size], va):
        if not (lo<=ins.address<hi): continue
        m=ins.mnemonic; ops=[t.strip() for t in ins.op_str.split(",")]
        try:
            if m=="lui": regs[ops[0]]=int(ops[1],0)<<16; continue
            if m=="ori" and ops[1] in regs: regs[ops[0]]=regs[ops[1]]|int(ops[2],0); continue
            if m=="ori" and ops[1]=="$zero": regs[ops[0]]=int(ops[2],0); continue
            if m=="addiu" and ops[1]=="$zero": regs[ops[0]]=int(ops[2],0)&0xffffffff; continue
            if m=="addiu" and ops[1] in regs: regs[ops[0]]=(regs[ops[1]]+int(ops[2],0))&0xffffffff; continue
        except ValueError: pass
        if m=="sw":
            disp=ops[1]; o=int(disp.split("(")[0] or "0",0)
            if (o & ~0x800)==target and ops[0] in regs:
                vals[regs[ops[0]]]+=1
        # invalidate written reg on other ops (crude)
        if ops and ops[0].startswith("$") and m not in ("sw","sb","sh","sd","sdc1","swc1","beq","bne","beql","bnel","bgez","bltz","blez","bgtz","j","jr","jal","jalr","b","nop"):
            regs.pop(ops[0],None)
for v,n in vals.most_common(40):
    print(f"{n:4d} {v:#010x}  width={v&3} pack={(v>>2)&1} crsinc={(v>>3)&1} crs={(v>>4)&7} addr={(v>>7)&15} sync={(v>>11)&1} async={(v>>12)&1} cswidth={(v>>13)&31} cshold={(v>>18)&31} cssetup={(v>>23)&31} swap={(v>>28)&1}")
