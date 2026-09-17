# Releases

Built bitstreams live in `releases/`, under the date they were built. Nothing
else is kept there — this file is the history, so that the directory a person
downloads from is only the files they need.

Each entry's md5 is checked against what was actually running on the board when
the result below was seen, not against whatever the fitter last left in
`output_files/`.

## Installing one

```
/media/fat/_Computer/SGIIndy_<date>.rbf     the core
/media/fat/games/SGIIndy/boot.rom           the PROM
```

Both files are in `releases/`. Two things about that second line, because both
of them fail silently:

* **MiSTer does not create `games/SGIIndy` for you.** `prefixGameDir` in the
  framework only *computes* the path; the `FileCreatePath` call beside it is
  commented out. A missing directory is not an error anywhere — it is an absent
  PROM, and the machine executes whatever DDR3 powered up with.
* **`SGIIndy` is not a name you can change.** It is the first field of
  `CONF_STR` in `sgiindy.sv`, and it is what the framework uses to find
  `boot.rom`. Rename the directory and the PROM stops being found.

`scripts/deploy.sh` does all of this over the network, including the directory.
See [19-hardware-bringup.md](19-hardware-bringup.md).

---

## SGIIndy_20260917 — the disk driver's busy-wait, loads behind loads, and 7,000 ALMs back

`releases/SGIIndy_20260917.rbf`, md5 `1dc28a9667ae14c3e3b39dd07a4cbb7f`
(build 42, SEED=2; 33,770 ALMs, 40,193 registers, 485 / 553 M10K, core clock
setup slack +2.310 ns, HDMI PLL +0.250 ns, no negative slack in any check).
Same `releases/boot.rom`. Built and tested on the board through 2026-09-17.
Details in [52-fill-latency-area-writebacks.md](52-fill-latency-area-writebacks.md),
[53-scsi-negotiation-us-delay.md](53-scsi-negotiation-us-delay.md) and
[54-hpc3-storage-m10k.md](54-hpc3-storage-m10k.md).

### What changed

* **A fifth of the boot was the disk driver waiting for a chip that never
  answered.** IRIX negotiates synchronous transfer in front of every SCSI
  command, and the WD33C93B model's polled TRANSFER INFO sent its bytes with no
  DBR handshake and interrupted before the driver's loop began - so every
  negotiation timed out (7.4 ms of `us_delay` per command) and the target was
  never marked negotiated, so it was tried again on the next command. The
  command now hands the driver one byte per DBR, the way the part does.
  **`us_delay` in the boot window: 28.8 s -> 1.8 s.**
* **The bus is no longer reset four times per boot.** With the negotiation
  working, the driver's asynchronous path waits two milliseconds before its
  polled INQUIRY, and the target's COMMAND-phase timeout - 2.6 ms, sized for
  something else entirely - cut the connection in the middle of it. It is 84 ms
  now, and a message ending in ABORT or BUS DEVICE RESET ends the connection the
  way a real target does. `wd93 SCSI Bus=0 ID=1: SYNC negotiation error` is gone
  from SYSLOG.
* **A load no longer stalls behind another load or a store**, and a dirty data
  cache line goes back to memory as one transaction instead of four trips
  through the FIFO, the bus and the DDR3 mux.
* **Three clocks off a cache line fill**: an instruction line no longer waits a
  clock only data lines need, the DDR3 mux presents a main-memory request in the
  clock it arrives, and a fill's words reach the cache in the clock they come off
  the bus. A data line fill costs 19.2 clocks on the bus where SGIIndy_20260916
  spent 20.9.
* **7,000 ALMs back, and the device is at 81 % from 93 %.** The configuration
  EEPROM's 2 Kbit and the RAMDAC's control table (1,982 and 1,056 ALMs), then
  HPC3's whole register file: 6,144 bits of PBUS channel pointers, control
  groups and configuration that were flip-flops read twice per bus access -
  3,637 ALMs of it - are two M10Ks now. That headroom is what the next speed
  change will be spent from.
* **The beacon is version 14**: a main-memory read's latency split into the
  bridge's own and the queue's, register 31 at retirement (so the profiler names
  who called a kernel routine), and every DATA-phase clock attributed to the side
  that was holding the bus up.

### Measured

`scripts/perfprobe.sh` on a pristine IRIX 5.3 image, bash `time`. Both columns
are 2026-09-17, six hours apart, with SGIIndy_20260916's build re-run that
morning as the control - the board's own speed drifts between nights, so a
release is only ever compared against something measured beside it:

