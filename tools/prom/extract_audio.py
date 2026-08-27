"""Decode the three IMA-ADPCM sound blobs embedded in the IP24 PROM.

Located by the (buffer, length) selector at 0xbfc03154/0xbfc0316c/0xbfc03184;
decoded by the routine at 0xbfc032cc, which is relocated to RAM before use and
carries the canonical 89-entry IMA step table (0xbfc55954) and 16-entry index
table (0xbfc55914).
"""
import sys, os, struct, wave
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from promlib import Image

STEP = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,
        73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,
        408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,
        1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,
        7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,
        22385,24623,27086,29794,32767]
IDX = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]

def ima_decode(data):
    pred, index, out = 0, 0, bytearray()
    for byte in data:
        for nib in (byte >> 4, byte & 0x0f):      # high nibble first
            step = STEP[index]
            diff = step >> 3
            if nib & 4: diff += step
            if nib & 2: diff += step >> 1
            if nib & 1: diff += step >> 2
            pred = pred - diff if nib & 8 else pred + diff
            pred = max(-32768, min(32767, pred))
            index = max(0, min(88, index + IDX[nib]))
            out += struct.pack('<h', pred)
    return bytes(out)

# (name, offset, length) taken from the three-way selector that feeds the
# decoder. The blobs are byte-identical between the two PROM revisions; only
# their offsets moved. Keyed by image size + first blob offset probe.
BLOBS_011 = [('tune0', 0x55ac0, 0xb3fb), ('tune1', 0x60ec0, 0x916e), ('tune2', 0x6a034, 0x3afc)]
BLOBS_007 = [('tune0', 0x56790, 0xb3fb), ('tune1', 0x61b90, 0x916e), ('tune2', 0x6ad04, 0x3afc)]

def blobs_for(img):
    import struct
    # the length word sits immediately after each blob; use it to pick the set
    for table in (BLOBS_011, BLOBS_007):
        off, ln = table[0][1], table[0][2]
        end = (off + ln + 3) & ~3
        if end + 4 <= img.size and struct.unpack('>I', img.data[end:end+4])[0] == ln:
            return table
    raise SystemExit('could not locate the ADPCM blob table in this image')

if __name__ == '__main__':
    img = Image(sys.argv[1]); outdir = sys.argv[2]; rate = int(sys.argv[3])
    os.makedirs(outdir, exist_ok=True)
    for name, off, ln in blobs_for(img):
        pcm = ima_decode(img.data[off:off+ln])
        p = os.path.join(outdir, '%s-%dHz.wav' % (name, rate))
        w = wave.open(p, 'wb'); w.setnchannels(1); w.setsampwidth(2)
        w.setframerate(rate); w.writeframes(pcm); w.close()
        print('%-8s prom 0x%05x  %6d bytes -> %6d samples  %5.2f s @ %d Hz  %s'
              % (name, off, ln, len(pcm)//2, (len(pcm)//2)/rate, rate, p))
