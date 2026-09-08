# Work item: after release SGIIndy_20260907 - the hardware this core still lacks, and a SCSI block cache ported from MacQuadra800

Paste everything below the line as the opening message of a fresh session.
This continues [47](47-resume-init-sigsegv-icache-pipt.md) (the PIPT
instruction cache, the crash-looped disk image, the release). Written
2026-09-08 12:45.

---

## STATE AT HANDOFF (read this first)

* **Released: `releases/SGIIndy_20260907.rbf`** = build 25 (md5
  `647091e8250543f64f04d42d96278bce`), entry in `docs/20-releases.md`.
  `main` is at `34b89d9` (the release commit, dated 2026-09-07 at the
  user's request) and is PUSHED to GitHub; the worktree branch
  `claude/docs47-pipt-icache` (`.claude/worktrees/modest-robinson-cad59e`)
  carries the follow-ups after it (hardware cpu-tests on build 25, the
  `hinv` script and capture, this document) and fast-forwards onto main.
  Push with the HTTPS URL (`git push https://github.com/danifunker/
  sgiindy_MiSTer.git main`): the ssh remote is refused from a Claude shell.
* **What build 25 is:** the Killer Instinct R4600 CPU base
  (`rtl/cpu/r4300/UPSTREAM.md` is the authority), PRId 0x2020, 48 TLB
  entries, 16 KB physically indexed D-cache, **8 KB physically indexed
  I-cache** (index bit 12 from the instruction mini-TLB, physical fill index,
  cache op 0x10 translated - docs/47), Config.EC = 0, no clock-domain
  crossing in the memory path. Core clock setup slack +1.981 ns; 34,637
  ALMs (83 %), 379/553 RAM blocks (69 %).
* **Validation of build 25 (all on this bitstream):** `cpuonly` 728/0;
  cpu-tests 2161/3 (`fpu/vec_cvt_from_l` only); whole-machine IRIX sim boot
  clean to 230M cycles, exit device table identical to build 23's; hardware
  cpu-tests **2166/3** (245 tests, PRId/FIR 0x2020, bench identical to build
  24 to the tick: `i_cached` 500 ticks/kinstr, `ld_miss` 13 ticks/load);
  **5 of 5 IRIX 5.3 boots to the login chooser** from pristine disk images
  (`tests/out/hw/irixrate-b25f.log`); `hinv` below.
* **The lesson of docs/47 that changes every future board measurement:** an
  `init died` panic leaves `/etc/ioctl.syscon`, `/var/adm/utmp` and
  `/var/adm/utmpx` zero bytes long, and IRIX's init then dies on them at
  EVERY following boot, on every build (build 25 3/3 and build 24 2/2
  panicked identically on the image left by the 09:17 panic, while the seven
  files init executes were byte-identical to the master). A boot after a
  panic measures nothing. `scripts/irixrate.sh N --tag X --fresh
  /media/fat/games/SGIIndy/SGIIndy53-pristine.img` restores the pristine
  image before every launch (266 s each on the SD card);
  `tools/misterdeploy/irixstate.py` (on the device) reads the kernel's
  `panicstr` and the frame-buffer histogram and says PANIC / X-UP / BOOTING.
  Whether build 24's single panic was the cache or that state is unknowable;
  build 24 was 2/2 clean on pristine images when the user stopped the
  control. If a panic ever recurs on a PRISTINE image: docs/47 §5 (beacon:
  last user-mode exception EPC/BadVAddr/Cause) before touching RTL.
* **Board:** `192.168.99.92` (`scripts/local.env`), build 25 in
  `_Unstable/SGIIndy.rbf`, `boot.rom` restored, `SGIIndy53.img` = a pristine
  copy, `SGIIndy53-pristine.img` beside it (md5 `449d0ba4ae92e80c57c7c760
  986e36f3` = `C:\Temp\mistercore\iris\SGIIndy53-master.img`). Reading
  files off an image: `python3 /media/fat/sgidbg/efsread.py IMG get|cat|ls
  PATH` on the device, `MSYS_NO_PATHCONV=1 python tools/misterdeploy/
  efsread.py` on the host (without it Git Bash turns `/etc` into
  `C:/Program Files/Git/etc`).
* **Still open from docs/46-47, unchanged:** the R4600 patch to the
  cpu-tests suite is UNCOMMITTED in `C:\Temp\mistercore\iris\cpu-tests`
  (`harness/testlib.c`, `tests/identity/identity.c`, `tests/cache/cache.c`);
  the 16 KB two-way I-cache (way by physical bit 13) is a performance
  follow-up only; the sim never reaches "The system is coming up" (sim-only
  device wait); the HDMI black picture is a MiSTer host wedge cured by
  `ssh root@192.168.99.92 reboot`.

## 1. `hinv` on build 25

`scripts/hinv.sh --fresh ... --out tests/out/hw/hinv-b25.txt` (new this
session: boots, waits for the chooser with irixstate.py, parks the pointer
by the docs/45 recipe, types `root`, then `hinv > /hinv.txt` and `init 0`,
and lifts the file off the image with efsread.py). Output:

```
1 50 MHZ IP22 Processor
FPU: MIPS R4600 Floating Point Coprocessor Revision: 2.0
CPU: MIPS R4600 Processor Chip Revision: 2.0
On-board serial ports: 2
On-board bi-directional parallel port
Data cache size: 16 Kbytes
Instruction cache size: 16 Kbytes
Main memory size: 48 Mbytes
Integral ISDN: Basic Rate Interface unit 0, revision 1.0
Integral Ethernet: ec0, version 0
Integral SCSI controller 0: Version WD33C93A
CDROM: unit 6 on SCSI controller 0
Disk drive: unit 1 on SCSI controller 0
Graphics board: Indy 24-bit
Presenter adapter board.
```

Captured 12:42 on 2026-09-08 (`tests/out/hw/hinv-b25.txt`; the login,
the typed line and the halt all landed - `tests/out/hw/hinv-console.png`
shows IRIX's shutdown dialog). What it says, line by line where it matters:

* **"50 MHZ"**: IRIX derives the clock from Count, which ticks at half the
  pipeline clock (`bench/count_rate` 25.0M/s) - the "66 MHz is a
  measurement" note in `docs/FEATURES_EVALUATE.md`. A real Indy R4600 is
  100 or 133 MHz. Cosmetic, unless something scales by it.
* **"WD33C93A"**, not "WD33C93B, revision D" as on a real Indy: IRIX's
  `wd93` driver reads the chip's revision and chooses timing/sync/burst
  behaviour by it. Our `rtl/scsi/wd33c93.sv` identifies as an A. Whether
  the B paths would matter (they enable faster transfer modes) is a
  question for the SCSI work in §3 - check what the driver does
  differently before changing the ID (the PROM has its own opinion:
  `hardware-bug-instrument-first`, "read every consumer").
* **"Integral ISDN ... revision 1.0"**, **"Integral Ethernet: ec0, version
  0"** and **"Presenter adapter board."** are all STUBS answering probes:
  IRIX believes an ISDN unit, a SEEQ Ethernet and an Indy Presenter LCD
  adapter exist. The Ethernet one is what we want once a SEEQ exists; the
  ISDN and Presenter ones are false positives to make honest (the
  Presenter matters most: its presence can change how IRIX programs the
  display timing; the desktop is fine today, so it is not being driven, but
  a "video mode" feature would trip over it).
* **"Graphics board: Indy 24-bit"**: the Newport reports the 24-bit XL
  board while the frame buffer is an 8-bit index plane (that is what
  irixstate.py counts). X runs the 8-bit PseudoColor desktop regardless;
  a 24-bit visual would draw into planes that are not there. Either
  report 8-bit or implement the planes - a decision for the graphics
  follow-up.
* Caches 16 KB / 16 KB: `Config` says so (an R4600 does); the I-cache is
  physically 8 KB, under-reported on purpose (docs/45).

## 2. Hardware a real Indy has that this core does not

Judged from the RTL and the top level (`rtl/sgi/`, `sgiindy.sv`), NOT from
`docs/02-address-map.md`, whose status column is stale (it still calls the
WD33C93 "a 2-register loopback stub"). Ordered by what it would give an
IRIX user.

| Indy (IP24) hardware | In this core | What is missing / what it takes | Value |
|---|---|---|---|
| **HAL2 audio** (Iris Audio Processor, PBUS audio DMA, codec) | `rtl/sgi/hal2.sv` answers `REV` with bit 15 = absent and everything else 0; the PBUS audio DMA descriptors (`HACK_CS`) and PBUS channel 4 are loopback stubs; `AUDIO_L/R = 0` in `sgiindy.sv` | No sound at all. Needs the HAL2 register model (IRIS has one), the HPC3 PBUS DMA descriptor walker for the audio channels (the same descriptor format the SCSI channel already walks in `hpc3_scsi_dma.sv`), a sample FIFO into MiSTer's `AUDIO_L/R` (48 kHz), and the IRIX audio daemon then finds a device. The docs/45 shutdown hang was the audio driver spinning because the device was *half* present - so present it completely or not at all | HIGH: desktop sounds, audio apps, the CD player |
| **SEEQ 8003 Ethernet** + HPC3 enetr/enetx DMA | No SEEQ module; the HPC3 ethernet DMA block is "storage that reads back"; `ec0` comes up down | Needs the SEEQ register model, the two HPC3 descriptor DMA channels, and a packet path out of the FPGA - the MiSTer framework has no generic core Ethernet, so this is host-side work too (an HPS tap through `hps_io`, or a UART-PPP bridge as the cheap version) | HIGH for usability (NFS, telnet, remote X), high cost |
| **Serial ports** (2 x Z8530 channels) | `rtl/sgi/z8530_scc.sv` is real; the PROM console runs on it when Graphics = None; but `UART_TXD` carries only the DEBUG serial (`status[16:15]`), and the guest's tty1/tty2 never reach the MiSTer's USB UART | Route SCC channel A/B TxD/RxD to `UART_TXD/RXD` when no debug mode is selected: a serial console, kermit, SLIP/PPP for the price of a mux | MEDIUM, cheap |
| **RTC** (DS1386) | `rtl/sgi/sgi_ds1386.sv` (RTC + NVRAM) - but the clock is not set from the HPS: every boot prints "time of day clock behind file system time" / "CHECK AND RESET THE DATE" | Load the DS1386 from `hps_io`'s RTC/timestamp at core start (every MiSTer computer core does this) | MEDIUM, cheap |
| **Memory** | 32/48/64 MB by OSD (`status[13:12]`); MC "high local memory" above 0x20000000 exists | An Indy takes 256 MB; 128 MB would need the DDR3 window widened (`ddr3_mux.sv`, 64 MB region) | LOW-MEDIUM |
| **Newport XL graphics** | 8-bit XL: REX3, VC2, 2 x XMAP9, 2 x CMAP, BT445, cursor, VDMA - works to the desktop | 24-bit XL variant (more planes, the 24-bit visual X uses for imaging) absent; output is a fixed 1280x1024 through the scaler | LOW-MEDIUM |
| **CD-ROM audio** (CD-DA through the SCSI CD) | `rtl/scsi/cd_audio.sv` exists from the Mac lineage; `docs/FEATURES_EVALUATE.md` says deferred, the CD is built without it | Wire the audio engine's output - it needs `AUDIO_L/R`, i.e. the HAL2 work above or a direct path | LOW (until HAL2 exists) |
| **Parallel port** (PBUS channel) | stubs | Nothing IRIX needs to boot; a printer port | LOW |
| **VINO video input + IndyCam** | absent, not decoded | A full capture engine; no source on a MiSTer | NONE |
| **ISDN** (Integral ISDN BRI) | absent - but `hinv` REPORTS one ("revision 1.0"): a stub answers its probe | Make the probe fail honestly (bus error / absent ack at its address); nothing to connect a real one to | NONE (fix the false positive) |
| **Indy Presenter** LCD adapter | absent - but `hinv` reports "Presenter adapter board.": a stub answers its probe | Same: make the probe fail. Its presence can change how IRIX programs display timing, which any "video mode" feature would trip over | fix the false positive |
| **GIO64 expansion slots** | absent (IRIX probes 0x1F400000/0x1F600000 and gets the absent ack) | Only if a GIO card (e.g. a second SCSI, 100BaseT) were ever modelled | NONE |
| Second WD33C93 (Indigo2 only), EISA (Indigo2 only) | absent | Not Indy hardware | - |
| **L2 cache** | none (an R4600PC) | An R4600SC's 512 KB L2 is what a real 100 MHz Indy ships with; our miss cost is the DDR3 round trip (docs/39) | performance only |

Present and real, for the record: R4600 CPU + FPU, MC (incl. the GIO DMA
memory-clear engine), HPC3 with the SCSI DMA channel, INT2/IOC, PIT8254
timers, i8042 PS/2 keyboard and mouse, EEPROM 93C56, WD33C93B with two
disks and an ISO/CHD CD-ROM, Newport 8-bit XL, the PROM.

## 3. The MacQuadra800 SCSI work, and what transfers

`C:\Temp\mistercore\MacQuadra800_MiSTer` (tip `c1f4cb2`), `rtl/scsi_cache.sv`
(602 lines) + `docs/scsi-block-cache.md` + `verilator/tb_scsi_cache.sv`,
2026-09-03 .. 09-08, branch `work/cache`, wired in on 2026-09-07.

**What they built:** a per-target read-ahead / write-behind block cache
between the 53C96 engine and `hps_io`, one true-dual-port M10K array
(64 + 48 + 16 sectors = 64 KB), each slot owning ONE contiguous LBA window
with `valid`/`dirty` bitmaps (a buffer around the current position, not a
general cache: sequential traffic runs from RAM, random access degrades to
one round trip per sector). Platform-side transactions serialised as demand
miss > dirty flush > prefetch (8 sectors ahead). **Multi-block platform
transactions**: `sd_blk_cnt` set so a demand miss or a prefetch fetches an
aligned 8-sector group in ONE transaction and a wholly dirty group flushes as
one 8-block write - "each transaction costs a full Main_MiSTer main-loop
pass, which is the real per-sector price; the SPI transfer is the small
term". Coherency rules are documented (re-base after flush-all, same-sector
hazards from registered state, mount-size invalidation, reset survives dirty
data). Bench: 32 sequential reads in 7 transactions, 64 writes in 8; 237,583
checks. It also removed a deadlock class: the engine acks a write from block
RAM in ~25 us and the flush happens behind it, so no platform transfer is
ever outstanding across a target switch. Cost: 64 M10Ks + two small state
machines; the CD slot can pass through (`CACHE_CD=0`) to save 250 ALMs and
16 M10Ks. The CD's multi-block path needs their Main_MiSTer FORK; the disks'
does not (stock `hps_io` honours `sd_blk_cnt`, up to 16 KB per transaction).

**What this core has today** (`rtl/scsi/sgi_scsi.sv` + `scsi.v`, the same
MacLC-lineage target): a 32-sector READ ring inside a command (`RING_LOG=5`,
16 KB per target, fetched one sector per HPS transaction - `sd_blk_cnt` is
not connected in `sgiindy.sv`, so every transaction is one 512-byte sector),
nothing across commands, and WRITES on the original two-slot double buffer:
one HPS write per sector, each waiting for the SD card (images are opened
O_SYNC, so a card housekeeping pause lands on the guest). The
`sd_buff_addr_hi` plumbing for wider transfers already exists for the CD's
whole-frame bursts. The HPC3 SCSI DMA descriptor walker is ours
(`hpc3_scsi_dma.sv`), the initiator is a WD33C93 rather than a 53C96, but
the engine/HPS contract is the SAME `io_lba/io_rd/io_wr/io_ack/sd_buff_*`
that `scsi_cache.sv` sits on - the cache would go between the per-target
`t_*` signals and the `sd_*` ports in `sgi_scsi.sv`, with `scsi.v`
untouched, exactly as `ncr53c96.sv` stayed untouched over there.

**Where IRIX pays:** fsck (a dirty root is thousands of sequential reads
and writes), the install, swapping, and every EFS metadata write (sync).
A pristine boot is 270 s to the login chooser on the board; how much of
that is disk is NOT measured - measure before promising a number.

**The plan, ordered by value over cost** (`hardware-bug-instrument-first`:
measure, then change):

1. **Measure.** The SCSI beacon (`sgiindy.sv` `bcn_src`, decoder
   `bcnread.py` w1/w2) already carries sd_rd/sd_wr/sd_ack counters. Add:
   transactions per boot and total cycles with `sd_rd|sd_wr` outstanding,
   read every 20 s by `irixstate.py` during a fresh boot. That gives "disk
   seconds per boot" - the ceiling of any cache.
2. **Multi-block reads in the existing ring** (small): let the ring fetcher
   issue `sd_blk_cnt = 7` (8 sectors, 4 KB) per transaction when 8 or more
   sectors are wanted, consuming 2048 words through `sd_buff_addr` +
   `sd_buff_addr_hi`. 8x fewer main-loop passes on sequential reads; no new
   RAM; the ring's fill accounting (`rd_hps_blk`, `rd_ahead_blk`) is the
   only logic that changes. Gate: the SCSI bench (`-fno-gate` build of
   `sgi_scsi`), the whole-machine IRIX sim boot, `irixrate.sh --fresh 5`.
3. **Write-behind: port `scsi_cache.sv`** between `sgi_scsi.sv` and
   `hps_io` (medium): take the file and its bench nearly verbatim, sizes
   64/64/16 sectors, `CACHE_CD=0` at first (the CD reads through the
   existing ring). Fits: 379/553 RAM blocks used, 83 % ALMs. Its
   write-behind is what turns IRIX's per-sector O_SYNC waits into one
   8-block flush per 4 KB. Check first that `scsi.v` answers SYNCHRONIZE
   CACHE (0x35) and that the WD33C93 target switch cannot leave a flush
   outstanding on the old target (their deadlock class) - the cache removes
   it anyway.
4. Skip their Main fork (`MB_CD`); the CD stays single-sector.

What does NOT transfer: their 53C96 PDMA fixes, the Mac ROM driver
behaviours (MODE SENSE page $30, the Apple firmware ID page), the AUX/NetBSD
expectations - all initiator-side or Mac-side.

## 4. Recipes (self-contained)

* Board: `scripts/deploy.sh --rbf F [--no-launch]`, `scripts/irixrate.sh N
  --tag X --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img`,
  `scripts/hinv.sh --fresh ...`, `scripts/screen.sh NAME --mode grey --full
  --scale 0.4` (frame buffer to PNG), `tests/run-cputest-hw.sh --no-build`
  (the R4600-aware `tests/out/hw-cputest/boot.rom`, md5 `964d3ce5...`;
  restores the PROM itself). Long board runs: launch detached via
  `Invoke-CimMethod Win32_Process Create` with `</dev/null >X.console 2>&1`
  and watch the log; never `Stop-Process` on a pattern that matches your
  own shell (it did, twice).
* Sim (WSL, native FS `~/kicpu`): rsync `rtl tools verilator` (exclude
  `generated`), de-CRLF, `/tmp/llvmshim`, `bash tools/gen_r4300_verilog.sh`,
  `make -C verilator cpuonly` (NO `-j 0` - this make rejects it),
  `make -C verilator cputest`; cpu-tests from `~/cputests`; the IRIX boot
  as in `~/kicpu/gate2.sh` (230M cycles, `--stop-on PANIC`, ~30 min).
  Variables inside a `wsl -- bash -c '...'` string are eaten: literal paths.
* Fit: `SEED=2 bash scripts/fit_when_free.sh bNN` detached; ~25 min when
  Quartus is free; `git checkout -- sgiindy.qsf` after.
* Auto-memory to read first: `ki-revendor-wip`, `irix-r4600-colours-one-bit`,
  `hardware-bug-instrument-first`, `github-push-https`, `local-toolchain`,
  `indy-desktop-input-recipe`, `scsi-fsck-transfer-count-livelock`.
