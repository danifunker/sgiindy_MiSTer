# tools/rex3audit - the instruments behind docs/56

Scratch analysis tools written for the REX3 source audit (docs/56,
2026-09-17), kept because they answer questions no simulator can: what the
guest's own software does to Newport. They are working scripts, not
polished tools - **every one has its input paths hard-coded near the top**
(the audit session's scratchpad), so point those at your own copies first.

## Inputs

Everything comes off an IRIX 5.3 disk image with
`tools/misterdeploy/efsread.py IMAGE get PATH OUT` (set `MSYS_NO_PATHCONV=1`
in Git Bash, or the `/usr/...` paths are mangled):

| file the scripts expect | from the image |
|---|---|
| `irisgl.so` | `/usr/gfx/arch/IP22NG1/libgl.so` (IRIS GL, unstripped ELF) |
| `libGLcore.so` | `/usr/gfx/arch/IP22NG1/libGLcore.so` (OpenGL, unstripped) |
| `opengl.so` | `/usr/gfx/arch/IP22NG1/libGL.so` |
| `libgd.so` | `/usr/gfx/arch/IP22NG1/libgd.so` |
| `Xsgi` | `/usr/gfx/arch/IP22NG1/Xsgi` (stripped) |
| `unix` | `/unix` (ECOFF with symbols; see `tools/misterdeploy/ecoffsyms.py`) |

(`libgl.so` and `libGL.so` collide on Windows' case-insensitive file system,
hence the renames.) The PROM is `releases/boot.rom`. The chip specifications
are SGI's own PDFs in `../SGI_Indy_Core_DE1/SGI Indy Hardware Docs/`; Git
Bash ships xpdf's `pdftotext` 4.00 - use `-layout` for prose and `-table`
for the register and format tables. Their text is not committed here.

All the MIPS work uses Python 3 with `capstone`.

## What is here

* `st64.py`, `rex64.py`, `disfn.py` - the first pass: count doubleword
  stores per function, find REX3 register-pair accesses by offset, and
  disassemble an ELF function by name (`--st64` for just the doubleword
  accesses, annotated with the REX3 register names).
* `census/` - the dataflow census of section 4.6: `mipsflow.py` (reaching
  definitions per function, stack slots tracked as registers) names the
  base of every load/store; `census.py`, `classify.py`, `values.py` and
  `table.py` turn that into per-binary register tables. `tables.md` and
  `matrix.md` are its output for the PROM, the kernel, Xsgi, IRIS GL and
  OpenGL.
* `registers/` - `pdfglyph*.py` recover Table 7's register-type symbols from
  the PDF's Symbol-font codes (the text extractions drop them);
  `basescan.py` counts stores through GL's own REX3 base pointer exactly.
* `walker/`, `pixel/` - corpus decoders for `iris/src/rex3_shaders.rs` and
  immediate/xref finders.
* `bus/` - `rexbase.py`, and `dcbscan.py`/`dcbmodes.py`, which decode every
  DCBMODE value a binary loads into (device, CRS, width).
* `display/` - `vtdecode.py` decodes a VC2 video timing table channel by
  channel (how the 1318- vs 1296-pixel window was found), `findframes.py`
  and `findvt.py` locate the tables in the PROM.
* `fb32ana.py` - analyses a `tools/misterdeploy/fbgrab32.py` dump of the
  Console filled by `tests/out/hw/textprobe.sh`: every text cell against its
  glyph, with the full 32-bit slots of any pixel that differs.
