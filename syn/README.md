# Measuring the fit

`sgiindy.sv` is still the stock MiSTer template and there is no SDRAM
controller, so **there is no core to build yet**. But the question this
directory answers does not need one:

> does the chipset and the R4300i fit on a DE10-Nano, and at what clock?

That needs the logic synthesised against the right device and nothing else.

## The answer

It does now. It did not at first, and the difference is not a smaller design -
it is the same design with three memories that Quartus can actually recognise
as memories.

Quartus Prime 17.0.2 Lite, `5CSEBA6U23I7`, `syn_top`:

| | ALMs | registers | M10K | block mem bits | Fmax |
|---|---:|---:|---:|---:|---:|
| as found | **74,751 / 41,910 (178%)** | 121,749 | 0 | 1,126,528 | *none - never placed* |
| memories fixed | 21,347 (51%) | 21,255 | 144 / 553 | 1,191,200 | 61.83 MHz |
| + 3 SCSI targets | **19,137 (46%)** | 19,570 | 80 / 553 | 666,912 (12%) | **63.77 MHz** |

The first row is a failure, not a measurement:

```
Error (170012): Fitter requires 7598 LABs to implement the design,
                but the device contains only 4191 LABs
```

A design that never places has no timing, which is why there is no Fmax
against it. **Block memory was not the constraint** - it sat at 20% while the
logic was at 178%, the opposite of what this file used to predict.

## What was actually wrong

Every bit of the overshoot was storage. **103,922 of the 121,749 registers -
85% - were arrays that never became memory blocks**, and the muxes to read
them were most of the ALUTs. Three of them, in order of size:

**`sgi_ds1386.sv`, the real-time clock: 30,430 ALUTs and 65,713 registers.**
Larger than the entire R4300i, for a clock chip. Its 8 KB of NVRAM had *four*
ports - `dev_rd(1'b0)` and `dev_rd(1'b1)` each read it and the unrolled write
loop wrote it twice - and a memory block has two. Three changes, none of which
alter what the device does:

* the array is split into even/odd banks. Free, because the device index is
  `{addr[14:3], w}`, so the bit that separates the two accesses *is* `w`.
* the read had a mux *and* a `rdata <= 64'h0` default between the array and
  its register. A read **enable** is fine; anything else in that path is not.
  The mux moved after the register.
* the write was nested in a `for` loop behind a block-local declaration.
  Quartus did not recognise it as a memory write and **said nothing at all** -
  no "uninferred RAM" message, it simply built 65,536 flip-flops.

Now **307 ALUTs and 178 registers**, with the NVRAM in M10Ks.

**`rtl/cpu/prim/RamMLAB.vhd`, the CPU's LUTRAMs: ~12,300 ALUTs and 36,096
registers** across nine instances - both instruction-cache tag rams, the TLB,
and the integer and FPU register files. One line:

```vhdl
attribute ramstyle of mem : signal is "MLAB, no_rw_check";
```

Quartus was rejecting all nine with *"uninferred due to unsupported
read-during-write behavior"*. `no_rw_check` is not a relaxation: the header of
that same file documents the `altdpram` it stands in for as
`read_during_write_mode_mixed_ports = CONSTRAINED_DONT_CARE`, already
unspecified. The attribute only tells Quartus what the file already says. They
now infer as `altdpram` at **0 ALUTs and 0 registers**.

**`rtl/scsi/sgi_scsi.sv`, the seven SCSI targets: 7,993 ALUTs and 917,504
bits.** Every SCSI ID got a full target with two 512-byte sector buffers,
because in simulation that was free. `TARGET_EN` is now a per-ID mask rather
than a count, defaulting to three: a disk on 1, a spare on 2, the CD-ROM on 6.

It has to be a mask and not a count. `NUM_TARGETS` indexes the generate
directly, so lowering it to 3 would build IDs 0..2 and **delete the CD-ROM**,
which lives at ID 6 (`CDROM_IDS`) - and the SCSI ID is visible software state:
`hinv` prints it, IRIX device paths encode it, `dksc(0,6,0)` names it. The
mask keeps the ID space at 0..6 and simply does not build what nobody
addresses. Port widths stay 7 bits, so nothing above `sgi_scsi` changes.

### The theme

Every compile failure before this was a *construct* Verilator accepts and
Quartus rejects. These are one level up: **models both tools accept and build
completely differently** - free in simulation, ruinous on silicon. They cost
nothing to write and they are invisible until something places the design.

