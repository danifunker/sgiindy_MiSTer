# SGI Indy / Indigo MiSTer core — documentation

Working notes and reference material for building an SGI workstation core for
MiSTer, distilled from an earlier exploratory project at `~/mistersgi` (a
DE1-based Quartus/Verilator sandbox, not a MiSTer core).

The knowledge base the core is built from, plus a record of what has been
built. Milestones M0 and M1 are done: the CPU runs the 240-test bare-metal MIPS
suite under Verilator at 2161 checks passed / 3 failed against full R4400
expectations, and the Z8530 transmits. `tests/` has both regressions. **Both
primary caches are on**, which is where that figure comes from — see
[docs/10](10-r4300-integration.md#caches).

**M6 — "it boots" — is reached.** The MC, HPC3, IOC2/INT2, the 8254, the
Dallas RTC/NVRAM and a MEMCFG-driven memory decode are in, and the real IP24
PROM runs its power-on diagnostics, prints them over the serial console, takes
keystrokes back, and answers `version` and `hinv` at the `>>` prompt.
[12-chipset.md](12-chipset.md) is the record of that;
`tests/run-prom.sh` reproduces it.

**And it reads a disk.** The HPC3's SCSI DMA channel is the core's first bus
master, and with a disk image attached the PROM completes its INQUIRY and reads
the volume header off it through a descriptor chain in main memory.
[13-scsi-dma-plan.md](13-scsi-dma-plan.md) is the record;
`tests/run-scsi.sh` and `tests/run-dma.sh` hold it.

Anything below that predates the build is still the plan; where the build
proved a plan wrong, the doc says so rather than being quietly rewritten.

| Doc | Contents |
|---|---|
| [00-overview.md](00-overview.md) | What the `~/mistersgi` project is, where it got to, what is reusable |
| [01-source-inventory.md](01-source-inventory.md) | File-by-file map of `~/mistersgi` — what to take, what to leave |
| [02-address-map.md](02-address-map.md) | IP22/IP24 physical address map and per-device register detail |
| [03-boot-prom.md](03-boot-prom.md) | Boot PROM images, reset flow, NVRAM format, bring-up checklist |
| [04-cpu.md](04-cpu.md) | CPU options: aoR3000 (R3000A) vs N64 R4300i vs a real R4400 |
| [05-existing-rtl.md](05-existing-rtl.md) | How `DE1_TOP.v` is wired: bus gearbox, decode tree, peripheral models |
| [06-simulation.md](06-simulation.md) | The Verilator harnesses — headless and interactive — and what they are for |
| [07-mister-port-plan.md](07-mister-port-plan.md) | Proposed plan for turning this into a real MiSTer core |
| **[08-resume-prompt.md](08-resume-prompt.md)** | **Start here if you are picking this work up** — the agent entry point |
| [09-cpu-validation.md](09-cpu-validation.md) | The IRIS bare-metal CPU test suite, and IRIS as behavioural oracle |
| **[10-r4300-integration.md](10-r4300-integration.md)** | **The CPU as built** — the byte-lane contract, turning an R4300 into an R4400, the fixes, the numbers |
| [11-running-on-hardware.md](11-running-on-hardware.md) | Running the same test binary on a real SGI, and which machines it applies to |
| **[12-chipset.md](12-chipset.md)** | **The chipset as built** — MC, HPC3, IOC2/INT2, the timers, the RTC, and the order in which each one blocked the next |
| **[13-scsi-dma-plan.md](13-scsi-dma-plan.md)** | **The HPC3 SCSI DMA engine as built** — the spec-confirmed register map, the bus arbiter, what the plan got wrong, and the one bus phase still between here and a disk in `hinv` |
| **[14-audio-and-graphics.md](14-audio-and-graphics.md)** | **Work-item prompt** for the two devices `hinv` still does not list: HAL2 audio (probably a register model) and Newport (the rest of the machine) |
| **[FEATURES_EVALUATE.md](FEATURES_EVALUATE.md)** | **Deliberately not built**, with the evidence: CD audio (the CD-ROM is data-only), the secondary cache, and why "66 Mhz" is a measurement rather than a clock |
| [prom-reference/](prom-reference/) | Verbatim IP24 boot PROM analysis: `HARDWARE.md`, `ANALYSIS.md` |

## Machines under consideration

| Target | Board | CPU | PROM in hand |
|---|---|---|---|
| **Indy** | IP24 | R4000PC / R4400SC / R4600 / R5000 (MIPS III, big-endian) | `ip24prom.070-9101-007` (5.0 Rev B6), `-011` (5.3 Rev B10) |
| **Indigo** | IP12 | R3000A (MIPS I, big-endian) | `ip12prom.070-8088-xxx` (4.0.1 Rev C, 256 KiB) |
| Indigo (R4000) | IP20 | R4000 | `ip20prom.070-8116-004.BE` |

**Target: Indy / IP24, with the N64 R4300i core.** The decision rests on
`~/repos/iris/cpu-tests/` — a 240-test bare-metal MIPS III/IV suite that makes
CPU correctness measurable, and on IRIS itself as a complete behavioural
reference for the chipset. See [04-cpu.md](04-cpu.md) and
[09-cpu-validation.md](09-cpu-validation.md).

The Indigo/IP12 + aoR3000 path remains the documented fallback if the R4300i
plus Newport does not fit the DE10-Nano.
