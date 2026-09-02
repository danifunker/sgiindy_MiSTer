# Work item: Ethernet, CPU throughput, and the rest of the video stack

Paste everything below the line as the opening message of a fresh session.
This follows [33-newport-vdma.md](33-newport-vdma.md) (the Newport pixel-DMA
black screen and the three display bugs behind it, all FIXED and verified on
the board). Written 2026-09-02.

---

## STATE AT HANDOFF (read this first)

* **The board runs build 15 (beacon ver=7) and boots IRIX 5.3 to a
  pixel-correct X login screen on the monitor** - verified against a live
  IRIS boot of the same disk image. HEAD is `0776072`; every commit is
  fitted, deployed, and confirmed. Timing is fully positive (+0.404 ns).
* docs/33 tells the whole four-round video story: the MC VDMA engine
  (mem->GIO + µTLB + LOCAL0-bit-4 interrupt + MC->Newport path), the
  VRINT-latch-not-level retrace interrupt, the VC2 DID table walker +
  per-pixel mode decode, and FASTCLEAR + the CID clip. Do not reopen any
  of it; the regression suite that guards it is listed under Instruments.
* **Nobody has ever LOGGED IN.** The login screen sits there correct and
  idle (a 100-sample beacon PC profile shows ~95% `wait_for_interrupt` +
  `idle` - no parasitic load). The first desktop session is where the next
  video bugs will surface.
* Read the auto-memory notes before doing anything: `newport-vdma-pixel-path`
  (the display architecture and every trap paid for this week),
  `hardware-bug-instrument-first`, `local-toolchain`,
  `verilator-whole-machine`, `iris-oracle-local`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly.** The reference emulator IRIS is `C:\Temp\mistercore\iris` - and
this week it graduated from "code oracle" to "live oracle": you can BOOT
THE SAME DISK IMAGE in it beside the board and diff device state
(iris-ci + snapshot parsing; recipe in the memory note and docs/33 round
four). A fit is ~40 minutes - instrument first, bundle diagnostics with
fixes, sim-verify before every fit.

## The queue

Work these in order unless evidence reorders them.

### 1. Log in and shake down the desktop (video, correctness)

Nobody has pressed a key yet. Log in as `guest` or `root` (keyboard goes
through i8042 -> the MAP_STAT interrupt path; both are wired but barely
exercised). The 4Dwm desktop will exercise, for the first time:

* **SCR2SCR copies** (window moves, scrolling) - the engine path exists
  and passed the PROM replay, but X's octant/overlap cases are richer;
* **the CID clip with real occlusion** - implemented this week
  (np_rex3.sv, IRIS's process_pixel_draw semantics), never seen a real
  overlapping-window workload;
* **popup planes** (menus) and overlay planes - the display decode is in,
  the DRAW side of aux planes is PROM-tested only;
* **VDMA reads** (mode 0x52, GIO->mem) - engine-tested and REX3-tested in
  sim, never observed live.

Screenshot BOTH ways at every step: `fbgrab.py`+`fbpng.py` (framebuffer
content) and `scripts/grab.sh` (what the monitor shows). They diverge on
different bug classes - that split is the whole lesson of docs/33.

### 2. CPU / system throughput ("it feels more sluggish than it should")

The user's read is right and the question is open. What is KNOWN:

* The PROM's "16 Mhz R4400" is **uncached** instruction throughput (KSEG1
  fetch per instruction over the bus; docs/10 "What it did not buy") - it
  says nothing about the cached path the kernel actually runs on.
  **The cached throughput has never been measured on the board.**
* The idle profile is clean (95% idle loop), so the sluggishness is in
  the working path, not a storm.
