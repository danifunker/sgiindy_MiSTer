"""dcbscan.py FILE... - find stores to REX3 DCBMODE (0x238/0xA38) and print the
constant stored when simple lui/ori/addiu tracking knows it; decode slave/CRS/width.
Works on ELF32 MSB (uses st64.parse) and on the ECOFF kernel (via .text section)."""
import sys, struct
from bisect import bisect_right
sys.path.insert(0, r"C:/Users/spam/AppData/Local/Temp/claude/C--Temp-mistercore-sgiindy-MiSTer--claude-worktrees-modest-robinson-cad59e/a11d8c0a-4bd4-4d6a-a12a-09061890f305/scratchpad")
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_BIG_ENDIAN

SLAVE = {0:"VC2",1:"CMAP01",2:"CMAP0",3:"CMAP1",4:"XMAP01",5:"XMAP0",6:"XMAP1",7:"RAMDAC",8:"CC1",9:"AB1",10:"?10",11:"?11",12:"PCD",15:"NULL"}

def decode(v):
    w = v & 3; inc = (v>>3)&1; crs=(v>>4)&7; a=(v>>7)&0xF
    return f"{SLAVE.get(a,a)} crs={crs} w={w or 4}{' inc' if inc else ''}{' swap' if v>>28&1 else ''} (cs w={(v>>13)&31} h={(v>>18)&31} s={(v>>23)&31})"

def texts(path):
    d = open(path,"rb").read()
    if d[:4] == b"\x7fELF":
        from st64 import parse
        d, secs, syms = parse(path)
        out=[]
        for s in secs:
            if s["flags"] & 4 and s["typ"] == 1:
                out.append((s["addr"], d[s["off"]:s["off"]+s["size"]]))
        return out, syms
    if path.endswith(".rom") or path.endswith(".bin"):
        return [(0xbfc00000, d)], []
    # ECOFF
    f_magic, f_nscns, f_timdat, f_symptr, f_nsyms, f_opthdr, f_flags = struct.unpack(">HHiiiHH", d[:20])
    off = 20 + f_opthdr; out=[]
    for i in range(f_nscns):
        nm, pa, va, sz, sp, rp, lp, nr, nl, fl = struct.unpack(">8siiiiiiHHi", d[off:off+40]); off += 40
        if nm.rstrip(b"\0") == b".text":
            out.append((va & 0xffffffff, d[sp:sp+sz]))
    return out, []

md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_BIG_ENDIAN); md.skipdata = True
for path in sys.argv[1:]:
    secs, syms = texts(path)
    addrs = [a for a,_ in syms]
    print("=====", path)
    for base, blob in secs:
        regs = {}
        for ins in md.disasm(blob, base):
            m = ins.mnemonic; ops = [o.strip() for o in ins.op_str.split(",")]
            try:
                if m == "lui": regs[ops[0]] = (int(ops[1],0) << 16) & 0xffffffff
                elif m in ("ori","addiu","addi") and len(ops)==3:
                    imm = int(ops[2],0)
                    src = 0 if ops[1] == "$zero" else regs.get(ops[1])
                    if src is None: regs.pop(ops[0], None)
                    else:
                        if m != "ori" and imm >= 0x8000: imm -= 0x10000
                        regs[ops[0]] = ((src | imm) if m=="ori" else (src+imm)) & 0xffffffff
                elif m in ("move","or","addu") and len(ops)>=2:
                    srcs = ops[1:]
                    vals = [0 if s=="$zero" else regs.get(s) for s in srcs]
                    if None in vals: regs.pop(ops[0], None)
                    else:
                        v = 0
                        for x in vals: v = (v | x) if m=="or" else (v + x)
                        regs[ops[0]] = v & 0xffffffff
                elif m == "sw":
                    disp = ops[1]; o = int(disp.split("(")[0],0) if disp.split("(")[0] else 0
                    if (o & 0x7ff) == 0x238:
                        v = 0 if ops[0]=="$zero" else regs.get(ops[0])
                        fn = ""
                        if addrs:
                            i = bisect_right(addrs, ins.address)-1
                            fn = syms[i][1] if i>=0 else ""
                        print(f"0x{ins.address:08x} {fn:28s} DCBMODE <- " + (f"0x{v:08x}  {decode(v)}" if v is not None else f"{ops[0]} (unknown)"))
                elif m in ("jal","jalr","j","jr","b","beq","bne","beqz","bnez","bltz","bgez","blez","bgtz"):
                    pass
                # any other write to a register invalidates it
                elif len(ops)>=1 and ops[0].startswith("$") and m not in ("sw","sh","sb","sd","sdc1","swc1","mtc0","mtc1","ctc1"):
                    regs.pop(ops[0], None)
                if m in ("jal","jalr"):
                    for r in list(regs):
                        if r not in ("$s0","$s1","$s2","$s3","$s4","$s5","$s6","$s7","$fp","$sp","$gp"): regs.pop(r,None)
            except ValueError:
                pass
