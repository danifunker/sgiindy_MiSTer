# Porting plan

## Proposed repo layout

Following the convention already used in `~/repos/MacLC_MiSTer` and
`~/repos/lbmactwo_MiSTer`:

```
sgiindy_MiSTer/
  sgiindy.sv          top level (MiSTer `emu` interface)          [to write]
  files.qip           the Quartus manifest
  rtl/
    sgi/
      sgi_indy.sv       the core: CPU + decode + on-chip devices  ✅
      sgi_scc.sv        IOC-side wrapper for the SCC              ✅
      z8530_scc.sv      the SCC itself, from the sandbox          ✅
      sgi_mc.v          memory controller (from sandbox, finish DMA + RPSS)
      sgi_hpc3.sv       HPC3 peripheral controller (new)
      sgi_int2.sv       INT2 interrupt controller (new)
      sgi_ds1386.sv     RTC + NVRAM, stride-4 aliasing, SD-backed (new)
      sgi_hal2.sv       audio - stub first (REV bit 15 set)
      sgi_wd33c93.sv    SCSI - stub first
      sgi_seeq8003.sv   Ethernet - stub first
    cpu/
      r4300/            the vendored VHDL, plus UPSTREAM.md       ✅
      prim/             behavioural stand-ins for the Altera parts ✅
      r4300_wrap.vhd    flat ports + reset/boot-PC sequencing     ✅
      r4300_bus.sv      mem_* <-> SGI bus, and the byte-lane rules ✅
      generated/        GHDL's Verilog, for Verilator only (gitignored)
    newport/            REX3 / VC2 / XMAP9 - the big one, last
  sys/                MiSTer framework
  verilator/          headless harness                            ✅
  tests/              the two regressions                         ✅
  tools/              gen_r4300_verilog.sh, diff_upstream.sh      ✅
  docs/               these files
```

## Milestones

Each milestone is defined by an observable, not by "component X is written".

**Status: M0–M3 are done, M4 and M5 are partly done, M6 is one step away.**

`tests/run-cputest.sh` runs the 240-test suite on the core in about 35 seconds
and reports 2161 checks passed / 3 failed against full R4400 expectations,
versus 2101 / 61 for IRIS's own R4400. `tests/run-scc.sh` proves the Z8530
transmits, checked against a UART decode of its own output pin.
`tests/run-prom.sh` boots the real IP24 PROM, which now runs its power-on
diagnostics, prints them over serial, takes a keystroke back and reaches the
**System Maintenance Menu**. See [12-chipset.md](12-chipset.md).

### M0 — infrastructure ✅
Portable Verilator harness (no DX11), ELF loader into the RAM model, PROM
loadable from a file, bus trace with `decode_reg_name`, PC-stuck detector, SCC
console tap. **Set up the IRIS golden-log diff** — this is the piece the
sandbox never had, and IRIS is a better oracle than MAME on every axis
(see [09-cpu-validation.md](09-cpu-validation.md)).

### M1 — CPU passes the IRIS test suite ✅
Load `~/repos/iris/cpu-tests/build/cputest.elf` straight into the RAM model at
KSEG0 `0x88200000` and run it, with `z8530_scc.sv` at `0x1FBD9830`/`0x34`
piping console output to stdout. No PROM, no MC, no chipset.

Success: `IRIS-CPUTEST-DONE` appears, and the per-test results match IRIS's own
run of the same binary except for the enumerated R4300-vs-R4400 divergences.
See [09-cpu-validation.md](09-cpu-validation.md). Add the `CPU_R4300` cell to
the suite harness as part of this milestone.

This is the CPU milestone; endianness needs no separate investigation, since
the R4300i is natively big-endian (`Config.bigEndian = 1` at reset) — just do
not carry `data_flipped` forward.

### M2 — MC good enough to survive `realstart` ✅
`SYSID`, `CPUCTRL0/1` readback, and a genuinely free-running `RPSS_CTR`.
Success: the PROM gets past `DELAY`/`calibrate_delay` without hanging.

Done, and it took more than the MC: `calibrate_delay` also needs the 8254 in
IOC2, and `realstart`'s HPC3 walking-bit tests come first.

