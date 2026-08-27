import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from promlib import Image, load_map
from disasm import Dis
from emit import Emitter

img_path, map_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
img = Image(img_path)
syms = load_map(map_path) if map_path != '-' else {}
d = Dis(img, syms); d.run(scan_prologues=True)
e = Emitter(img, syms, d)
with open(out_path, 'w') as fh:
    fh.write('; ' + '=' * 76 + '\n')
    fh.write('; SGI IP24 (Indy) boot PROM - full annotated disassembly\n')
    fh.write('; image : %s (%d bytes)\n' % (os.path.basename(img_path), img.size))
    fh.write('; base  : 0x%08x (kseg1) / 0x%08x (kseg0) / 0x%08x (physical)\n'
             % (img.base, img.base - 0x20000000, img.base & 0x1fffffff))
    fh.write('; arch  : MIPS-III, big-endian (R4000/R4400/R4600/R5000)\n')
    fh.write('; stats : %d code words, %d functions, %d strings\n'
             % (len(d.code), len(d.func), len(e.strs)))
    fh.write('; ' + '=' * 76 + '\n')
    e.emit(fh)
print('%s: %d code words, %d funcs, %d strings' % (os.path.basename(img_path), len(d.code), len(d.func), len(e.strs)))