| workload | build 38, re-run this morning | this file (build 42) |
|---|---:|---:|
| launch until the boot goes quiet | 103.1 s | **83.1 s** |
| launch to the X login screen (11 s polls) | 102 s | **79 s** |
| `us_delay` over the boot capture | 28.8 s | **1.8 s** |
| dd 10 MB off the raw disk | 3.89 s | **2.60 s** |
| `ls -lR /usr/lib/X11` into the Console | 8.16 s | **5.87 s** |
| `xterm -e /bin/true`, cold | 1.12 s | **0.68 s** |
| bzip2 -9 of /unix | 85.5 s | **84.0 s** |
| 60 x `/bin/ls /` | 3.88 s | 3.88 s |
| instruction / data cache line fill, clocks on the bus | 18.5 / 20.2 | 18.5 / **19.2** |

Two numbers went the other way and neither is a slowdown. Clocks per instruction
in the boot window rose from 1.54 to 1.64 because the twenty seconds of a
two-instruction cached busy-loop that used to hold the average down are gone.
Interpreter loops still vary with where their hot pages land in the direct-mapped
instruction cache - perl 12.0 s against 12.6 s here, and the warm `xterm` 0.41 s
against 0.62 s, both single runs on paths nothing in this release touches.

### Tested

In the simulator: `make cpuonly` (728 runs, 0 against expectation); the R4600
cpu-tests suite 2409 / 0 over 250 tests; `run-scsi` (the PROM booting with a disk
attached), `run-scsiwr`, `run-dma` and `run-cdrom`; tb_ddr3, tb_ramarb,
tb_linecache, tb_fetcharb, tb_eeprom, and the new tb_hpc3 - a shadow of the HPC3
spec's address map that the flip-flop register file and the M10K one answer
identically, 27,108 checks each.

On the board, this bitstream: the suite as the PROM **2415 / 0** over 255 tests;
`diskcheck` PASS; a full perfprobe run with no display line-cache miss in any
window and the desktop intact after every workload; no SCSI notice in either
boot's SYSLOG; and a `diskstress.sh` session - sixteen synced copies of /unix
while directories are read underneath, then the whole image compared with the
pristine one block by block - with no block of any file changed that nothing
wrote. Builds 39, 40 and 41 each passed the same board tests as they landed.

## SGIIndy_20260916 — twice the speed, a CPU checked against real Indys, the MiSTer's clock

`releases/SGIIndy_20260916.rbf`, md5 `91980dc9a94ab0f1a052f614e6a1cf6f`
(build 36, SEED=2; 39,090 ALMs, 47,945 registers, 483 / 553 M10K, core
clock setup slack +3.063 ns, HDMI PLL +0.182 ns, every domain met). Same
`releases/boot.rom`.

**This file was replaced the same day.** It was first published as build
30b, md5 `aea29ae92655eb59a8fa88549f2c5f31`, which has only the first group
of changes below. A copy with that md5 is the earlier build; everything in it
is also in this one.

### The speed work (build 30b, docs/50)

Build 27 profiled on the board said the machine was CPU- and memory-bound
rather than waiting on anything, and four changes came out of it:

* **The TLB is matched in parallel.** A lookup used to walk the 48 entries one
  per clock, on every page crossing of every user program, and all 48 before
  each refill exception. Now two clocks, or one for a miss.
* **The instruction cache is 16 KB again**, physically indexed.
* **The DDR3 port is pipelined.** One transaction at a time used to make every
  CPU cache fill queue behind the display's 128-word line reads; commands now
  overlap in the bridge and main memory goes first. A fill's time on the bus
  went from ~40 clocks to 24.
* **A refill of a line the instruction cache already holds is answered from
  it.** The CPU asked for a DDR3 fill after every instruction TLB walk,
  cached or not; 78-98 % of those now need no trip at all.

### Accuracy, the clock, the disk and the pipeline (build 36, docs/51)

* **The CPU against the suite real Indys validated.** The cpu-tests suite
  (`../iris`) was run on an R4400 and an R5000 Indy and turned out to have
  been wrong in sixteen places - and four of this core's changes to the
  vendored CPU had been made to match those wrong answers. They are undone:
  NaN polarity (the fraction's top bit set marks a *signalling* NaN on these
  parts), MIPS IV COP1 function codes are the FPU's Unimplemented Operation
  and not Reserved Instruction, COP2 takes no exception with `Status.CU2`
  set, and `cvt.s.l`/`cvt.d.l` refuse past 2^53. The suite has an R4600
  case now (iris branch `claude/r4600-cputests`), with every expectation's
  source written down.
