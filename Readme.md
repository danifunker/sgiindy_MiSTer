# SGI workstation core for MiSTer

An in-progress MiSTer FPGA core for the **SGI Indy (IP24, R4x00)**, using the
MiSTer N64 project's R4300i CPU.

**Status: the CPU works.** The R4300i runs a 240-test bare-metal MIPS III/IV
suite under Verilator and reports **2114 checks passed, 9 failed** — against
2101 / 61 for the IRIS emulator's own R4400. The Z8530 SCC transmits, verified
against a UART decode of its own output pin. There is no boot PROM execution
yet; that is the next milestone.

```sh
tests/run-cputest.sh      # the CPU suite, ~35 s
tests/run-scc.sh          # the SCC, ~4 s
```

## Where to start

[`docs/README.md`](docs/README.md) indexes everything.
[`docs/10-r4300-integration.md`](docs/10-r4300-integration.md) is the CPU as
built — the byte-lane contract, the seven bugs fixed in the vendored core, and
the numbers. If you are picking this work up,
[`docs/08-resume-prompt.md`](docs/08-resume-prompt.md) is the entry point.

## Layout

| Path | Contents |
|---|---|
| `sgiindy.sv` | MiSTer top level (still the stock template) |
| `rtl/sgi/` | `sgi_indy.sv` (the core), the SCC; MC, HPC3, INT2, DS1386, HAL2 to come |
| `rtl/cpu/` | the R4300i: vendored VHDL, Altera-primitive stand-ins, the bus adapter |
| `rtl/newport/` | Newport graphics (REX3 / VC2 / XMAP9) — later |
| `sys/` | MiSTer framework, from the upstream template |
| `verilator/` | headless simulation harness |
| `tests/` | the CPU and SCC regressions, and their reference logs |
| `tools/` | VHDL→Verilog lowering, upstream diff, PROM tooling |
| `docs/` | design notes, address maps, PROM analysis, port plan |
| `roms/` | boot PROM images (**gitignored** — SGI firmware) |
| `reference/` | chip specs, full PROM disassembly, MAME sources (**gitignored**) |

## Building

Quartus 17.0.x (or 13.x via `sgiindy_Q13.qpf`), per the standard MiSTer flow.
Quartus compiles the CPU's VHDL directly; there is no checked-in netlist.

Simulation needs Verilator, GHDL (to lower the VHDL for Verilator only) and a
big-endian MIPS cross compiler:

```sh
brew install verilator ghdl
brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
make -C verilator cputest
```

The `mipsel` cross GCC is bi-endian; `-EB -mabi=n32` gets the ELF32 MSB image
the tests want, which is what makes this work on macOS at all.

## Licence

**GPL-3.0** — see [`NOTICE.md`](NOTICE.md). The core vendors the MiSTer N64
project's GPL-3.0 CPU, so it cannot be GPL-2.0-only; MiSTer's `sys/` is
"v2 or later", which makes that legal.

## Credits

- MiSTer framework and core template: the MiSTer-devel project.
- R4300i CPU: the MiSTer N64 project (`MiSTer-devel/N64_MiSTer`), GPL-3.0.
  `rtl/cpu/r4300/UPSTREAM.md` records every local change.
- The DE1-based SGI reverse-engineering sandbox this work builds on: OzOnE.
- IRIS, the Rust SGI Indy emulator, used as the behavioural oracle and as the
  source of the bare-metal MIPS III/IV CPU test suite.
- MAME's `indy_indigo2` driver, used as a further cross-reference.
- aoR3000 R3000A core: Aleksander Osman (BSD) — the documented fallback for an
  Indigo/IP12 target.

Boot PROM images are copyrighted SGI firmware and are not distributed here.
