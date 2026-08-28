# Measuring the fit

`sgiindy.sv` is still the stock MiSTer template and there is no SDRAM
controller, so **there is no core to build yet**. But the question this
directory answers does not need one:

> does the chipset and the R4300i fit on a DE10-Nano, and at what clock?

That needs the logic synthesised against the right device and nothing else.

## Run it

Quartus does not run on macOS, so this has to happen on a Linux or Windows
machine with Quartus 17.0 or later (the version the vendored CPU was written
against; newer is fine):

```sh
cd syn
quartus_sh --flow compile sgiindy_syn
```

Or, if only the resource number is wanted and not the placement, Analysis &
Synthesis alone is much faster and needs no pins:

```sh
quartus_map sgiindy_syn
```

## What to read

* `output_files/sgiindy_syn.fit.rpt` — ALMs, registers, block memory bits and
  DSPs. **Block memory is the one to watch**: both primary caches, the TLBs,
  the SCSI target's sector buffers and the FPU tables all want M10Ks, and the
  5CSEBA6U23I7 has 553 of them. `rtl/scsi/scsi.v`'s own header records that an
  earlier version of that core hit 553/553 and had to be redesigned to avoid
  it, so this is not a hypothetical.
* `output_files/sgiindy_syn.sta.rpt` — Fmax. The SDC deliberately asks for
  50 MHz, which the design is not expected to meet; the useful output is the
  worst path and the achievable Fmax, not a pass/fail.

**The comparison worth making:** the MiSTer N64 core runs this same R4300i at
93.75 MHz (`N64_MiSTer/rtl/pll.v`). That is the only real evidence available
about what this CPU closes at on this device, so an Fmax far below it points
at something in the SGI chipset rather than the CPU.

## What this is not

**A clean report here does not mean the core works.** Nothing in `syn/` is
wired to anything: `syn_top.sv` drives the core's inputs from an LFSR and
XORs its outputs into one pin, purely so Quartus cannot optimise the design
away and so the fitter has few enough pins to place. It will not boot, and it
is not a step towards booting - it is a measurement.

`mem_mb` is tied to a constant 48 in the harness, matching the single-SDRAM
target, because on hardware it is fixed by which SDRAM is fitted and tying it
lets `sgi_memmap`'s bank arithmetic fold away. Leaving it live would put
adders in the report that a real core would never build.

## Known unknowns

None of this has ever been through Quartus, so the first run may well fail to
compile rather than produce a number. The things most likely to break, in the
order they are worth checking:

* **SystemVerilog constructs Verilator accepts and Quartus does not.**
  `rtl/sgi/sgi_memmap.sv` already carries a note about block-scoped
  `automatic` declarations for exactly this reason.
* **The VHDL library assignments.** `cpu.vhd` instantiates its primitives as
  `entity mem.<name>`, and the `-library mem` lines in `files_core.qip` are
  what make that resolve. If they are wrong the CPU will not elaborate.
* **`rtl/scsi/scsi.v`'s vendored includes.** It expects `scsi_vendor.vh` on
  the search path; `files_core.qip` adds `../rtl/scsi` for that.