* **CP0 instructions were usable from User mode**: any IRIX process could
  have written Status. MFC0/MTC0, the TLB instructions, ERET and CACHE are
  now Coprocessor Unusable outside Kernel mode unless `Status.CU0` is set.
* **The clock.** The DS1386 had no time source and powered up in February
  1996 on every load. It takes the MiSTer's clock now, and keeps it across
  resets. Main sends local time; IRIX keeps GMT and applies `/etc/TIMEZONE`,
  so set `TZ=GMT0` there to see the MiSTer's time.
* **The disk.** The HPC3's SCSI DMA engine wrote every byte of a data phase
  to DDR3 as its own transaction; it writes a word per eight bytes now. And
  the WD33C93B takes a READ's bytes four at a time from the target's
  look-ahead, still acknowledging each. Disk data phases during the boot:
  22.4 s -> 11.2 s.
* **The CPU pipeline.** A load no longer holds execute for a clock when the
  next instruction does not need its value, and the display's DDR3 reads go
  out in 4-word sub-bursts instead of build 30b's 16, so a cache line fill
  waits behind at most 8 of its words (fills 24 -> 20 clocks).

### Measured

With `scripts/perfprobe.sh` on a pristine IRIX 5.3 image, bash `time`:

| workload | SGIIndy_20260908_2 | build 30b | this file (build 36) |
|---|---:|---:|---:|
| launch to the X login screen | 216 s | 125 s | **102 s** |
| perl interpreter loop | 44.5 s | 13.5 s | 12.2 s |
| bzip2 -9 of /unix | 215.0 s | 101.9 s | 94.4 s |
| `ls -lR /usr/lib/X11` into the Console | 16.6 s | 8.8 s | 8.1 s |
| 60 x `/bin/ls /` | 8.8 s | 4.9 s | 5.0 s |
| dd 10 MB off the raw disk | 8.1 s | 5.9 s | 3.9 s |
| `xterm -e /bin/true`, warm | 0.77 s (build 28) | 0.51 s | 0.49 s |
| disk data phases in the boot window | | 22.4 s for 42.4 MB | 11.2 s for 42.3 MB |
| clocks per instruction, boot / login | | 1.71 / 1.85 | 1.59 / 1.70 |

The "root login to a settled desktop" row of the build 30b entry (~67 s ->
~49 s) is gone: perfprobe's login capture cannot stop before 45 s, and
recomputed from the capture the login settles in ~29 s (docs/51 §6).

### Tested

Build 36: in the simulator, `make cpuonly` (728 runs, 0 against
expectation), the R4600 cpu-tests suite 2259 / 0 over 246 tests (iris
`5f0c1b2`, including new tests for traps and stalling instructions right
behind a load), the SCSI runs (`run-scsi`, `run-scsiwr`, `run-dma`), tb_ddr3
at sub-burst sizes 16, 8, 4 and 3, and `tb_ds1386`. On the board, this
bitstream: the suite as the PROM 2264 / 0 over 251 tests;
`scripts/diskcheck.sh` (new) PASS - IRIX's own `sum` and `sum -r` of 8.9 MB
of files match the bytes on the image and a 3.2 MB copy it wrote is
identical; a full perfprobe run with no display line-cache miss in any
window; no SCSI notice in either boot's `/var/adm/SYSLOG`. The clock was
measured on build 31: the date the MiSTer says, and 103 s of IRIX time across
a 103.24 s host-timed gap.

Build 30b: `make cpuonly`, the old cpu-tests suite (2160 / 3, the known
`fpu/vec_cvt_from_l`), the whole-machine IRIX boot (console identical to
build 28's and 30's), tb_ddr3 in both sub-burst shapes, tb_ramarb,
tb_linecache, tb_fetcharb; on the board, full perfprobe runs of builds 29, 30
and 30b - every one booted, logged in, ran every workload and shut down, with
no display line-cache miss in any window. The beacon is version 11 (one more
word, the refill counters); the tools in `tools/misterdeploy/` read both.

The IRIX *simulator* boot of build 36's no-stall load printed one
`wd93 ... SYNC negotiation error` notice that its control did not; no board
boot has (docs/51 §9). Perl-like interpreter loops still vary from boot to
boot with where their hot pages land in the direct-mapped instruction cache.

## SGIIndy_20260908_2 — the CD-ROM cached too

