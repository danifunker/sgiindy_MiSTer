# Third-party code and licensing

This core is **GPL-3.0** (see `LICENSE`). It has to be: its CPU is GPL-3.0
code, so the combined work cannot be GPL-2.0-only. MiSTer's `sys/` framework is
"version 2 of the License, or (at your option) any later version" - some of it
is already GPL-3.0 - so the whole can be distributed under GPL-3.0.

## Code from elsewhere

| Component | Where | Origin | Licence |
|---|---|---|---|
| MIPS R4600 CPU | `rtl/cpu/r4300/` | [MiSTer-devel/Arcade-KillerInstinct_MiSTer](https://github.com/MiSTer-devel/Arcade-KillerInstinct_MiSTer) `rtl/cpu/`, commit `5c443bd`; itself a fork of [MiSTer-devel/N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer)'s R4300i | GPL-3.0 |
| MiSTer framework | `sys/` | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | GPL-2.0-or-later, parts GPL-3.0 |
| SCSI target | `rtl/scsi/scsi.v` | the MiSTer MacPlus core ([MiSTer-devel/MacPlus_MiSTer](https://github.com/MiSTer-devel/MacPlus_MiSTer), a port of MiST's Plus Too), by way of the MacLC core | no licence notice in the file or its upstream; distributed there as part of the MiSTer project |
| SCSI block cache | `rtl/scsi/scsi_cache.sv` | ported from the MacQuadra800 core, where it was written by this core's author | GPL-3.0 here |
| Z8530 SCC | `rtl/sgi/z8530_scc.sv` | written for this project's DE1-based predecessor | GPL-3.0 |
| Altera primitive stand-ins | `rtl/cpu/prim/` | written for this project, for simulation | GPL-3.0 |
| Simulator front end | `verilator/sim/` | the MiSTer Verilator simulation framework: Dear ImGui and ImPlot (MIT), ImGuiFileDialog (MIT), dirent (MIT), Verilator's runtime headers (LGPL-3.0 / Artistic-2.0) | as marked in each file |

`rtl/cpu/r4300/UPSTREAM.md` lists every local change to the vendored CPU, and
`tools/diff_upstream.sh` prints the difference so that list can be checked.

Parts of the test benches transcribe behaviour from **IRIS**, Dominik Behr's
SGI Indy emulator (BSD-3-Clause): `verilator/tb_rex3draw.cpp`'s reference
rasteriser follows IRIS's `rex3_generic.rs`, and `verilator/tb_mcdma.cpp`
follows its DMA loops. They are test code and are not part of the FPGA image.

## The boot PROM

`releases/boot.rom` and `roms/IP24_Indy/ip24prom.070-9101-011.bin` are the same
file: SGI's IP24 boot PROM, PROM Monitor 5.3 ("SGI Version 5.3 Rev B10
R4X00/R5000 IP24 Feb 12, 1996"). It is **SGI-copyrighted firmware**, not
covered by this repository's licence. The core does not contain it: it loads a
PROM from the SD card at runtime, the way MiSTer cores load a BIOS. The copy in
`roms/` is what the simulation tests boot.

Anyone redistributing this repository should decide for themselves whether to
carry it.

## What is deliberately not here

- **The `cpu-tests` suite.** It belongs to the IRIS project (BSD-3-Clause) and
  is used from a checkout of it rather than forked; `tests/run-cputest.sh`
  points at one. See `docs/reference/cpu-validation.md`.
- **Chip specifications, MAME sources and the full PROM disassembly** - kept by
  developers in a local, gitignored `reference/` folder. The core does not need
  them to build.
- **IRIX.** Disk and CD images are the user's to supply; see
  `docs/installing-irix.md`.