* Structural suspects, in likely order of damage:
  - **No L2 cache.** A real Indy R4400 has 1 MB of it and IRIX 5.3 leans
    on it; here every L1 miss is a full DDR3 round trip (tens of cycles
    at 50 MHz). The L1s are 16K each, direct-mapped, real.
  - **Store path**: check whether r4300_wrap's D-cache is write-through
    without a write buffer - if every kernel store is a bus transaction,
    that alone explains "weirdly sluggish". Read the wrap, then measure.
  - **CP0 Count rate vs wall clock**: IRIX calibrates DELAY() and its
    timers from Count. If Count ticks at a rate mismatched to real time,
    every kernel delay loop stretches. Verify Count Hz on the board
    against the RTC (`guestmem` two samples of a known Count-derived
    kernel variable, or a cpu-test).
* HOW to measure, instrument-first:
  - `tests/run-cputest-hw.sh` / `tests/hw-cputest` - the bare-metal CPU
    test harness that boots as boot.rom. Add a cached-loop benchmark
    (same shape as the PROM's, in KSEG0) and a store benchmark; run on
    the board without touching the core. That gives real IPC numbers in
    one deploy, no fit.
  - The beacon PC profiler (100x `bcnread.py` + `ecoffsyms.py` mapping)
    during a DRAWING workload (drag a window, hold a key) - if the time
    goes to the rasteriser wait loops rather than the CPU, the fix is
    video-side, not CPU-side.
  - `dbg_retire` exists on the CPU debug bus - a retire-rate counter in
    a beacon word is a one-fit instrument for live IPC if needed.
* Fixes are a separate decision after the numbers exist. Candidates:
  a write buffer, an L2 (block-RAM victim cache?), wider refill bursts.

### 3. Ethernet, properly

IRIX configures ec0 unconditionally (Indy's Seeq 8003 is integral) and
the boot burns 2+ minutes on no-carrier timeouts. There is NO Seeq model
in the RTL - `sgi_hpc3.sv` holds the enetr/enetx DMA register windows as
storage only, and INT2 L0 bit 3 (Ethernet) is hardwired 0.

* **Oracle: IRIS `src/seeq8003.rs`** plus its HPC3 ethernet DMA handling
  (hpc3.rs) - IRIX 5.3 networking works under IRIS, so the register/DMA
  contract is all there. The if_ec driver in /unix disassembles the same
  way wd93/ng1 did when questions arise.
* Shape of the work: Seeq 8003 MAC registers + RX/TX rings through HPC3's
  enetr/enetx descriptor DMA (the descriptor walker pattern already
  exists in hpc3_scsi_dma.sv), ethernet interrupt on L0 bit 3, and a
  **host-side packet path**: the natural MiSTer design is an ARM-side
  bridge daemon moving frames through a DDR3 mailbox ring (the beacon
  proved the DDR3-window channel; `ddr3_peek.py` is the read side and the
  core already has a lowest-priority writer to copy). Bridge to the
  MiSTer's own network with a raw socket on the ARM.
* The MAC address already flows: `mac_addr` -> eeprom/NVRAM -> PROM
  `eaddr` (sgiindy.sv ioctl 0x40 path).
* First milestone is honest carrier + working `ping` from IRIX; NFS and
  the rest ride on that. Even the carrier alone kills the boot timeouts.

### 4. Video, remainder (performance then fidelity)

* **~14 Hz refresh is the single most visible slowness.** PIX_DIV=2 in
  newport.sv exists because the display fetches EIGHT bytes per pixel
  and uses one (fb_linecache.sv header, docs/18). Fetch-width fix ->
  PIX_DIV=1 -> ~27 Hz. This is the highest-payoff video project.
* **Rasteriser speed**: one pixel per DDR3 round trip. A span cache /
  burst-fill path (accumulate a 64-bit word = 8 CI pixels per write,
  burst spans) would cut X fills by ~8x. DR_FILL is the place.
* Fidelity leftovers, roughly in order a desktop will hit them: BT445
  gamma LUT (display currently bypasses it), DRAWMODE1 swapendian +
  24bpp direct byte-order (identity now, verify against IRIS with a
  TrueColor client), line address modes + stipple (xterm underlines,
  wm decorations may use them), colour DDAs / shading + blending +
  dither (GL demos), double-buffer switching (buf_sel is decoded in
  display and extraction, DBLSRC draw side untested).
* The sim harness for all of it: `verilator/sim_video_cap.h` captures
  video output; tests/run-rex3.sh replays per-pixel; tb_rex3/tb_vc2 hold
  the unit fixtures (FASTCLEAR/CID/DMA/DID phases added this week).

### 5. SCSI leftovers (docs/29, unchanged)

* CD-ROM `cmd=0xc9` CDB-length disagreement - fix shape per docs/29:
  raise 0x87 UNKNOWN_GROUP for vendor groups in SAT mode in wd33c93.sv,
  plus a mid-CDB timeout in scsi.v. Both consumers (PROM + IRIX) must be
  read first - this is the ASR-bit-5 lesson's territory.
* `sd_lba` last-match-wins mux in sgi_scsi.sv.
* 64-bit CPU PIO stores to REX3 drop a half (newport.sv takes one word).
  Nothing issues them today; fix when something does.

### 6. Housekeeping that pays for itself

* **Stop power-cutting the guest.** Every deploy hard-cuts IRIX, every
  boot then fscks a dirty 2 GB EFS for 5-10 minutes. Log in and
  `shutdown -y -g0` (or `init 0`) before redeploying, or keep a cleanly
  unmounted image copy to restore. This is minutes back on every cycle.
* The wedged-fsck reproducer is gone (repaired); `SGIIndy53.img` is the
  pristine copy, `SGIIndy53-wedged-fsck.img` is the current boots-fine
  board image.

## Instruments (all present, all proven this week)

* `bcnread.py` (ver=7, 15 words) - VDMA words 11-13, display word 14
  (DID + mode entry in use), CPU PC word 10. **Re-push after any edit;
  the board copy goes stale silently.** 100 samples + `ecoffsyms.py` =
  a statistical profiler (caught the retrace storm; proved idle clean).
* **The live IRIS oracle**: boot the same image beside the board
  (`iris.exe --config ... --ci --ci-display`, iris-ci boot/screenshot/
  save), parse `saves/<name>/rex3.bin` for cmap/mode/vc2-ram as hex
  tokens. Traps: CI overlay mode hardcodes /tmp (absent on Windows -
  use a disposable image COPY); `screenshot` takes a POSITIONAL path
  and its rgba can lag - PrintWindow-capture the iris window instead.
* `fbgrab.py`+`fbpng.py` (framebuffer) vs `scripts/grab.sh` (monitor) -
  ALWAYS check both; they split every display bug into halves.
* `efsread.py` / `ecoffsyms.py` / `disbin.py` - the guest's own binaries
  answer register contracts for free (/unix has if_ec for Ethernet).
* Sim: `make -C verilator mcdmatest | rex3test | vc2test` (unit, seconds)
  and `tests/run-rex3.sh` (whole-boot per-pixel replay, ~15 min; run via
  an LF copy - the .sh files are CRLF and die under WSL bash).
* `scripts/build.sh` detached via the Invoke-CimMethod recipe
  (local-toolchain memory); `scripts/deploy.sh`; `scripts/setopt.sh`
  writes OSD options without the OSD (viddbg=raw is the palette-bypass
  view).

## Traps already paid for (do not re-pay)

* Everything in docs/32's list still applies (fits ~40 min, db/ cleanup,
  no qsf edits mid-compile, no Verilator during fits, Invoke-CimMethod).
* Verilator: -O1+ dies on this design; WM_OPT is the working flag set
  and cputest-rex3-debug now uses it. `rtl/cpu/generated/r4300_wrap.v`
  is gitignored - copy/regenerate before whole-machine builds.
* Beacon display-word samples include BLANKING (~30% of wall time, where
  the DID walker parks on the line's first run) - never infer region
  sizes from sample frequencies alone.
* The PROM runs all real draws at cidmatch=0xF; CLIPMODE=0 means
  cidmatch=0 which GATES on aux==0 - that is correct (IRIS does it) but
  remember it when staring at a draw that skips.
* IRIX unmasks the retrace interrupt at gfx init; any INT2 line must be
  retirable by its ISR or the machine starves (docs/33 round two).