`releases/SGIIndy_20260908_2.rbf`, md5 `28e1b0c662efe8ef9df8eef89d9cf10c`
(build 27, SEED=2; 36,609 ALMs, 44,279 registers, 475 / 553 M10K, core
clock setup slack +3.069 ns, every domain met). Same `releases/boot.rom`.

Two hours after 20260908, the same block cache with the CD-ROM slot cached
as well: a 64-sector window like the disks', 8-sector transactions, so an
install or a `dd` off the disc costs one HPS transaction per 4 KB instead
of one per 512-byte sector (docs/49 §6). Nothing changes in Main_MiSTer:
the CD slot of this core is served by Main's generic image path (the Mac
fork's CD special cases are gated on the Mac cores), the same path the
disks' multi-block reads already used. One rule of the cache changed with
it: a mount pulse carrying the same image size now drops the slot's clean
lines and keeps only the dirty ones, so two ISOs of one size swapped in
the OSD cannot serve each other's blocks. A CHD in the CD slot was never
decoded for this core by Main and still is not: use a flat ISO.

Tested: the cache bench in three shapes (286,500 checks, 0 failures in the
shipped one), the four PROM-level SCSI runs (the CD-block phase of the write
test and the CD-ROM ratchet read the disc through the cache), the
whole-machine IRIX boot identical to build 25's; on the board, four
IRIX 5.3 boots to the login screen (two from a pristine image), 64 MB read
raw off the install ISO with the cache on and off (16,752 vs 133,878 HPS
transactions, target wait 8.1 s vs 18.9 s, the disc at 1.6 MB/s on the bus
either way), and a 16 MB read checksummed by IRIX's `sum` against the ISO:
checksum match (docs/49 §6).

## SGIIndy_20260908 — the SCSI block cache

`releases/SGIIndy_20260908.rbf`, md5 `4e1cd4ea4d37ae42da9b0b17fb02ebe2`
(build 26, SEED=2; 36,296 ALMs, 44,117 registers, 443 / 553 M10K, core
clock setup slack +2.875 ns, every domain met). Pair it with the same
`releases/boot.rom` as before.

### What it is

Build 25 plus a per-target read-ahead / write-behind block cache between
the SCSI targets and the MiSTer block channel (`rtl/scsi/scsi_cache.sv`,
ported from MacQuadra800_MiSTer; docs/49). Each disk owns a 64-sector
window in block RAM: a sector read that hits is served from RAM, a miss
fetches its aligned 8-sector group in one HPS transaction and the next two
groups are prefetched behind it, and a write is accepted into RAM at once
and flushed in the background, a whole group at a time. IRIX no longer
waits for the SD card on every sector it writes, nor for a Main_MiSTer
round trip on every sector it reads. The CD-ROM reads as before.

A new OSD entry, **SCSI cache: On / Off**. Off turns the cache into a
plain passthrough (one HPS transaction per sector, the 20260907 behaviour)
on the same bitstream; it is how the numbers below were taken, and the way
out if the cache ever misbehaves with an image. Switching it while IRIX is
running is safe: dirty data is flushed before the first bypassed request.

### What it measures

The core now counts its own disk time (five beacon words, `bcnread.py
--stats`; `scripts/irixrate.sh --stats` logs them every poll). One IRIX 5.3
boot from a pristine image each way, on the DE10-Nano (build A of this
source, identical on the board):

| | cache ON | cache OFF |
|---|---|---|
| time the guest waited on its disk | **8.6 s** | **21.3 s** |
| HPS transactions, read + write | 8,313 + 4,691 | 45,312 + 7,055 |
| cache hits / misses | 45,144 / 1,606 | - |
| SCSI bus busy | 26.1 s | 34.8 s |
| DATA phases: bytes, rate | 26.6 MB at 1.21 MB/s | 26.8 MB at 0.93 MB/s |
| to the X login screen | 258 s | 259 s |

The disk wait falls by 60 %. The boot does not get measurably shorter:
disk was 8 % of a 259 s boot, and the 22 s poll that classifies the boot
cannot resolve a 13 s change. The remaining disk cost is the SCSI byte
path itself - the DATA phases move 26 MB at 1.2 MB/s, 22 s of the boot -
which is the next thing to instrument (docs/49 §4).

### How it was tested

