# SGI IP24 (Indy) Boot PROM — Full Disassembly & Analysis

Complete static analysis of two SGI IP24 boot PROMs, produced for MiSTer FPGA
core development.

| Image | Version string | Date | MD5 |
|---|---|---|---|
| `roms/IP24_Indy/ip24prom.070-9101-007.bin` | SGI Version **5.0 Rev B6** IP24 | Sep 28, 1994 | `1a9fe64104ed03e43d7e5e4c1e4e02f0` |
| `roms/IP24_Indy/ip24prom.070-9101-011.bin` | SGI Version **5.3 Rev B10** R4X00/R5000 IP24 | Feb 12, 1996 | `11bb4acd64fb7c79c985d3d09390668b` |

Both are 512 KiB, MIPS-III big-endian, mapped at physical `0x1fc00000`
(`0xbfc00000` uncached / `0x9fc00000` cached).

## Documents

- **[ANALYSIS.md](ANALYSIS.md)** — the write-up: image layout, boot flow, NVRAM
  format, embedded audio, Command Monitor, version diff.
- **[HARDWARE.md](HARDWARE.md)** — register-level hardware reference aimed at
  core implementation: what the PROM touches, in what order, and what it
  expects back.
- **[ip24-prom-teardown.html](ip24-prom-teardown.html)** — the same findings as a
  standalone illustrated report (open it in a browser; no assets, no network).

## Generated artefacts (`out/`)

| File | What it is |
|---|---|
| `ip24prom-011-5.3-B10.asm` | Full annotated disassembly, 5.3 Rev B10 (9.2 MB) |
| `ip24prom-007-5.0-B6.asm` | Full annotated disassembly, 5.0 Rev B6 (9.2 MB) |
| `functions-011.txt` / `-007.txt` | Function inventory: bounds, callers, hardware touched, strings used |
| `hardware-011.txt` / `-007.txt` | Every MMIO address the PROM forms, grouped by device |
| `strings-011.txt` / `-007.txt` | String table with the functions that reference each string |
| `symbols-011.json` / `-007.json` | Machine-readable symbol map |
| `named-symbols.txt` | The 147 hand-annotated symbols recovered from `prom.map` |
| `audio/`, `audio-007/` | The three embedded PROM tunes, decoded to WAV |
| `nvram-default-repaired.bin` | A default NVRAM image with a valid checksum |

## Tools (`tools/`)

All Python, dependency: `capstone`.

```
promlib.py        image + Ghidra .map loading, kseg0/kseg1/phys normalisation
disasm.py         recursive-descent disassembler + lui/addiu constant tracking
hwmap.py          IP22/IP24 physical address map and register database
emit.py           annotated listing emitter (CP0 names, cache ops, xrefs, strings)
strings.py        string extraction
run.py            build a listing:   run.py <image> <map|-> <out.asm>
report.py         build the reports: report.py <image> <map|-> <outdir> <tag>
tables.py         static (string -> handler) dispatch-table finder
extract_audio.py  IMA-ADPCM decoder for the embedded tunes
nvram.py          NVRAM checksum verify / repair
```

Rebuild everything:

```sh
python3 -m venv venv && ./venv/bin/pip install capstone
PY=./venv/bin/python
$PY tools/run.py    roms/IP24_Indy/ip24prom.070-9101-011.bin prom.map reference/prom/ip24prom-011-5.3-B10.asm
$PY tools/run.py    roms/IP24_Indy/ip24prom.070-9101-007.bin -        reference/prom/ip24prom-007-5.0-B6.asm
$PY tools/report.py roms/IP24_Indy/ip24prom.070-9101-011.bin prom.map out 011
$PY tools/report.py roms/IP24_Indy/ip24prom.070-9101-007.bin -        out 007
$PY tools/extract_audio.py roms/IP24_Indy/ip24prom.070-9101-011.bin out/audio 22050
$PY tools/nvram.py <path-to-nvram-image.bin>
```

## Sources of truth

Everything here is derived from the two binaries plus the `reference/prom/prom.map` Ghidra
export, which carries 147 hand-written symbol names (`realstart`, `szmem`,
`init_memconfig`, `cpu_get_eaddr`, …) that anchor the analysis. The Ghidra project archive `prom.gzf` (not copied into this repo) is a
Ghidra project archive for the **-011** image; the map matches it.

Claims below are labelled where they are inferred rather than read directly out
of the instruction stream.
