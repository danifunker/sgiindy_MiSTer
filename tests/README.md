# Tests

The regressions in this directory run the headless simulator,
`verilator/obj_dir/Vsim_top` (`make -C verilator cputest`), with two
exceptions: `uart/run.sh` is a host-side unit test with no simulator in it, and
`run-cputest-hw.sh` runs on a DE10-Nano. The module benches are Makefile
targets in `verilator/`
([simulation.md](../docs/reference/simulation.md#the-module-benches)).
Everything a test writes goes to `tests/out/`, which is gitignored scratch.

```sh
tests/uart/run.sh          # the harness's serial decoder, host only
tests/run-scc.sh           # the Z8530, driven the way the PROM drives it
tests/run-int.sh           # INT2 to an Interrupt exception, end to end
tests/run-dma.sh           # the HPC3 SCSI DMA channel, no SCSI in it
tests/run-scsiwr.sh        # blocks written to a disk and read back, and read off a CD
tests/run-cputest.sh       # the IRIS cpu-tests suite, against a reference log
tests/run-prom.sh          # boot the real IP24 PROM to the Command Monitor
tests/run-scsi.sh          # the same boot with a disk on ID 1
tests/run-cdrom.sh         # the same boot with a CD-ROM image on ID 6 as well
tests/run-newport.sh       # the same boot with graphics: the picture on the pins
tests/run-rex3.sh          # every pixel REX3 drew against every command it got
tests/run-irix.sh          # an installed IRIX 5.3 booted to the kernel banner
tests/run-cputest-hw.sh    # the cpu-tests suite as the PROM of a real board
```

Each simulated script builds what it needs first — the simulator, and the
test's bare-metal image where it has one — unless it is given `--no-build`,
and exits non-zero on a failure. The bare-metal images' ELFs are committed
(`scc/build/`, `int/build/`, `dma/build/`, `scsiwr/build/`), so with the
simulator built by hand, `--no-build` runs them without a MIPS toolchain.

**Everything except the two graphics tests passes `--no-gfx`**, and that is
not a shortcut: the moment ARCS finds a graphics board the PROM moves its
console onto it and the serial port goes quiet. A serial ratchet has to fit a
machine with no graphics card, which is a real configuration — the OSD's
**Graphics board: None**.

## `run-irix.sh` — the kernel

Boots an installed IRIX 5.3 root off SCSI ID 1, types `1` at the System
Maintenance Menu, and asserts the milestones in order: `System Maintenance
Menu`, `Starting up the system`, `IRIX Release 5.3 IP22` and `Silicon Graphics,
Inc.`, where the run stops. The banner arrives around 200 million clocks; the
budget is 260 million.

Getting there means the PROM read the volume header, `sash` loaded `/unix` off
an EFS file system, and the kernel ran far enough to bring up its own console
— which takes about two and a half million TLB refills. That last part is the
point: this is the only test that runs guest code past the PROM, and the PROM
runs entirely in KSEG0/KSEG1 and never takes a TLB exception, so every other
test here passed against a CPU that looped the kernel for ever on its first
nested refill ([cpu-validation.md](../docs/reference/cpu-validation.md#a-tlb-refill-taken-with-exl-set)).

The image is two gigabytes of installed IRIX and cannot be in the repository.
Set `IRIXDISK` to a raw disk image, or `IRIXCHD` to a MAME CHD (by default
`~/irix-images/Indy-IRIX53_dev.chd`), which the script converts once with
`chdman extractraw` into `$TMPDIR`. With neither it prints `IRIX: SKIP` and
exits 0 rather than reporting a failure it did not measure.

## `run-cputest.sh` — the CPU

Builds the `cpu-tests` suite from an IRIS checkout, loads its ELF straight into
the harness's RAM with no PROM, runs it with the IRIS test device fitted, and
compares the result test by test with a reference log using `compare.py`,
which exits non-zero if any test that passes in the reference fails here.

```sh
CPUTESTS=~/repos/iris/cpu-tests REF=path/to/reference.log tests/run-cputest.sh
tests/run-cputest.sh --no-build --no-dcache     # extra options go to the simulator
```

The suite is *not* forked into this repository. It is a general MIPS III/IV
suite that also runs on real SGI hardware, and its expectations are held
against real machines; keeping it upstream is what keeps it honest.
`CPUTESTS` points at the checkout (default `~/repos/iris/cpu-tests`).
**The core presents as an R4600**
(PRId `0x2020`), and the suite selects its expectations by PRId: it needs its
R4600 case, which is on the IRIS branch `claude/r4600-cputests`; without it
the suite refuses the CPU and exits 127
([r4600-accuracy-clock-disk.md](../docs/design/r4600-accuracy-clock-disk.md) §1).
See [cpu-validation.md](../docs/reference/cpu-validation.md) for the oracle
policy and [cpu.md](../docs/reference/cpu.md) for the CPU itself.

**No reference log is committed** — `*.log` is gitignored — so set `REF` to one
(the default, `tests/baseline/iris-r4400.log`, does not exist and the
comparison fails without it). The script also prints the suite's own summary
and its exit code, the number of failed checks.

The last recorded results are 2,409 checks passed and none failed over 250
tests in the simulator, and 2,415 / 0 over 255 tests on the board
([cache-fill-latency.md](../docs/design/cache-fill-latency.md)).
`--no-icache` and `--no-dcache` pass straight through to the simulator, so a
failure can be bisected onto one of the primary caches without a rebuild.

## `run-scc.sh` — the SCC

`scc/scctest.c` is a small bare-metal image that programs the Z8530 the way the
PROM does — WR9 channel reset, WR4/3/5/11/12/13/14, then transmitter enable —
and prints a string. The CPU suite deliberately does not do this (it runs after
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
the wire was correct and the tap was one byte behind, a clock-domain race
between the grab toggle and its data. The script asserts `uart: MATCHES the
byte tap`, `0 framing errors` and the image's `USCC-TX-OK`.

`scctest.c` sends `'U'` first on purpose — its bits alternate, so the first
low run on the line is exactly one bit and the auto-baud cannot come out half
speed.

## `run-int.sh` — the interrupt path

This one exists because **the PROM cannot test it**. The PROM leaves `L0_MASK`
at zero and polls the WD33C93's AUX STATUS register instead (`FUN_bfc1c380`
reads the address port and tests bit 7), so a boot all the way to the Command
Monitor exercises not one line of INT2 or of the CPU's `Cause.IP` handling.
IRIX does use interrupts, but only `run-irix.sh` gets that far, and it needs an
image this repository cannot carry.

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

It exists because a boot exercises exactly one path through the engine. The
PROM's descriptors never set XIE, so the interrupt path is invisible to a boot;
it never writes `ch_active_mask`; it never uses a link descriptor; and nothing
in a boot points a chain at memory that is not there. All four are here, with
the power-on state and FLUSH.

Two things in it are worth reading before writing a driver for this channel:

- **Reading the control register acknowledges its interrupt.** A wait loop
  that polls `ch_active` there loses the interrupt it is waiting for. The
  first version of this image did exactly that and failed three of its own
  checks. INT2's status register is the thing to watch instead.
- **Clearing HPC3's `ch_reset` resets the WD33C93B**, which then comes up with
  its own interrupt pending on the same INT2 line. It has to be acknowledged
  before anything can tell the two sources apart.

## `run-prom.sh` — the chipset

A **progress ratchet**, not a pass/fail test of the machine. It boots the real
IP24 PROM (`roms/IP24_Indy/ip24prom.070-9101-011.bin`, or `PROM=`) with no
disk and no graphics, types `5` at the System Maintenance Menu, then `version`
and `hinv` at the Command Monitor, and stops on `Mbytes`. What it asserts is
that every milestone the boot has previously reached is still reached, in the
`EXPECT` list, so a change that quietly moves the boot backwards fails a test
instead of being noticed three sessions later. The console lands in
`tests/out/prom-console.txt`.

It also has a forbidden list: strings that used to appear and must not again.
`No usable memory found. Make sure you have a full bank (4 SIMMs)` is the
important one — it is what POST prints when the memory decode stops following
MEMCFG, or when the CPU stops being able to form a physical address above
`0x1FFFFFFF`. Two very different bugs, one message. The keyboard controller's
and the SCSI controller's POST failures, `Diagnostics failed` and `Press any
key to continue` are on it too: each was once an `EXPECT` line, from when the
device was absent and the only question was whether POST got as far as
complaining.

Add a line to `EXPECT` when the PROM starts printing something new. Do not
remove one to make the script pass. **Its processor line still expects `R4400`**,
from before the core presented as an R4600; the recent builds' simulation
gates ran `run-scsi.sh`, which does not check that line, and this script has
not been re-verified against the R4600 presentation.

The run **types at the console** through a real UART on the SCC's receive pin,
so it covers the receive path, not just transmit. The triggers fire in order,
which is a trap worth knowing: a trigger string that stops being printed blocks
every keystroke behind it. That is what `[Press any key to continue.]` did the
moment POST started passing.

## `run-scsi.sh` — the SCSI data path

`run-prom.sh` boots with **no disk**, deliberately: it is the machine's own
ratchet and must not depend on a block device. This is the same boot with a
disk on ID 1, and the difference between the two is the whole DMA engine.
Without the engine every SCSI command printed

```
sc0,1,0: cmd=0x12 timeout after 2 sec.  Resetting SCSI bus
```

because the WD33C93B had taken the first INQUIRY byte, raised DBR and had
nothing behind it. What is asserted now is that the PROM names the disk
`dks0d1s0` and reads its volume header — a real descriptor-driven transfer of a
real block out of a real image file — and that `hinv` lists `SCSI Disk:
scsi(0)disk(1)` and `SCSI CDROM: scsi(0)cdrom(6)`. Each of those lines only
prints if the PROM built the whole ARCS node chain above the device, so each
asserts a shape, not just an INQUIRY. The CD-ROM drive answers with no disc in
it, as a real one does, and its line is the last `hinv` prints, so the run
stops there.

**The disk is `tests/disks/blank8m.img`, and the script does not create it**:
`tests/disks/` is gitignored. Make it once, or point `DISK=` elsewhere:

```sh
mkdir -p tests/disks && dd if=/dev/zero of=tests/disks/blank8m.img bs=1048576 count=8
```

**The volume header is expected to be invalid.** Eight megabytes of zeros is a
block full of nothing, correctly read. A test that wanted a valid header would
be testing the fixture.

The boot is free of SCSI errors, and the forbidden list keeps it so: no
timeouts, no `SYNC negotiation error`, no bus reset of either spelling — the
PROM negotiates synchronous transfer and the target answers — and no `Iris
Audio Processor` line, because HAL2 reports no audio and IRIX's audio driver
must stay unloaded. The history of the engine is in
[history.md#13](../docs/history.md#13).

## `run-cdrom.sh` — the CD-ROM drive

The same boot with a disk on ID 1 and an 8 MB image on ID 6, which
`sgi_scsi.sv` elaborates as a CD-ROM drive: a compile-time choice, because
`CDROM` changes INQUIRY, the logical block size, READ CAPACITY and the MODE
SENSE pages. It asserts that the drive answers INQUIRY as device type 5 and
that the PROM builds the right ARCS node shape for it, with the disk still
listed beside it.

What it does **not** cover is the disc: a drive answers selection with no disc
in it, so the same `hinv` line appears in `run-scsi.sh` with no image at all.
Reading a disc is `run-scsiwr.sh`'s last phase. The image here is built by the
script, with a pattern rather than zeros, for the reason that phase gives. It
needs `tests/disks/blank8m.img` as `run-scsi.sh` does.

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

The images are built by the script under `tests/out/` — a zeroed scratch disk
and a patterned ISO — not taken from a fixture, so the test cannot damage one.
Phase 1 found four bugs when it was written, three of them in code every boot
runs: nothing in a PROM boot writes to a disk, so the memory-to-device half of
the core's first bus master had never moved a byte.

## `run-newport.sh` — the picture

The same boot with a graphics board fitted, which moves the console off the
serial port entirely, so every assertion is made on the **video output pins**
and the frame buffer instead of on text:

- **VC2 completed a frame, and it is exactly 1280 × 1065.** VC2's timing
  generator is an interpreter for a table the PROM loads, and for an
  interpreter "close" is a bug. The PROM loads `np_timing.h`'s 1280×1024 table,
  1,065 lines a frame; the visible window on it is 1,296 pixels wide and the
  display enable is its central 1,280 — frame buffer columns 8..1287, where
  IRIX draws. This said 1318 until build 44, when the enable was RO1's
  pipeline enable and the MiSTer scaler squeezed 1,318 columns into 1,280 by
  dropping one every ~34 ([rex3-source-audit.md](../docs/design/rex3-source-audit.md)
  §3.6): an exact number here had encoded the bug.
- **REX3 drew at least a million pixels, in all three channels.** The frame
  buffer holds a colour index, so a Display Control Bus that dropped the third
  byte of every palette write left the store, the geometry and the pixel count
  perfect and turned the whole boot screen yellow-green; each channel has to
  carry at least 100,000 pixels.
- **The PROM opened `video()`**, so `Cannot open video() for output` is gone.
- **The raster shows the store row for row.** The frame buffer is written to
  `tests/out/newport-fb.ppm` and the last complete frame off the pins to
  `tests/out/newport-pins.ppm`, and `tests/vidshift.py` aligns the rows where
  the pins picture changes with the rows where the store changes (the boot
  screen's gradient gives 165 of them). A size check alone passed on a build
  whose VC2 numbered its lines from 1 and never showed frame buffer row 0
  ([scsi-fit-and-framebuffer-layout.md](../docs/design/scsi-fit-and-framebuffer-layout.md)
  §5); this one fails it.

## `run-rex3.sh` — every pixel against every command

The strongest test of the PROM's drawing, and the only one here that can tell
a rasteriser drawing the wrong thing from one drawing the right thing. It
boots with `np_rex3.sv`'s `REX3_DEBUG` trace on, in its own simulator build
(`make -C verilator cputest-rex3-debug`) — one line per accepted drawing
command, carrying every register that command depends on — and
`tests/rex3_replay.py` replays those commands into a model frame buffer and
compares it with the one the run dumped. On build 44 that is 3,928 commands
and all 1,310,720 pixels checked, none left unchecked. Fewer than 3,000
commands fails the run: the boot did not reach the screen, and the replay would
agree with an empty frame buffer.

It exists because **three separate defects survived a whole session of looking
at the picture**: the logic op decoded from the wrong bits of `DRAWMODE1`, a
missing graphics FIFO that dropped 13 % of a boot's drawing commands, and a
`USER_STATUS` alias answering zero so `REX3WAIT` never waited. None of them
made the machine hang, fail POST, or print anything wrong. All three fail this
test, one of them by 1,102 pixels.

The PROM draws flat colour-index spans and blocks, about a tenth of what REX3
can be told to do. The rest — shading, dither, lines, blending, GL's register
interface — is `verilator/tb_rex3draw.cpp` and the Newport benches.

## `run-cputest-hw.sh` — the CPU suite on the board

The same suite, run on a DE10-Nano as the machine's PROM. Of the three places
it runs — real SGI machines, the simulator and this — it is the one that
exercises what Quartus actually built: inferred M10K read-during-write
behaviour, real DDR3 latency, real clock domains.

```sh
tests/run-cputest-hw.sh [--no-build] [--keep] [--wait N] [--load]
```

`hw-cputest/build.sh` turns the suite into a 512 KB `boot.rom` — a stub with the
boot vectors at 0, the suite at `0x1000` — patching a scratch copy of the
checkout on the way: `console-memlog.patch` adds a console sink in main memory
(uncached, at physical `0x08100000`), because nothing the SCC transmits reaches
the HPS and GIO slot 0 has no test device on the board;
`relocate-data-only.patch` copies only text and data out of the ROM, so a
suite whose `.bss` runs past the 512 KB PROM region still boots from it;
`bench.patch` adds throughput benchmarks. The script then zeroes the
board's main memory so a previous log cannot be read as this one's, installs
the ROM with `scripts/deploy.sh --rom-only`, launches, waits (`--wait`, 180 s
by default), reads the log back over ssh with `hw-cputest/read_log.py`, and
puts the release PROM back unless `--keep`. `--load` runs
`tools/misterdeploy/hammer.py` on the ARM during the run, a second heavy reader
of the shared DDR3. It needs `scripts/local.env`
([deploy-and-debug.md](../docs/reference/deploy-and-debug.md#setup)) and the same
`CPUTESTS` and `CROSS` as `run-cputest.sh` (`CROSS` defaults to
`mips-linux-gnu-` here). `scripts/regression.sh --cpu` runs it with
`--no-build`.

## `colcheck.py` — the monitor, column for column

```sh
python3 tests/colcheck.py SCREEN.png FB.raw [--want 8] [--band 32] [--dy 0]
```

A board check with no simulator: `SCREEN.png` is `scripts/grab.sh`'s capture of
the scaler's output, `FB.raw` is `fbgrab.py`'s colour-index plane of the same
moment. It learns the palette from the two pictures, then reports for each band
of 32 screen columns which offset explains the most pixels. Every screen column
X must show frame buffer column X + 8; one offset across every band is a clean
display, a step between bands is a dropped or doubled column. Build 44 passes
with all 31 bands of content at +8; build 43b had 19 of 30 off. Pixels no frame
buffer column can explain — the cursor, the overlay planes, which the grab does
not read — are counted, not failed. It needs numpy and Pillow;
`scripts/textprobe.sh` produces a matching pair.

## `tlborder/` — the lost delay-slot store, in forty instructions

`tlborder/tlborder.S` reproduces, in about 2,000 cycles, a fault that took a
25-minute IRIX boot to reach: a branch whose delay slot is a store, where the
branch target's page and the store's page both miss the TLB. The fetch-side
fault must not take the store's EPC; if it does, software returns to the
branch target and the store is lost
([history.md#25](../docs/history.md#25)). The CPU suite cannot host the case,
because it runs unmapped from KSEG0. There is no pass/fail wrapper: build it
and read the exception log.

```sh
make -C verilator wholemachine
tests/tlborder/build.sh          # -> tests/out/tlborder/tlborder.elf
./verilator/obj_wm/Vsim_top --elf tests/out/tlborder/tlborder.elf \
    --no-gfx --exc --exc-count 8 --epc --epc-count 8 --max-cycles 300000
```

Correct is `EPC` = the jump, `Cause.BD` = 1, `ExcCode` = TLBS (3) and
`BadVAddr` = the store's address.

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

## The checkers

| file | what it does |
|---|---|
| `compare.py REF LOG` | diffs two `cpu-tests` runs test by test; exit 1 if the run under test fails anything the reference passes |
| `vidshift.py PINS.ppm STORE.ppm` | checks the picture on the pins is the frame buffer store, row for row, by the shape of each row |
| `rex3_replay.py TRACE FB.ppm` | replays a `REX3_DEBUG` trace into a model frame buffer and compares every pixel it can |
| `colcheck.py SCREEN.png FB.raw` | the board's screen against its frame buffer, column for column |

## The toolchain

The bare-metal images and the CPU suite need a big-endian MIPS cross compiler.
macOS has no `mips-linux-gnu-gcc`, but the `mipsel` cross GCC is bi-endian and
`-EB -mabi=n32` produces exactly the ELF32 MSB n32 image these want:

```sh
brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
```

`CROSS` overrides the prefix. The run scripts and the images' Makefiles default
to `mipsel-linux-gnu-`; `tlborder/build.sh` and `hw-cputest/build.sh` default to
`mips-linux-gnu-`.

The repository stores these scripts with LF line endings. A Windows checkout
with `core.autocrlf` gives them CRLF, which bash under WSL will not run; use LF
copies there (`.gitignore` keeps `tests/.*.sh` free for them).
