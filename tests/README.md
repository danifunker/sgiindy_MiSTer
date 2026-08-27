# Tests

Two regressions, both headless, both run in seconds.

```sh
tests/run-cputest.sh      # the 240-test MIPS III/IV suite, on the core
tests/run-scc.sh          # the Z8530, driven the way the PROM drives it
```

## `run-cputest.sh` — the CPU

Builds `cpu-tests` from the IRIS project, loads the ELF straight into the
harness's RAM model with no PROM, runs it, and diffs the result test by test
against `baseline/iris-r4400.log`. Exit status is non-zero if any test that
passes on the reference fails here.

The suite is *not* forked into this repo. It is a general MIPS III/IV suite
that also runs on real SGI hardware, and its expectations come from the R4000
manual; keeping it upstream is what keeps it honest. Set `CPUTESTS` if your
checkout is elsewhere. See [docs/09-cpu-validation.md](../docs/09-cpu-validation.md)
for the oracle policy and [docs/10-r4300-integration.md](../docs/10-r4300-integration.md)
for the R4300 support that was added to it.

Current: **2114 checks passed, 9 failed** over 240 tests, against 2101 / 61 for
IRIS's own R4400. Three tests fail, all diagnosed in `docs/10`.

## `run-scc.sh` — the SCC

`scc/scctest.c` is a small bare-metal image that programs the Z8530 the way
the PROM does — WR9 channel reset, WR4/3/5/11/12/13/14, then transmitter enable
— and prints a string. The suite deliberately does not do this (it runs after
the PROM, so its `con_init` is a no-op), which means it leaves the transmitter
disabled and exercises almost none of the part.

The run is checked two independent ways that must agree:

- the **byte tap** in `rtl/sgi/sgi_scc.sv`, which fires when the transmitter
  pops a byte off the TX FIFO — what the CPU handed the hardware;
- a **UART decode of the `txdb` pin** in the harness (`--uart`) — what actually
  came out of it, with the bit time measured from the first start bit and the
  stop bit checked on every frame.

A model that queued the writes and never shifted anything would pass the first
and fail the second. That is exactly the bug the pair caught during bring-up:
the wire was correct and the tap was one byte behind, a CDC race between the
grab toggle and its data.

`scctest.c` sends `'U'` first on purpose — its bits alternate, so the first
low run on the line is exactly one bit and the auto-baud cannot come out half
speed.

## The toolchain

Both need a big-endian MIPS cross compiler. macOS has no `mips-linux-gnu-gcc`,
but the `mipsel` cross GCC is bi-endian and `-EB -mabi=n32` produces exactly
the ELF32 MSB n32 image these want:

```sh
brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
```

`CROSS` overrides the prefix if you have a real `mips-linux-gnu-` toolchain.

## `baseline/`

- `iris-r4400.log` — the suite run under IRIS with R4400 expectations. The
  reference `compare.py` diffs against. Regenerate with
  `cd ~/repos/iris/cpu-tests && ../target/release/iris --config run/bare.toml
  --load-elf build/cputest.elf --test-device --headless --noaudio`.
- `r4300-core.log` — the last accepted run on this core, so a regression is
  visible in `git diff` and not just in a terminal.
