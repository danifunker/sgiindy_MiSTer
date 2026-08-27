"""SGI IP24 NVRAM (Dallas DS1386-8K) decode / checksum / repair.

Device layout as used by the PROM
---------------------------------
  phys 0x1fbe0000, byte-wide device on a 32-bit bus: device byte N lives in
  the low 8 bits of the word at 0x1fbe0000 + N*4.
  Device bytes 0x00-0x3f : DS1386 RTC + control register file.
  Device byte  0x40      : the PROM's "NVRAM offset 0". All PROM NVRAM
                           offsets in this file are relative to that.

Validity (cpu_is_nvvalid, FUN_bfc116e8)
---------------------------------------
  nvram[0] must equal checksum(), and (nvram[1] & 0x3f) must equal 8.

Checksum (FUN_bfc11050) - covers PROM offsets 0x00..0xff, skipping offset 0:
  s = (int8) 0xa5
  for i in 0..255:
      if i: s = (int8)(s ^ nvram[i])
      if i & 1: s = (int8)((s << 1) | (s < 0))     # rotate left through sign
  return s & 0xff
"""
import sys, os

NVRAM_BASE_IN_DEVICE = 0x40      # PROM offset 0 == device byte 0x40
CKSUM_LEN = 0x100

def _s8(x): return ((x & 0xff) ^ 0x80) - 0x80

def checksum(nv):
    """nv: 256 bytes starting at PROM offset 0."""
    s = _s8(0xa5)
    for i in range(CKSUM_LEN):
        if i: s = _s8(s ^ nv[i])
        if i & 1: s = _s8((s << 1) | (1 if s < 0 else 0))
    return s & 0xff

def is_valid(dev):
    """dev: the full device image (>= 0x140 bytes)."""
    nv = dev[NVRAM_BASE_IN_DEVICE:NVRAM_BASE_IN_DEVICE + CKSUM_LEN]
    return nv[0] == checksum(nv), nv[0], checksum(nv), nv[1] & 0x3f

def repair(dev):
    """Return a copy with the checksum byte and the 0x08 tag corrected."""
    out = bytearray(dev)
    b = NVRAM_BASE_IN_DEVICE
    out[b + 1] = (out[b + 1] & ~0x3f) | 0x08
    nv = bytearray(out[b:b + CKSUM_LEN]); nv[0] = 0
    out[b] = checksum(nv)
    return bytes(out)

if __name__ == '__main__':
    path = sys.argv[1]
    dev = open(path, 'rb').read()
    ok, stored, computed, tag = is_valid(dev)
    print('file            : %s (%d bytes)' % (path, len(dev)))
    print('stored  nvram[0]: 0x%02x' % stored)
    print('computed        : 0x%02x' % computed)
    print('tag nvram[1]&3f : %d  (%s)' % (tag, 'ok' if tag == 8 else 'INVALID, must be 8'))
    print('verdict         : %s' % ('VALID' if ok and tag == 8 else
                                    'INVALID - the PROM would reinitialise this NVRAM'))
    if len(sys.argv) > 2:
        open(sys.argv[2], 'wb').write(repair(dev))
        print('repaired copy   : %s' % sys.argv[2])