`verilator/tb_scsi_cache.sv` (the Mac's bench with a bypass test and a
stricter device model) 285,472 checks / 0 failures in both configurations;
`tests/run-scsi.sh`, `run-scsiwr.sh` (five write/read phases through the
cache), `run-cdrom.sh`, and `run-scsi` with the cache bypassed, all PASS;
the whole-machine Verilator IRIX boot to 230M cycles with the console and
the exit device table identical to build 25's; on the board, this
bitstream booted IRIX 5.3 from a pristine image to the X login screen with
the cache on (257 s, no panic; disk wait 9.2 s, 45,649 hits / 1,644
misses) and again with it off (258 s, no panic; disk wait 20.2 s).

### Known

* Everything in the 20260907 entry still applies (the crash-looped image
  after an `init died`, the sim's device wait, the `hinv` stubs).
* The cache holds up to 64 KB of the guest's writes for a few milliseconds
  after it acknowledges them. IRIX's own shutdown syncs long before the
  power goes; pulling the card mid-write was never safe.
* The CD-ROM slot is not cached in this build (`CACHE_CD = 0`): an install
  from CD still costs one HPS transaction per 512-byte sector. 20260908_2
  above fixes that.

## SGIIndy_20260907 — IRIX 5.3 to the desktop on the R4600 core

`releases/SGIIndy_20260907.rbf`, md5 `647091e8250543f64f04d42d96278bce`
(build 25, SEED=2; 34,637 ALMs, 42,804 registers, core clock setup slack
+1.981 ns). Pair it with the same `releases/boot.rom` as before.

### What it is

The CPU is now the Killer Instinct R4600 base (`rtl/cpu/r4300/UPSTREAM.md`
is the authority on every change from that base): PRId 0x2020, 48 TLB
entries, 16 KB physically indexed data cache with 32-byte lines and burst
fills, and an 8 KB **physically indexed** instruction cache with a full
20-bit tag. The system boots IRIX 5.3 from the SCSI disk image to the X
login chooser and the 4Dwm desktop, with a working keyboard and mouse.

### What was fixed since 20260901

* The instruction cache. Three failures in a row, each a different bit of
  it: IRIX colours user pages for the part the PRId names — bits 13:12 as an
  R4400, bit 12 only as an R4600 — so KI's 16 KB virtually indexed cache
  with an 18-bit tag executed the wrong 4 KB page under the R4600 identity
  (bus errors, SIGSEGVs and SIGILLs all through rc2); an 8 KB one-way cache
  with the full tag stopped the wrong hits but still indexed on virtual bit
  12, which an uncoloured mapping can leave stale where the kernel's
  invalidate by physical address never looks; the released cache takes bit
  12 from the instruction mini-TLB, fills by physical address and
  translates `Hit_Invalidate_I`, so a line lives in exactly one set for
  every mapping (docs/45, docs/47).
* `Config.EC` = 0 under the R4600 identity: the IP24 PROM divides by a
  per-family clock-ratio table and EC = 7 is a `break 7` on the R4600 path
  (docs/44).
* The memory path no longer crosses clock domains (KI's clk93/clk1x mailbox
  is gone; this core has one clock), which is where the slack came from.

### How it was tested

`make -C verilator cpuonly` 728/0; the cpu-tests suite 2161/3 (only
`fpu/vec_cvt_from_l`, unchanged since the N64 base); the whole-machine
Verilator IRIX boot clean to 230M cycles with the exit device table
identical to the previous build's; on the DE10-Nano, **five IRIX boots out
of five to the login chooser**, each from a pristine disk image
(`scripts/irixrate.sh --fresh`); the hardware cpu-tests on this bitstream
**2166 passed / 3 failed** (245 tests; the three are `fpu/vec_cvt_from_l`,
unchanged since the N64 base), PRId and FIR 0x2020, and the bench numbers
identical to build 24's to the tick (`i_cached` 500 ticks/kinstr,
`ld_miss` 13 ticks/load, `count_rate` 25.0M/s).

### Known

* An `init died` panic — from any cause — leaves `/etc/ioctl.syscon`,
  `/var/adm/utmp` and `/var/adm/utmpx` empty, and IRIX's init then dies on
  them at every following boot. That is a property of the disk image, not
  of this core: restore a clean image (docs/47).
* The simulator never reaches "The system is coming up" (a sim-only device
  wait); the board does.
* `hinv` on this build (`tests/out/hw/hinv-b25.txt`): "1 50 MHZ IP22
  Processor", "CPU: MIPS R4600 Processor Chip Revision: 2.0", FPU R4600
  2.0, 16 KB / 16 KB caches, 48 MB, "Integral SCSI controller 0: Version
  WD33C93A", disk on unit 1 and CD-ROM on unit 6, "Graphics board: Indy
  24-bit". It also lists an ISDN unit, an Ethernet `ec0` and a Presenter
  adapter - stubs answering probes; none of the three works (docs/48).

