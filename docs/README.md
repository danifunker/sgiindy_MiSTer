# SGI Indy / Indigo MiSTer core — documentation

Working notes and reference material for building an SGI workstation core for
MiSTer, distilled from an earlier exploratory project at `~/mistersgi` (a
DE1-based Quartus/Verilator sandbox, not a MiSTer core).

The knowledge base the core is built from, plus a record of what has been
built. Milestones M0 and M1 are done: the R4300i runs the 240-test bare-metal
MIPS suite under Verilator at 2114 checks passed / 9 failed, and the Z8530
transmits. `tests/` has both regressions.

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
| [06-simulation.md](06-simulation.md) | The Verilator + ImGui harness, spoofs, how to reproduce it |
| [07-mister-port-plan.md](07-mister-port-plan.md) | Proposed plan for turning this into a real MiSTer core |
| **[08-resume-prompt.md](08-resume-prompt.md)** | **Start here if you are picking this work up** — the agent entry point |
| [09-cpu-validation.md](09-cpu-validation.md) | The IRIS bare-metal CPU test suite, and IRIS as behavioural oracle |
| **[10-r4300-integration.md](10-r4300-integration.md)** | **The CPU as built** — the byte-lane contract, the seven fixes, the numbers |
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
