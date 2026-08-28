# Tests

Seven regressions, all headless.

```sh
tests/uart/run.sh         # the harness's serial decoder, no simulator       ~1 s
tests/run-scc.sh          # the Z8530, driven the way the PROM drives it     ~4 s
tests/run-int.sh          # INT2 to an Interrupt exception, end to end       ~6 s
tests/run-dma.sh          # the HPC3 SCSI DMA channel, no SCSI in it        ~12 s
tests/run-cputest.sh      # the 240-test MIPS III/IV suite, on the core     ~35 s
tests/run-prom.sh         # boot the real IP24 PROM to the Command Monitor
tests/run-scsi.sh         # the same boot with a disk on it, and a block read
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

Current: **2161 checks passed, 3 failed** over 240 tests, against 2101 / 61 for
IRIS's own R4400 — the same expectations, since the core identifies as an
R4400. One test fails, `fpu/vec_cvt_from_l`, diagnosed in `docs/10`.

`--no-icache` and `--no-dcache` pass straight through to the simulator, so a
failure can be bisected onto one of the primary caches without a rebuild.
Caches off, the same run is 2155 / 9 and takes five times as many clocks.

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

## `run-int.sh` — the interrupt path

This one exists because **the PROM cannot test it**. The PROM leaves `L0_MASK`
at zero and polls the WD33C93's AUX STATUS register instead (`FUN_bfc1c380`
reads the address port and tests bit 7), so a boot all the way to the Command
Monitor exercises not one line of INT2 or of the CPU's `Cause.IP` handling.
IRIX is the software that needs interrupts and IRIX does not boot yet, so
without this image the interrupt controller would be code nothing had ever run.

`int/inttest.c` arms 8254 counter 0 — the only interrupt source on this machine
that software can raise by itself — and follows it into the CPU twice:

- straight through to `Cause.IP4`, the unmasked path;
- through `MAP_MASK0` and the `LOCAL0` summary bit to `Cause.IP2`, which is the
  path almost every real source on this machine takes.

It checks the two negatives as carefully as the positives — masked at the CPU
with `Status.IM` clear, and masked at INT2 with `L0_MASK` clear — because a
core that took a spurious interrupt every microsecond would pass a test that
only looked for one arriving.

One finding from writing it is worth knowing before you write a handler for
this core: **clearing a level-sensitive source and returning can re-enter the
handler**, because the clearing store sits in the CPU's write FIFO and `eret`
does not wait for it to drain. Read the device back before returning.

## `run-dma.sh` — the HPC3 SCSI DMA channel

Thirty-one checks on the descriptor engine, with **no SCSI in the image at
all**: it builds descriptor chains in uncached memory, starts the channel, and
reads back what the engine fetched. No byte moves, because there is no device
to hand one over; what is proved is that HPC3 masters the memory bus and reads
a descriptor chain the way the chip specification says.

It exists because the boot exercises exactly one path through the engine and
several of the others will be wrong when something needs them. The PROM's
descriptors never set XIE, so the interrupt path is invisible to a boot; it
never writes `ch_active_mask`; it never uses a link descriptor; and nothing in
a boot points a chain at memory that is not there. All four are here.

Two things in it are worth reading before writing a driver for this channel:

- **Reading the control register acknowledges its interrupt.** A wait loop
  that polls `ch_active` there loses the interrupt it is waiting for. The
  first version of this image did exactly that and failed three of its own
  checks. INT2's status register is the thing to watch instead.
- **Clearing HPC3's `ch_reset` resets the WD33C93B**, which then comes up with
  its own interrupt pending on the same INT2 line. It has to be acknowledged
  before anything can tell the two sources apart.

## `run-prom.sh` — the chipset

A **progress ratchet**, not a pass/fail test of the machine. The PROM is
expected to report the devices this core does not implement — SCSI, the
keyboard controller, graphics — and it does. What the script asserts is that
every milestone the boot has previously reached is still reached, so a change
that quietly moves the boot backwards fails a test instead of being noticed
three sessions later.

It also has a forbidden list: strings that used to appear and must not again.
`No usable memory found. Make sure you have a full bank (4 SIMMs)` is the
important one — it is what POST prints when the memory decode stops following
MEMCFG, or when the CPU stops being able to form a physical address above
`0x1FFFFFFF`. Two very different bugs, one message.

Add a line to `EXPECT` when the PROM starts printing something new. Do not
remove one to make the script pass.

The run also **types at the console**, through a real UART on the SCC's receive
pin — so it covers the receive path, not just transmit. The triggers fire in
order, which is a trap worth knowing: a trigger string that stops being printed
blocks every keystroke behind it. That is what `[Press any key to continue.]`
did the moment POST started passing.

## `run-scsi.sh` — the SCSI data path

`run-prom.sh` boots with **no disk**, deliberately: it is the machine's own
ratchet and must not depend on a block device. This is the same boot with
`--disk 1=tests/disks/blank8m.img`, and the difference between the two is the
whole DMA engine. Without it, every SCSI command printed

```
sc0,1,0: cmd=0x12 timeout after 2 sec.  Resetting SCSI bus
```

because the WD33C93B had taken the first INQUIRY byte, raised DBR and had
nothing behind it. What is asserted now is that the PROM identifies the disk as
`dks0d1s0` and reads its volume header — a real descriptor-driven transfer of a
real block out of a real image file, a byte at a time.

**The volume header is expected to be invalid.** `blank8m.img` is eight
megabytes of zeroes. A test that wanted a valid header would be testing the
fixture.

`sc0,1,0: SYNC negotiation error` is expected too, and is deliberately not
asserted either way: the PROM tries to negotiate synchronous transfer and the
target model has no MESSAGE OUT phase to receive the message in. It is why
`hinv` does not list the disk. See `docs/13-scsi-dma-plan.md`.

## `uart/run.sh` — the harness itself

`verilator/sim_uart.h` is host code, not RTL, so it can be tested without a
simulator — and it needs to be, because every bug in it presents as "the SCC
transmits garbage", which sends you looking at the wrong file. The three cases
are the three ways it has actually been wrong:

- a clean 8N1 burst decodes and the bit time comes out right;
- **the one-clock low on `txdb` at reset** does not open a measurement that
  never closes, which is what made the first real character decode as a single
  `0xFF`;
- **a baud change mid-stream** is picked up, because the PROM does one during
  boot and a harness typing at the stale rate sends garbage that the PROM's own
  auto-baud then chases further.

Plus a loopback of the transmitter, which is the path a keystroke takes.

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
- `core-r4400.log` — the last accepted run on this core, so a regression is
  visible in `git diff` and not just in a terminal.
