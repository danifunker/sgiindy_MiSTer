# Third-party code and licensing

This core is **GPL-3.0**, and it has to be: it vendors the MiSTer N64
project's R4300i CPU, which is GPL-3.0. A GPL-2.0-only work cannot include
GPL-3.0 code, so the licence was changed from the MiSTer template's GPL-2.0
when the CPU was brought in.

That is legitimate here because MiSTer's `sys/` framework is "version 2 of the
License, or (at your option) any later version" - some of it is already
GPL-3.0 - so the combined work can be distributed under GPL-3.0. Anyone
forking this and wanting GPL-2.0 has to replace the CPU.

| Component | Where | Origin | Licence |
|---|---|---|---|
| R4300i CPU | `rtl/cpu/r4300/` | [MiSTer-devel/N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) `rtl/`, commit `adbf9b5` | GPL-3.0 |
| MiSTer framework | `sys/` | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | GPL-2.0-or-later, parts GPL-3.0 |
| Z8530 SCC | `rtl/sgi/z8530_scc.sv` | written for this project's DE1 predecessor | GPL-3.0 |
| Altera primitive stand-ins | `rtl/cpu/prim/` | written for this project | GPL-3.0 |

`rtl/cpu/r4300/UPSTREAM.md` lists every local change to the vendored CPU, and
`tools/diff_upstream.sh` prints the delta so that list can be checked rather
than trusted.

## Boot PROM images

`roms/` holds SGI boot PROM dumps for IP12, IP20, IP22 and IP24. They are
**SGI-copyrighted firmware**, not covered by this repository's licence, and
they are here at the repository owner's decision rather than because anything
needs them to be: the core loads a PROM from the SD card at runtime, the way
every MiSTer core loads a BIOS, so deleting `roms/` breaks nothing in the RTL.

Anyone redistributing this repository should decide for themselves whether to
carry them.

## What is deliberately not here

- **The `cpu-tests` suite.** It lives in the IRIS project (BSD-3-Clause) and is
  used from there rather than forked; `tests/run-cputest.sh` points at a
  checkout. The R4300 support this core needs was contributed to that copy -
  see `docs/09-cpu-validation.md`.
- **Chip specifications, MAME sources and the full PROM disassembly**, kept
  locally under `reference/` and gitignored - 26 MB of derived and
  third-party material that the core does not need to build.
