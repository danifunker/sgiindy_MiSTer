# Work item: verify build 18 on the board, then the CD-ROM attach, the burst fill path, the R4600 swap, Ethernet

Paste everything below the line as the opening message of a fresh session.
This follows [36-scsi-fit-fb-relayout.md](36-scsi-fit-fb-relayout.md), the
session of 2026-09-02 that landed the docs/29 SCSI fixes on the board,
relaid the frame buffer to four bytes a pixel with `PIX_DIV=1`, found and
fixed the desktop "shutdown hang" (the kdsp_a2 audio driver), and mapped the
next SCSI problem (IRIX never attaches the CD-ROM). Written 2026-09-02.

---

## STATE AT HANDOFF (read this first)

* **`main` is at `f5ffc82` or later** (four commits from this session, in
  order: `4a6c8ee` ws_send shifted keys, `52f24ef` the frame buffer
  relayout, `30bab9e` HAL2 reports no audio, `f5ffc82` the display fetch
  path fixes). Check `git log` for a fifth: the build-18 result commit, if
  the session got that far. The user pushes from his own environment.
* **Build 18 = all four commits, fitted from `f5ffc82`.** Its board result
  is at the END of docs/36 if the session reached it; if that section is
  missing, the FIRST job is to deploy `output_files/sgiindy.rbf` (md5 in
  `b18.console`/`b18.log` in the main checkout) and verify:
  - the chooser renders at `PIX_DIV=1` (the refresh should be ~27 Hz);
  - `bcnread.py` word 15 (`lcache:`): `rgb_miss`/`aux_miss` must be SMALL
    AND STABLE between samples (the 16-bit counters wrap - a random-looking
    value that changes each sample means every pixel misses), `aux_skips`
    climbing by ~1024 a frame on a bare desktop;
  - root login, then the toolchest System menu (popup planes = the aux
    cache's flag path) and a window drag (SCR2SCR);
  - System Shutdown from the toolchest must NOT freeze the desktop any more
    (docs/36 section 3b), and hinv must print no audio line;
  - `init 0` from the root console before any redeploy (docs/36 section 3
    has the input recipe; the image fscks 5-10 min after every power-cut).
* **Build 16 (the SCSI fixes alone) is verified on the board:** zero
  `cmd=0xc9` timeouts, zero bus resets, zero SYNC-negotiation notices in a
  boot's SYSLOG. Build 17 (relayout, first cut) was a black screen for three
  fetch-path bugs that `tb_fetcharb` now covers - never fit anything in
  `rtl/mister/` without `make -C verilator fetcharbtest linecachetest`.
* Read the auto-memory notes first: `display-fetch-path-board-only`,
  `shutdown-hang-kdsp-audio`, `mister-main-death-instruments`,
  `indy-desktop-input-recipe`, plus the older `cpu-throughput-measured`,
  `newport-vdma-pixel-path`, `hardware-bug-instrument-first`,
  `local-toolchain`, `verilator-whole-machine`, `iris-oracle-local`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly** (a session may start in a worktree on a `claude/*` branch: commit
there, then `git -C C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only
<branch>`; fits run from the main checkout). The reference emulator IRIS is
`C:\Temp\mistercore\iris`. A fit is ~40 minutes - and TWO fits on this box at
once died silently twice today; check `tasklist | grep quartus` and do not
kill anyone else's. The board is a SuperStation1 (not a DE10-Nano); its
MiSTer binary is a fork.

## The queue

### 1. Verify build 18 (above) and close docs/36 with the numbers

### 2. IRIX does not attach the CD-ROM (the CD install blocker)

`hinv -c disk` lists no CD-ROM, `/CDROM` is empty, and the beacon's last
command to ID 6 after INQUIRY (alloc 64, 54 returned) is a 12-byte MODE
SELECT - READ CAPACITY is never issued. Same on builds 15 and 16, so it is
not the docs/29 fixes. Ruled out: the kernel's `cdrom_inquiry_test`
(substring match for CDROM/CD-ROM/CD ROM; ours passes). Leads, in order:

* Simulate dksc's attach sequence in `tests/scsiwr` (INQUIRY alloc 64,
  MODE SELECT(6) with the 8-byte block descriptor setting 512-byte blocks,
  then whatever the kernel sends next) and look at the completion status
  the initiator reports for the MODE SELECT - `917dce7`'s S_DISCONNECT
  (0x85) on ST_SAT_END is a candidate if the target goes bus-free early.
* Disassemble `dkscinit` (0x880aad10) / `dksc_unit` (0x880ae4f0) in
  `unix.ecoff` (`ecoffsyms.py`, `disbin.py`) for what it expects after MODE
  SELECT; compare with IRIS (`src/scsi.rs`: Sony CDU-76S, 36-byte INQUIRY,
  `exec_mode_select_6` switching the block size).