### M3 — console output ✅
SCC on a real MiSTer UART (or the framework's virtual serial). Success: **the
PROM's first banner line appears**, and matches the corresponding line in the
real serial capture.

Done, in simulation. Two caveats:

- The blocking bug was not the SCC's serialiser but a missing register path:
  the PROM prints through **WR8 on the command port**, and the model only
  pushed the TX FIFO on data-port writes. See `rtl/sgi/z8530_scc.sv`.
- **There is no IP24 serial capture in `roms/`** — only an IP22 one — so the
  output has not been diffed against real hardware. That is a good thing to ask
  the user for: a serial capture of a real Indy booting this PROM revision
  would be a golden reference for everything from here on.

### M4 — memory sizing — partly done
`MEMCFG0/1` describing a real bank at phys `0x08000000`, plus the GIO DMA engine
completing the VDMA memory clear. Success: no `DMA_RUN`/`DMA_CAUSE` dump; the
PROM prints the correct memory size.

`rtl/sgi/sgi_memmap.sv` makes the decode follow MEMCFG and POST's memory tests
pass — no bank failures, no "No usable memory found". **The GIO DMA engine is
still a stub**: its registers behave and a start reports instant completion, but
nothing is copied, so the boot memory clear does not clear anything. The PROM
does not print the DMA failure dump, which means it believes the clear worked.

### M5 — NVRAM — partly done
Full DS1386 stride-4 aliasing, 256-byte checksummed window, `(nvram[1]&0x3f)==8`
tag, backed by a file on the SD card so settings persist. Success: `printenv`
works and `setenv` survives a reset.

`rtl/sgi/sgi_ds1386.sv` is the whole part with a BCD calendar, and the PROM's
RTC path test passes. **It is volatile**, so the PROM prints "NVRAM checksum is
incorrect: reinitializing" and rebuilds the environment on every boot. Nothing
is seeded and nothing persists.

### M6 — **Command Monitor prompt** — in progress
INT2 readable, SCSI/Ethernet reporting absent-but-graceful, HAL2 returning
REV bit 15. Success: an interactive `>>` prompt over serial, `hinv` and `help`
respond. **This is the "it boots" milestone**, and it is reachable with zero
graphics work.

INT2 is readable, SCSI and Ethernet report absent and the PROM continues, HAL2
returns REV bit 15, and the boot reaches:

```
System Maintenance Menu

1) Start System
2) Install System Software
3) Run Diagnostics
4) Recover System
5) Enter Command Monitor

Option?
```

Serial **input** works too — the harness types a real UART frame into `rxdb`
and the PROM acts on it. Option 5 is the last step.

### M7 — graphics
Newport: REX3 rasteriser at `0x1F0F0000` (`XSTART` `+0x100`, `XSTARTI` `+0x148`,
`CONFIG` `+0x1330`), VC2, XMAP9. Specs are all in
`SGI Indy Hardware Docs/`. Success: the PROM's GR2 self-tests pass and the
boot logo / console renders on HDMI.

### M8 — mass storage and IRIX
WD33C93B + HPC3 SCSI DMA against a disk image on SD, interrupts wired
(INT2 → MIPS `Cause`), caches enabled. Success: IRIX boots.

M7 and M8 are each larger than M0–M6 combined.

## Deliberate scope decisions to make up front

- **Serial-first.** Everything through M6 is achievable with no video model at
  all. Resist building graphics early.
- **Interrupts can wait.** The PROM reaches the Command Monitor with INT2 as a
  register file and no CPU interrupt wiring. IRIX cannot.
- **Caches can wait.** Both candidate CPUs can run with caches off, at a speed
  cost that doesn't matter in bring-up.
- **PROM images are user-supplied.** They are SGI-copyrighted firmware; load
  them from the SD card the way every MiSTer core loads a BIOS. Do not commit
  them here.
- **Vendor VHDL, not netlists.** If the R4300i route is taken, add
  `R4300_VHDL/*.vhd` to the QSF; Quartus compiles VHDL. Keep the
  GHDL/Yosys flatten only as a Verilator input, regenerated by script.

## Resource sanity check (DE10-Nano, Cyclone V 5CSEBA6: ~41 910 ALMs)

- aoR3000: ~7 660 LE on Cyclone IV ⇒ comfortably small.
- N64 R4300i with FPU and caches: substantial; the MiSTer N64 core fits a
  DE10-Nano but leaves little room. With caches tied off it's smaller, but the
  FPU (`cpu_FPU.vhd`, 72 KB of VHDL) is the bulk.
- Newport/REX3 is unknown until designed; budget for it from the start if the
  Indy is the target.

If the R4300i + Newport combination turns out not to fit, the Indigo/aoR3000
path becomes the pragmatic answer rather than just the easier first step.

## First three concrete tasks

1. Copy `z8530_scc.sv`, `sgi_mc.v`, and `sgi_hd_enet.v` into `rtl/`, unchanged,
   and get them compiling standalone under Verilator on macOS.
2. Copy `indy-prom/` (docs, tools, `out/hardware-011.txt`,
   `out/named-symbols.txt`, `nvram-default-repaired.bin`) into this repo — but
   **not** the PROM binaries. It's the reference the whole effort leans on.
3. Write the portable Verilator harness shell with the `decode_reg_name` table
   and the bus trace, driving nothing but a ROM and a RAM model, then hang the
   CPU off it.
