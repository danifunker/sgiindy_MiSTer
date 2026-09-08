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
