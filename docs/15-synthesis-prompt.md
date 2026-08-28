# Work item: get `syn/` through Quartus and read the numbers

Paste everything below the line as the opening message of a fresh session, on a
machine that can run Quartus. This is a **separate work item** from
`docs/08-resume-prompt.md`, and it is deliberately narrow.

---

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA. The repo is
`sgiindy_MiSTer`, branch `main`. **Your job is one thing:** make
`syn/sgiindy_syn` compile in Quartus and report how big the design is and what
clock it closes at. Nothing else.

## The goal, precisely

```sh
cd syn
quartus_sh --flow compile sgiindy_syn      # full: synthesis, fit, timing
quartus_map sgiindy_syn                    # synthesis only - faster, no pins
```

and then two numbers out of `syn/output_files/`:

* **`sgiindy_syn.fit.rpt`** — ALMs, registers, **block memory bits and M10K
  count**, DSPs. Block memory is the one that matters: both primary caches,
  two TLBs, the FPU tables and seven SCSI targets' sector buffers all want
  M10Ks, and a 5CSEBA6U23I7 has 553. `rtl/scsi/scsi.v`'s own header records an
  earlier version of that core hitting **553/553** and needing a redesign, so
  this is not hypothetical.
* **`sgiindy_syn.sta.rpt`** — Fmax and the worst path. The SDC asks for 50 MHz
  on purpose; the design is not expected to meet it. The useful output is the
  achievable Fmax, not pass/fail.

**The comparison worth making:** the MiSTer N64 core runs this same R4300i at
93.75 MHz. That is the only real evidence about what this CPU closes at on this
device, so an Fmax far below it points at the SGI chipset rather than the CPU.

## Read this before you touch anything

`syn/README.md`, and then believe it: **`syn/` is not the MiSTer core.** There
is no SDRAM controller in this repo, `sgiindy.sv` is still the stock MiSTer
template and instantiates nothing, and `syn_top.sv` drives `sgi_indy`'s inputs
from an LFSR and XORs its outputs into one pin purely so Quartus cannot
optimise the design away and the fitter has five pins instead of thirty-nine.
It will not boot. **A clean fit report does not mean the core works**, and
saying otherwise in a commit message would be the worst outcome of this task.

## Where this got to

Quartus 17.0.2 Lite has been run once. Analysis & Synthesis failed with 68
errors in three groups, **all now fixed and pushed** — the run that produced
them is the one described below, so the next run should get further, not
identically far.

| Fixed | What it was |
|---|---|
| `syn/sgiindy_syn.qpf` | had only `PROJECT_REVISION`; Quartus will not open a project without `QUARTUS_VERSION` |
| `syn/sgiindy_syn.qsf` | contained `SYSTEMVERILOG_INPUT_VERSION`, which is not a Quartus assignment at all |
| `syn/sgiindy_syn.qsf` | was **missing** `VHDL_INPUT_VERSION VHDL_2008`, without which no CPU entity elaborates |
| `rtl/sgi/sgi_memmap.sv` | inline `for (genvar b = 0; ...)` instead of explicit `generate`/`endgenerate` |
| `rtl/sgi/sgi_hpc3.sv`, `rtl/sgi/sgi_ioc.sv` | bit-selecting a function call result |

### Two of those are worth understanding, not just knowing

**The CPU requires VHDL-2008.** Its constants are sized bit-string literals —
`6x"00"` in `cpu_FPU.vhd`, `X"1FF"` in `cpu_instrcache.vhd` — which is 2008
syntax with no VHDL-1993 equivalent. Without the setting you get sixty-odd
`VHDL syntax error ... near text X"00"` and every CPU file reports *"Found 0
design units"*.

That setting was removed once, on the reasoning that
`tools/gen_r4300_verilog.sh` needs GHDL `-frelaxed` because VHDL-2008 makes
non-protected shared variables an error. **That reasoning is backwards** —
`-frelaxed` is what lets those sources be compiled *as* 2008. If a future
session sees the `-frelaxed` note and reaches for `VHDL_1993`, it will
reproduce sixty-eight errors exactly.

**Quartus will not bit-select a function call.** `hpc3_rd(w[0])[24-8*b +: 8]`
is a syntax error there, reported unhelpfully as `near text "["; expecting
";"`. Verilator accepts it. The fix is a variable in between.

## The recurring theme, and the rule that follows from it

**Every RTL failure so far has been a construct Verilator accepts and Quartus
does not.** Expect more of them, and expect the error message to point
somewhere other than the cause — the inline `genvar` was reported as
*"expecting endmodule"* followed by a cascade of `identifier "half" is already
declared`, none of which mentions `genvar`.

A scan for the two known patterns across all of `rtl/` currently comes back
clean, so whatever surfaces next will be a new pattern rather than a missed
instance of an old one.

**THE RULE: fix the syntax, never the behaviour.** These are portability
fixes. If satisfying Quartus seems to require changing what the RTL *does* —
resizing a memory, dropping a target, weakening a reset — stop and say so
rather than doing it quietly. The simulator is the specification here, and:

```sh
make -C verilator cputest          # must keep building
tests/run-scsi.sh                  # and this must keep passing
```

is the check that a portability fix stayed one. Run it before every commit
that touches `rtl/`.

## If the CPU's VHDL becomes the obstacle

The fallback exists and is already understood: `tools/gen_r4300_verilog.sh`
lowers the same VHDL to Verilog with GHDL's synthesis backend, which is how
Verilator sees the CPU. Feeding Quartus that output instead of the VHDL is a
last resort, **not** a first move — it puts a generated netlist in the build,
which `docs/08-resume-prompt.md` is explicit about never checking in. Try it
only if mixed-language compilation itself proves to be the wall, and say
clearly in the commit that it is a workaround.

## What the numbers might tell you, and the cheapest lever

If block memory is the binding constraint, the first thing to look at is
`NUM_TARGETS` in `rtl/scsi/sgi_scsi.sv`. It is **7** — every SCSI ID gets a
full target with its own sector buffers — because that was free in simulation.
It is not free on silicon, and nothing in use needs more than two or three: a
disk on ID 1 and a CD-ROM on ID 6. Cutting it is a parameter change that costs
nothing anyone is using, and it is worth quantifying before anything more
invasive.

Do not start optimising before there is a report. The point of this task is to
find out, and "it does not fit" is a perfectly good answer to come back with.

## What success looks like

A commit that records the actual numbers — ALMs, M10Ks, Fmax — in
`syn/README.md`, and any portability fixes needed to get them, with the
Verilator suite still passing. If it does not fit, or does not close anywhere
near 93.75 MHz, say so plainly with the report to back it. That is the useful
result either way, and it is the first hard evidence this project will have
about whether it runs on real hardware at all.
