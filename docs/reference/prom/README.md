# The IP24 (Indy) boot PROM — disassembly and analysis

Static analysis of two SGI IP24 boot PROMs, produced for the development of
this core.

| Image | Version string | Date | MD5 | In this repository |
|---|---|---|---|---|
| `ip24prom.070-9101-007.bin` | SGI Version **5.0 Rev B6** IP24 | Sep 28, 1994 | `1a9fe64104ed03e43d7e5e4c1e4e02f0` | no |
| `ip24prom.070-9101-011.bin` | SGI Version **5.3 Rev B10** R4X00/R5000 IP24 | Feb 12, 1996 | `11bb4acd64fb7c79c985d3d09390668b` | `roms/IP24_Indy/`, and as `releases/boot.rom` |

Both are 512 KiB, MIPS-III big-endian, mapped at physical `0x1fc00000`
(`0xbfc00000` uncached / `0x9fc00000` cached). The 5.3 image is the one this
core boots.

## Documents

- **[ANALYSIS.md](ANALYSIS.md)** — the write-up: image layout, boot flow, NVRAM
  format, embedded audio, Command Monitor, version diff.
- **[HARDWARE.md](HARDWARE.md)** — register-level hardware reference aimed at
  core implementation: what the PROM touches, in what order, and what it
  expects back.

What this core answers at each of those registers is in
[../address-map.md](../address-map.md); how the PROM gets into the machine is
in [../boot-prom.md](../boot-prom.md).

## Generated artefacts

The tools below write these; none of them is committed.

| File | Written by | What it is |
|---|---|---|
| `ip24prom-011-5.3-B10.asm`, `ip24prom-007-5.0-B6.asm` | `run.py` | Full annotated disassembly (9.2 MB each) |
| `functions-011.txt` / `-007.txt` | `report.py` | Function inventory: bounds, callers, hardware touched, strings used |
| `hardware-011.txt` / `-007.txt` | `report.py` | Every MMIO address the PROM forms, grouped by device |
| `strings-011.txt` / `-007.txt` | `report.py` | String table with the functions that reference each string |
| `symbols-011.json` / `-007.json` | `report.py` | Machine-readable symbol map |
| `tune0-22050Hz.wav` … `tune2-22050Hz.wav` | `extract_audio.py` | The three embedded PROM tunes, decoded at the rate given |

The original analysis also had `named-symbols.txt` (the 147 hand-annotated
symbols recovered from `prom.map`) and `nvram-default-repaired.bin` (a default
NVRAM image with a valid checksum; [ANALYSIS.md §4](ANALYSIS.md#4-nvram-and-rtc--fully-decoded)).
Neither is in this repository.

## Tools (`tools/prom/`)

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
win.py            the instructions around one address, in any of the three aliases
```

`hwmap.py` names some MC and INT2 registers from before the chip
specifications were read, and those names are shifted by a slot:
[HARDWARE.md](HARDWARE.md) and [../address-map.md](../address-map.md) have the
corrected tables.

Rebuild everything, from the repository root. `-` stands for "no symbol map";
give the path to `prom.map` in its place if you have it:

```sh
pip install capstone
ROM=roms/IP24_Indy/ip24prom.070-9101-011.bin
python tools/prom/report.py        $ROM - out 011        # creates out/
python tools/prom/run.py           $ROM - out/ip24prom-011-5.3-B10.asm
python tools/prom/extract_audio.py $ROM out/audio 22050
python tools/prom/tables.py        $ROM -
python tools/prom/nvram.py         <nvram-image.bin> [<repaired.bin>]
python tools/prom/win.py           0x9fc1f238
```

The 5.0 image, where you have it, takes the same commands with tag `007`.

## Sources of truth

Everything here is derived from the two binaries plus a Ghidra export of the
**-011** image's project, `prom.map`, which carries 147 hand-written symbol
names (`realstart`, `szmem`, `init_memconfig`, `cpu_get_eaddr`, …) that anchor
the analysis. The map and the Ghidra project archive it matches (`prom.gzf`)
are not in this repository. Without the map the tools still run: the
disassembler finds 1075 functions in the 5.3 image rather than 1102, and every
function is named by its address.

Claims in ANALYSIS.md and HARDWARE.md are labelled where they are inferred
rather than read directly out of the instruction stream.
