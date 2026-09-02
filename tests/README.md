# Tests

Eleven regressions, all headless.

```sh
tests/uart/run.sh         # the harness's serial decoder, no simulator       ~1 s
make -C verilator vc2test && verilator/obj_dir_vc2/Vnp_vc2   # VC2's timing generator
tests/run-scc.sh          # the Z8530, driven the way the PROM drives it     ~4 s
tests/run-int.sh          # INT2 to an Interrupt exception, end to end       ~6 s
tests/run-dma.sh          # the HPC3 SCSI DMA channel, no SCSI in it        ~12 s
tests/run-scsiwr.sh       # a block written to a disk and read back         ~30 s
tests/run-cputest.sh      # the 240-test MIPS III/IV suite, on the core     ~35 s
tests/run-prom.sh         # boot the real IP24 PROM to the Command Monitor
tests/run-scsi.sh         # the same boot with a disk on it, and a block read
tests/run-cdrom.sh        # the same boot with a CD-ROM drive on ID 6
tests/run-newport.sh      # the same boot with graphics, and the picture
tests/run-rex3.sh         # every pixel REX3 drew against every command it got
tests/run-irix.sh         # boot an INSTALLED IRIX 5.3 root to the kernel    ~5 m
```

`run-irix.sh` is the only one that runs guest code past the PROM, and it needs
a two-gigabyte installed-IRIX image this repository cannot carry — it **skips**
without one. It is worth its five minutes: the PROM never uses the TLB, so
every other test here passed against the CPU bug in `docs/09` that looped the
IRIX kernel forever on its first nested TLB miss.

**Everything except the last two graphics tests passes `--no-gfx`**, and that is not a
shortcut: the moment ARCS finds a graphics board the PROM moves its console
onto it and the serial port goes quiet. A serial ratchet has to fit a machine
with no graphics card, which is a real configuration and the one every boot log
in this repository showed before Newport existed.

## `run-irix.sh` — the kernel

Boots an installed IRIX 5.3 root off SCSI ID 1, presses `1` at the System
Maintenance Menu, and asserts the kernel identifies itself:

```
IRIX Release 5.3 IP22 Version 12200159 System V
Copyright 1987-1994 Silicon Graphics, Inc.
```

Getting there means the PROM read the volume header, `sash` loaded `/unix`
off an EFS filesystem, and the kernel ran far enough to bring up its own
console — which on an R4400 means a few million TLB refill exceptions. That
last part is the point. `docs/09`, "A TLB refill taken with EXL set", is a
CPU bug that every other test in this directory passes over, because the PROM
runs entirely in KSEG0/KSEG1 and never takes a TLB exception at all.

The image is not in the repository and cannot be. Set `IRIXDISK` to a raw
disk image, or `IRIXCHD` to a MAME CHD (the script will run `chdman
extractraw` once and cache the result in `$TMPDIR`). With neither it prints
`IRIX: SKIP` and exits 0 rather than reporting a failure it did not measure.

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

The boot is now free of SCSI errors entirely, and the forbidden list says so:
`SYNC negotiation error` and `resetting SCSI bus` must not come back. Both were
real until the SCSI message phases were built — the PROM negotiates synchronous
transfer and the target had nowhere to receive the message.

**`hinv` lists the disk, and this script asserts it.** It always did: three
successive theories about why the disk was "missing from the ARCS device tree"
were all wrong, because the harness was stopping the run on `Mbytes` and the
PROM prints the SCSI lines *after* `Memory size:`. Nobody checked whether the
line was being printed before working out why it was not.
See `docs/13-scsi-dma-plan.md`.

## `run-scsiwr.sh` — the SCSI data path, in both directions

Six phases against two targets, all bare metal, no PROM:

| phase | what it does |
|---|---|
| 1 | one block, WRITE(6)/READ(6), one descriptor |
| 2 | four blocks in one WRITE(6), so the target advances its own LBA |
| 3 | four blocks through WRITE(10)/READ(10) — a ten-byte CDB, which is a different length decode in both the WD33C93B and the target |
| 4 | four blocks out over three data descriptors, back over two |
| 5 | 16 KB over four descriptors each way |
| 6 | four 2048-byte logical blocks off the CD-ROM on ID 6, over a chain |

Three details are load-bearing and a casual version of this test misses all
three. **The pattern is seeded per phase**, so a transfer that moved nothing
cannot pass on the previous phase's bytes still sitting in the buffer. **The
descriptor splits differ between the write and the read**, so a chaining bug
cannot cancel itself. And **the CD read is at a non-zero LBA**, because
`scsi.v` multiplies a CD-ROM's logical block number by four to reach the
512-byte host blocks behind it, and at LBA 0 a missing multiply and a correct
one give the same answer.

Phase 1 found four bugs when it was written, three of them in code every boot
runs. Phases 2 to 6 were added to test the leading theory about why the IRIX
5.3 installer panics after "Copy complete" — and they passed first time, which
means that theory is wrong. See `docs/13-scsi-dma-plan.md`.

## `run-newport.sh` — the picture

The same boot with a graphics board fitted, which moves the console off the
serial port entirely, so every assertion is made on the **video output pins**
and the frame buffer instead of on text. The frame size is checked exactly —
1318 x 1065, which is what walking `n1280_r3` out of `np_timing.h` by hand
gives — because VC2's timing generator is an interpreter for a table the PROM
loads, and for an interpreter "close" is a bug. The frame buffer is written to
`tests/out/newport-fb.ppm` and the last complete frame off the pins to
`tests/out/newport-pins.ppm`, and `tests/vidshift.py` then insists the raster
shows the store **row for row**: it aligns the rows where the pins picture
changes with the rows where the store changes (the boot screen's gradient
gives about 150 of them). A size check alone passed on a build whose VC2
numbered its lines from 1 and never showed frame buffer row 0 (docs/36
section 5); this one fails it.

## `run-rex3.sh` — every pixel against every command

The strongest test here, and the only one that can tell a rasteriser drawing
the wrong thing from one drawing the right thing. It boots with `np_rex3.sv`'s
`REX3_DEBUG` trace on — one line per accepted drawing command, carrying every
register that command depends on — and `tests/rex3_replay.py` replays those
commands into a model frame buffer and compares it with the one the run dumped.
A current boot is 10,412 commands and all 1,310,720 pixels, with none left
unchecked.

It exists because **three separate defects survived a whole session of looking
at the picture**: the logic op decoded from the wrong bits of `DRAWMODE1`, a
missing graphics FIFO that dropped 13% of a boot's drawing commands, and a
`USER_STATUS` alias answering zero so `REX3WAIT` never waited. None of them
made the machine hang, fail POST, or print anything wrong. All three fail this
test, one of them by 1102 pixels.

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