## SGIIndy_20260829 — the first build that draws

**The machine draws its own boot screen on a DE10-Nano**, and goes on to the
System Maintenance Menu. `releases/SGIIndy_20260829_bootscreen.png` is the
splash: the gradient, the hourglass, "Running power-on diagnostics...",
"WELCOME TO INDY" and "Silicon Graphics Computer Systems", in colour, stable
across screenshots ninety seconds apart. The frame buffer holds 171 distinct
colour indices where the build before it held three.

    rbf       md5 214e9fddd29f7322490de25643388446   3,813,644 bytes
    boot.rom  md5 11bb4acd64fb7c79c985d3d09390668b   PROM Monitor 5.3 Rev B10
                                                     (ip24prom.070-9101-011)
    Quartus 17.0.2 Lite, 5CSEBA6U23I7
    30,611 / 41,910 ALMs (73%), 294 / 553 M10K (53%), 51 / 112 DSP
    Timing met on every clock, TNS 0.000, core clock slack +4.287 ns

### What works

* The PROM runs, sizes memory, finds Newport, programs VC2, draws the boot
  screen and reaches the **System Maintenance Menu**.
* Video out at 1318 x 1024 — the raster `tests/run-newport.sh` asserts, to the
  pixel.
* The colour map: the boot screen's colours are right.
* Main memory in DDR3, 48 MB, and the PROM's own walking-bit sizing test passes
  over all of it.
* PS/2 keyboard and mouse reach the 8042 in IOC2; three SCSI drive slots exist.

### What does not

* **It is slow to get there.** REX3 waits for every write to be acknowledged,
  so a pixel costs a DDR3 round trip and the boot screen takes a while to
  paint. Give it a minute or two, and a restart if it seems not to be
  progressing. Correct, and slower than it needs to be — a "taken" handshake on
  the frame buffer port would let more than one write be in flight.
* **About 14 Hz.** `PIX_DIV` is 2 because at 1 the display wants 0.80 words a
  clock against a DDR3 port whose peak is 1.00. The fix is not a faster clock:
  it is to split the frame buffer into separate RGB and auxiliary planes the
  way IRIS does, which halves the fetch and gives 27 Hz back. See
  [18-mister-integration.md](18-mister-integration.md) section 0.
* **No mouse cursor.** The mouse's data reaches the 8042, but nothing draws a
  pointer: VC2 holds the position registers and generates no cursor planes, and
  `np_bt445`'s three cursor colours are wired to nothing. See
  [16-newport-plan.md](16-newport-plan.md), milestone N4.
* **No serial console.** With the graphics board unfitted the machine still
  runs, but `/proc/tty/driver/serial` on the HPS reports `rx:0` — not one start
  bit, ever. `sclk` is the suspect; the OSD's "UART debug" entry is a probe that
  settles it and has not been run yet.
* No audio, no Ethernet, and nothing persists across a reset — the PROM rebuilds
  its environment every boot.

### What made it draw

Four bugs, and every one of them was the same bug: RTL written against
`verilator/sim_ram.v`, which accepts a request every cycle and never refuses
one, meeting `rtl/mister/ddr3_mux.sv`, which holds a single transaction at a
time and takes tens of cycles over it.

| | what was wrong |
|---|---|
| `ddr3_mux.sv` | a HELD request was latched twice, which put REX3 permanently one acknowledgement behind and made it write the CPU's instruction fetches into the frame buffer as pixels |
| `newport.sv` | `PIX_DIV` had gone to 1 for a free doubling of the frame rate; it was not free, and the display missed 710 of every 1318 pixels |
| `fb_linecache.sv` | rewritten as a four-buffer ring — and the first attempt declared them in a generate loop, which infers no memory at all and failed the fit at 291% of the device with no warning |
| `np_rex3.sv` | `DR_FILL` asserted a write every cycle and counted assertions rather than acceptances: 249 of a 256-pixel rectangle lost at DDR3 latency, and then it wedged |

In three of the four the existing test was actively reassuring. `tb_ddr3` drove
every master as a one-cycle pulse and never modelled one that holds its request
through the acknowledgement; `tb_linecache` hard-coded `PIX_DIV = 2` long after
the RTL moved to 1. Both fail against the old code now, and
`verilator/tb_rex3.cpp` is new.