* Do NOT probe with `scsicontrol` from the guest until the audio driver is
  gone (build 18): the console bell froze the kernel, not the SCSI path.

### 3. Rasteriser fill speed: a burst-WRITE path

DR_FILL is still one pixel per `fbw` transaction, tens of cycles each. With
two pixels to a 64-bit word a span cache can emit one write per pair, and a
burst-write port on `ddr3_mux` (the `fbr` burst port is read-only) would
make a span one bridge transaction. `tb_rex3` (`REX3_ACK_DELAY=40`) is the
gate; `run-rex3` the replay check. Beacon word 13 counts REX3 beats.

### 4. CPU: the R4600 from Killer Instinct (docs/35 item 4, scoped)

`rtl/cpu/r4300/` is the vendored N64 R4300i with ~20 `-- SGI:` changes
(UPSTREAM.md). Killer Instinct's `rtl/cpu/cpu.vhd` has the IDENTICAL
`mem_*`/`rdram`/`ddr3_DOUT`/`SS_*` port set (plus generics: `LITTLE_ENDIAN`
false by default, `ADDR32_ONLY`, ...), `irqRequest(1:0)` where ours has
`irqLines(4:0)`, and a `debug_*` set instead of our nine `dbg_*`. Its caches
fill 32-byte lines over 512 lines (16 KB); the 2-way claim needs the tag
compare read; PRId 0x2020. So `r4300_wrap.vhd`/`r4300_bus.sv` carry over and
the work is porting the SGI change list onto the KI files, then `make -C
verilator cpuonly` (364 checks) and `tests/run-cputest.sh` as the gate, then
the `bench` group on the board (`cpu-throughput-measured`: 36 cycles per
L1 miss is the number to beat).

### 5. Ethernet (docs/35 item 5, unchanged)

Honest carrier first: Seeq 8003 at HPC3 0x54000 is an unclaimed hole;
`ec_watchdog` reads 80C03 read-mode reg 5 NO_CARRIER. Then the RX/TX rings.

### 6. Audio, eventually

HAL2 reports "absent" (bit 15) because the kdsp_a2 driver wedges on a HAL2
with no DMA engine. Real audio = the HPC3 PBUS DMA channel + a sample
pipeline; only then clear bit 15 again. `run-scsi`/`run-cdrom` stop on the
`cdrom(6)` hinv line now.

## Instruments (all present, all proven this session)

* `bcnread.py` ver=8 (16 words); word 15 = `lcache:` (docs/36).
* `tb_fetcharb` (two caches + arbiter vs a mux-like bridge), `tb_linecache`
  (flag table), `tb_rex3` (per-byte write tracking, the window-ID copy).
* Kernel forensics at zero fit cost: beacon PC -> `ecoffsyms.py unix.ecoff
  syms` (K0) or, for K2 addresses, `kptbl` (K0 0x881ec000) entry -> PFN ->
  `guestmem.py` -> `disbin.py`, then byte-search the module .o pulled with
  `efsread.py` (`/usr/cpu/sysgen/IP22boot/`).
* The framework: `gdb -p $(pidof MiSTer) -batch -ex "bt 8"`; its stdout in
  `/tmp/mister_stdout.log` after the dup2 trick (survives `load_core`, not
  a reboot); `mwatch.sh` (scratchpad of this session - recreate from
  docs/36 if gone).
* Input: root login is `text:root` + Enter at the chooser; `xset m 0 0` in
  the console; ≤ 40 px mouse steps; `ws_send.py` types shifted keys.
* `fbgrab.py` (tracked now, 4 B/px) + `fbpng.py`; `fb_poke.py` zeroes the
  aux region; `scripts/grab.sh` for the monitor. Always both.
* `postfit.sh` pattern (scratchpad): `deploy.sh --no-launch`, push tools,
  `mount.sh` to launch through `/dev/MiSTer_cmd`.

## Traps paid for this session (do not re-pay)

* Everything in docs/35's list still applies.
* The whole-machine sim never runs the display fetch path; `fetcharbtest`
  does. Beacon miss counters wrap.
* `ddr3_mux` latches a burst request when first seen: anything in front of
  its `fbr` port must hold a stable address/burst until `fbr_taken`.
* Two Quartus fits at once on this box: two silent fitter deaths in a row.
  The recovery is `mv db db.crashed-*` (deleting in the main checkout is
  refused by the tool permission layer when running from a worktree).
* A garbled console line (an `ec0` ALERT printed mid-typing) can ring the
  bell; on builds ≤ 17 that froze the kernel (audio). Type short lines.
* `text:` steps typed at the chooser before its field exists are lost -
  screenshot first, then type.