Quartus will tell you, but you have to ask: `Info (276014): Found N instances
of uninferred RAM logic`, and then the reason per instance. Grep the map log
for `276014` before assuming an array became a memory. The worst case is the
one that produces no message at all, which is what the RTC did.

## Timing

The full design closes at **63.77 MHz** with three SCSI targets, and 61.83 MHz
with seven, against a 50 MHz constraint the SDC asks for on purpose - see the
note in `sgiindy_syn.sdc`. So the constraint is met with room, but that is not
the interesting number.

`cpu_top.sv` is a second, CPU-only project (`sgiindy_cpu`) that exists because
the R4300i is the one block with a published figure to compare against: the
MiSTer N64 core runs this same CPU at 93.75 MHz.

| `sgiindy_cpu` | ALMs | registers | Fmax |
|---|---:|---:|---:|
| before the MLAB fix | 24,284 (58%) | 42,491 | 55.88 MHz |
| after | **8,555 (20%)** | 6,113 | **64.04 MHz** |

The LUTRAM fix bought 15% of clock as well as two thirds of the area, which is
the same story as the resources: reading 512 words out of flip-flops through a
mux is a long path. **64 MHz is still well short of 93.75**, so there is
something else between this and upstream worth finding, and this harness is
where to look for it. Read it as an upper bound on the CPU: it has no chipset
attached, and the real core can only be slower.

## Run it

Quartus does not run on macOS, so this has to happen on a Linux or Windows
machine with Quartus 17.0 or later (the version the vendored CPU was written
against; newer is fine):

```sh
cd syn
quartus_sh --flow compile sgiindy_syn      # the chipset and the CPU
quartus_sh --flow compile sgiindy_cpu      # the CPU on its own, for Fmax
```

Or, for resource numbers without placement, Analysis & Synthesis alone is much
faster and needs no pins:

```sh
quartus_map sgiindy_syn
```

## What to read

* `output_files/sgiindy_syn.fit.summary` - ALMs, registers, M10Ks. If the
  fitter failed, `Error (170012)` in `sgiindy_syn.fit.rpt` names the shortfall.
* `output_files/sgiindy_syn.map.rpt`, the *Resource Utilization by Entity*
  table - where the logic actually went, per module. This is the one that
  found the RTC.
* `output_files/sgiindy_syn.sta.rpt` - Fmax and the worst path.

## What this is not

**A clean report here does not mean the core works.** Nothing in `syn/` is
wired to anything: `syn_top.sv` drives the core's inputs from an LFSR and
XORs its outputs into one pin, purely so Quartus cannot optimise the design
away and so the fitter has few enough pins to place. It will not boot, and it
is not a step towards booting - it is a measurement. `cpu_top.sv` is the same
trick around the CPU alone.

`mem_mb` is tied to a constant 48 in the harness, matching the single-SDRAM
target, because on hardware it is fixed by which SDRAM is fitted and tying it
lets `sgi_memmap`'s bank arithmetic fold away. Leaving it live would put
adders in the report that a real core would never build.

## What is left

Where the remaining logic goes, at 26,350 ALUTs total:

| | ALUTs | registers |
|---|---:|---:|
| `r4300_wrap` (of which `cpu_FPU` is 3,409) | 10,651 | 5,517 |
| `sgi_hpc3` | 4,611 | 6,359 |
| `sgi_scsi` (3 targets) | 4,204 | 1,459 |
| `eeprom_93c56` | 2,926 | 2,113 |
| `sgi_mc` | 1,106 | 1,235 |
| everything else | ~2,850 | ~1,880 |

`eeprom_93c56` is the last uninferred memory - 2 Kbit costing 2,113
registers, reported as `asynchronous read logic`. Its read lands in `shifter`,
a shift register with many other drivers, so it cannot be the array's output
register; fixing it means giving the array a register of its own without
moving the byte it feeds a cycle later. Left alone deliberately: it is the
smallest of the three and the fiddliest.

`sgi_hpc3`'s 6,359 registers are the DMA descriptor and control arrays
(`dma_desc[32]`, `dma_ctrl[128]`, and the config blocks) - 192 words of 32
bits. Those are genuinely multi-ported registers, not a memory written
wrongly, so they are a redesign rather than a fix.

**There is now real headroom** - about half the device is free, and none of the
MiSTer framework, the SDRAM controller or the video path is in this figure yet.
They will take a large bite out of it.
