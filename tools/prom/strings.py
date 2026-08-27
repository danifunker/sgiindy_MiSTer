import sys, os, re
sys.path.insert(0, os.path.dirname(__file__))
from promlib import Image, BASE

def extract(img, minlen=4):
    """Yield (addr, bytes) for NUL-terminated printable runs."""
    d, out, i, n = img.data, [], 0, img.size
    while i < n:
        if 32 <= d[i] < 127 or d[i] in (9,10,13):
            j = i
            while j < n and (32 <= d[j] < 127 or d[j] in (9,10,13)): j += 1
            if j < n and d[j] == 0 and j - i >= minlen:
                out.append((img.base + i, d[i:j]))
                i = j + 1; continue
            i = j if j > i else i+1
        else:
            i += 1
    return out
