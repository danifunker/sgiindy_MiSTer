# Running the CPU test suite on hardware

The `cpu-tests` suite ([cpu-validation.md](cpu-validation.md)) is deliberately
free of emulator-specific requirements - IRIS's test device is probed rather
than assumed, and the output goes to whatever console the machine has - so
the binary that runs in the simulator also runs on hardware. Two kinds of
hardware matter here:

- **the DE10-Nano running this core**, where the suite runs as the machine's
  PROM and is part of the board regression a new bitstream goes through. That
  exercises what Quartus actually built - inferred RAM read-during-write
  behaviour, real DDR3 latency, the real clock - none of which a simulation
  has;
- **a real SGI**, which is the oracle the suite's expectations are validated
  against.

## On the core: `tests/run-cputest-hw.sh`

```sh
bash tests/hw-cputest/build.sh          # -> tests/out/hw-cputest/boot.rom
bash tests/run-cputest-hw.sh --no-build
```

Or `tests/run-cputest-hw.sh` alone, which builds first. Building needs a MIPS
cross toolchain (`CROSS`, default `mips-linux-gnu-`) and a checkout of the
suite with its R4600 case (`CPUTESTS`, default `~/repos/iris/cpu-tests` - see
[cpu-validation.md](cpu-validation.md#the-suite) for which branch); running
needs `scripts/local.env`, copied from `scripts/local.env.sample`, to reach
the MiSTer. For a new bitstream, `scripts/regression.sh TAG RBF --cpu` wraps
the run: it stages the rbf in the board's RAM (no copy to the SD card, no
reboot), runs `tests/run-cputest-hw.sh --no-build --wait 240` on the image
already built, keeps the log as `tests/out/hw/cputest-r4600-TAG.log`, and
checks by md5 that the machine's own PROM went back on the card - four to five
minutes.

Build 44, the 2026-09-18 release, on the board:

```
========================================================
 IRIS CPU test suite   cpu=R4600
   PRId   0x00002020    FIR    0x00002020
   Config 0x0006e4b0    testdev no   L2 no
========================================================
identity/prid .............................. PASS
...
bench/count_rate ...........................   bench/count_rate: 49999988 ticks / 2 s (24999994 + 24999994)
PASS
========================================================
 RESULT: 2415 checks passed, 0 failed  (255 tests)
========================================================

IRIS-CPUTEST-DONE rc=0
scsilog: skipped on the MiSTer core
```

The log is the result; the `rc=` in it is the failure count. Afterwards the
suite spins by design: it has no test device to report an exit to.

### The image

The core has exactly one automatic path into memory: when it starts, the
framework uploads `games/SGIIndy/boot.rom` as the PROM, and the CPU begins
fetching at `0xBFC00000`. Putting the suite there makes a run one ROM deploy
and a relaunch, with nobody at the machine - booting it off a disk through the
real PROM, as on a real Indy, would need the maintenance menu and a keyboard
every time. `tests/hw-cputest/build.sh` makes that image, 512 KB, which is what
`ddr3_mux` gives the PROM region:

| Offset | Contents |
|---|---|
| `0x00000` | `promstub.S`: a jump to `0xBFC01000`, and at `0x200`, `0x280`, `0x300` and `0x380` the four BEV=1 exception vectors |
| `0x01000` | the suite: `objcopy -O binary` of `cputest.elf` |
| the rest | zeros |

The suite already knows how to be loaded anywhere: its `start.S` works out its
load bias and copies itself down to its link address, `0x88200000`, before it
runs anything, so from `0xBFC01000` it copies itself out of the PROM into RAM
and the stub only has to jump to it. The four vectors cover the start of the
run. Until `start.S` has finished that copy and set `Status.BEV` to 0, an
exception goes to the BEV=1 vectors in the PROM, and without these it would
execute whatever bytes happened to be at those offsets and look like a hang.
Each one records `Cause`, `EPC`, `BadVAddr`, `Status` and which vector it was
at KSEG1 `0xA8180000` (magic `EXCP`) and stops, and `read_log.py` prints the
record. After that the suite's own handlers take over: it installs them
before it probes GIO slot 0 for the test device, a read that takes a bus
error on a real Indy with the slot empty.

The suite is patched on the way through, in a scratch copy with carriage
returns stripped - the checkout is never touched:

- **`console-memlog.patch`** adds a third console sink that writes into main
  memory: KSEG1 `0xA8100000` (physical `0x08100000`, 1 MB into RAM, below the
  suite's image), a magic word `ILOG`, a length, then the bytes, 512 KB at
  most. KSEG1 so that a reader outside the CPU sees every byte without the
  suite flushing anything; the header of the patch says why neither of the
  suite's own sinks is used. It also stops the suite writing its log to the
  disk at SCSI ID 2 through its own SCSI driver: on the MiSTer that ID may
  hold a real image, whose LBA 8192 is not the suite's to write. That is the
  `scsilog` line at the end.
- **`relocate-data-only.patch`** makes `start.S` copy `[_ftext, _fbss)` rather
  than `[_ftext, _end)`; it zeroes `.bss` itself anyway. The R4600 suite spans
  about 573 KB to `_end`, more than the PROM region holds, and `build.sh`
  checks that the span it does copy fits.
- **`bench.patch`** adds the five `bench/` tests: throughput in `Count` ticks
  for an ALU loop fetched cached and uncached, cached and uncached loads and
  stores, a load every 32 bytes across 256 KB so that every one misses, and
  `Count` against two seconds of the DS1386. They print; they do not judge.
  They are why the board runs 255 tests to the simulator's 250.

### What the script does

1. **Zeroes main memory** from the ARM (`tools/misterdeploy/memclear.py`).
   Not optional: the log is found by its magic word, DDR3 survives a core
   reload, and nothing in the PROM-stub path clears memory, so a run that never
   started would hand back the *previous* run's log and look like a pass.
2. **Deploys the image as the PROM** (`scripts/deploy.sh --rom-only --rom
   tests/out/hw-cputest/boot.rom`).
3. **Launches the core** (`tools/misterdeploy/launch_unstable_core.py`; with
   `MISTER_RBF_PATH` set, as `regression.sh` sets it, it loads that rbf from
   the board's RAM without a reboot).
4. **Waits** - 180 s by default, `--wait` to change it.
5. **Reads the log out of RAM** with `tests/hw-cputest/read_log.py` on the
   board (through `ddr3_peek.py`) into `tests/out/hw-cputest/hw-cputest.log`,
   followed by the exception record if one was written, and prints the
   `RESULT` and `IRIS-CPUTEST-DONE` lines.
6. **Puts the machine's own PROM back** on the card (`releases/boot.rom`) for
   the next launch, unless `--keep`.

**Byte order is the one subtle part of reading it back.** The core numbers the
bytes of a doubleword big-endian - the byte at `addr + i` is
`data[63-8i -: 8]` - and the ARM reads the same doubleword little-endian, so
the guest's byte `i` is at ARM offset `7 - i` in each group of eight, and
`read_log.py` byte-reverses every doubleword. Getting it wrong produces line
noise rather than an error. Addresses are ARM physical: `sgi_indy.sv` puts
guest RAM at `0x08000000` and `ddr3_mux.sv` puts that region at ARM
`0x30000000`, so the log at guest `0x08100000` is at ARM `0x30100000`.

**`--load`** runs `tools/misterdeploy/hammer.py` on the ARM for the length of
the run: a second heavy reader of DDR3, reading the frame-buffer region, which
contends at the HPS end rather than through `ddr3_mux`'s arbiter. It starts
after the launch, because a launch that reboots the MiSTer would kill anything
started before it, and the script checks that the generator finished - if it
did not, it says to treat the run as unloaded.

## On a real SGI

The IRIS project has done this, on an Indy R4400 rev 6.0 and an Indy R5000
rev 1.0, and its procedure is the one to follow: `cpu-tests/oracle/README.md`
and `rules/testing/running-cpu-tests-on-real-hardware.md` in the IRIS
repository. In outline:

1. Build the ELF and a disk image whose SGI volume header names it:
   `make` and `make image` in `cpu-tests/` (the image needs IRIS's `mkvh`,
   `cargo build --release --bin mkvh`).
2. Put the image on a BlueSCSI at **SCSI ID 2** - the IRIS runs used a
   BlueSCSI v2 - and boot it from the Command Monitor with
   `boot -f dksc(0,2,8)cputest`.
3. The output goes wherever the PROM's console goes, screen or serial: booted
   by the PROM, the suite writes through its ARCS console. It also writes the
   whole log to the disk from LBA 8192, through the PROM's own SCSI driver -
   at any ID but 2 the run prints normally and that write silently fails.
4. Recover the log from the card with `run/extract-log.py`, before the next
   run overwrites it, and classify it against an emulator run with
   `run/diff-hw.py`.

`testdev no` is correct on real hardware, and the machine spins after the
`IRIS-CPUTEST-DONE` line; power-cycle it.

### Which machines

The suite is MIPS III, n32, 64-bit: `-march=mips3 -mabi=n32` means 64-bit
registers, R4000-style CP0, and an FPU with an R4000-family `FIR`. Its harness
is written for the IP22/IP24 memory map and console, and its README restricts
it to those machines.

| Machine | CPU | |
|---|---|---|
| Indy (IP24) | R4400, R5000 | runs; both cases are measured on Indys |
| Indy (IP24) | R4600 | runs; the case is inferred, and no R4600 has run it yet |
| Indy (IP24) | R4000 | runs as an R4400: the two share implementation 0x04, so R4400 expectations are asserted against an R4000 |
| Indigo2 (IP22) | R4400, R4600 | within the harness's machine; no run is recorded |
| Indigo2 | R8000, R10000 | refuses to run, `rc=127`: no case for those `PRId`s |
| Indigo (IP20, IP12) | R4000, R3000A | outside the harness's machine, and the R3000A is not MIPS III at all |

An unrecognised `PRId` is refused rather than tested: the suite prints
`UNKNOWN CPU - refusing to run` and `IRIS-CPUTEST-DONE rc=127`.

## What to do with a result

**From the board**, a failure is either the RTL or the board: run the same
suite in the simulator (`tests/run-cputest.sh`) and compare the two logs test
by test with `tests/compare.py`. A failure only the board shows points at what
the simulator does not model - how Quartus built a RAM, DDR3 latency and
contention (`--load`), the clock. For a cache-sensitive result, suspect the
test as well as the core: `identity/config_k0` once swept `Config.K0` with a
dirty line of its own in the data cache, a hazard on silicon too
([design/r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md)
§4). Record the `RESULT` line with the build it came from; `tests/out/` is not
tracked.

**From silicon**, the silicon wins. Where it disagrees with IRIS, IRIS has a
bug; where it disagrees with this core, the core has one; where it disagrees
with the R4000 manual, read the manual section again before touching anything.
Hardware logs belong with the suite, in `cpu-tests/oracle/`, pinned to the ELF
that produced them - a diff means something only between logs of the same
binary. The run this core most needs is the first R4600 Indy:
`cpu-tests/docs/r4600.md` lists what it would settle, starting with which
answer an R4600 gives for a partial `LWR`.
