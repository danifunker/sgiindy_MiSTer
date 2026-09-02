# Work item: land the SCSI fit, then video perf, desktop input, the R4600 CPU swap, and Ethernet

Paste everything below the line as the opening message of a fresh session.
This follows [34-resume-net-cpu-video.md](34-resume-net-cpu-video.md). The
session that wrote this verified and committed the docs/29 SCSI leftovers,
MEASURED the CPU throughput on the board (the sluggishness question is now
answered with data), shook down the first-ever desktop login, and mapped the
Ethernet contract. Written 2026-09-02.

---

## STATE AT HANDOFF (read this first)

* **The board runs build 15 (beacon ver=7) and boots IRIX 5.3 to the X login
  chooser on the monitor** - the full per-user icon panel (root, guest, demos,
  4Dgifts, user), rendered cleanly. Timing was +0.404 ns at build 15. The
  desktop was logged into for the first time this session (guest): 4Dwm, the
  toolchest, the Console overlapping the Icon Catalog with **correct occlusion**
  (the CID clip with real occlusion - this week's new draw path - confirmed
  live). Do not reopen the docs/33 video work.

* **THE TWO COMMITS BELOW ARE NOT ON MAIN AND NOT ON THE BOARD.** They live on
  branch `claude/modest-robinson-cad59e` (a worktree this session ran in),
  which is `main` + 2, linear and fast-forwardable. **Before anything else,
  get them onto `main`** (`git checkout main && git merge --ff-only
  claude/modest-robinson-cad59e`, or cherry-pick the two SHAs). Then fit.
  - `917dce7` scsi: the docs/29 leftovers (per-target sd_lba/sd_buff_din, the
    mid-CDB timeout, S_UNKNOWN_GROUP 0x87, the S_DISCONNECT 0x85 status).
    **Sim-verified: `run-scsi`, `run-scsiwr` (ALL PASS), `run-cdrom` all pass.**
    Never fitted.
  - `7123efb` hw-cputest: the CPU throughput `bench` group. A boot.rom test,
    already run on the board - no core change, no fit needed for it.

* **The CPU sluggishness question is ANSWERED** (auto-memory
  `cpu-throughput-measured`, read it): the whole cost is the **L1 miss with no
  L2 - 36 CPU cycles (~720 ns) per miss**, every miss a full DDR3 round trip,
  on a working set far bigger than the 32 KB of L1. Count rate (25 MHz = CPU/2)
  is CORRECT and the cached path is healthy (1.0 CPI ALU, 1.0 CPI hitting
  store) - the store-path and Count-rate suspects are RULED OUT. This is why
  the CPU item is now a real swap (item 4), not a tuning pass.

* Read the auto-memory notes before doing anything: `cpu-throughput-measured`
  (new), `newport-vdma-pixel-path`, `hardware-bug-instrument-first`,
  `local-toolchain`, `verilator-whole-machine`, `iris-oracle-local`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly.** The reference emulator IRIS is `C:\Temp\mistercore\iris` (live
oracle: boot the same disk image beside the board, iris-ci + snapshot parsing;
recipe in docs/33 round four and the memory note). A fit is ~40 minutes -
instrument first, bundle diagnostics with fixes, sim-verify before every fit.

## The queue (REORDERED 2026-09-02 at the user's request)

Work these in order unless evidence reorders them.

### 1. Land the SCSI fit - FIRST ACTION

The four docs/29 SCSI fixes are committed and sim-verified but have never run
on hardware. Fit HEAD (after merging to main), deploy, and confirm on the
board:

* **Sim-verify first, no excuses:** `make -C verilator cputest` then the three
  ratchets (`run-scsi`, `run-scsiwr`, `run-cdrom`) via LF copies. They passed
  at `7123efb`; a green re-run is the pre-fit gate. NOTE: `cputest` now builds
  with **WM_OPT, not -O3** (the per-target sd_lba/sd_buff_din arrays tipped -O3
  into the no-location Verilator 5.020 fault - see Traps); ~2x slower build,
  same model.
* **Fit** via the detached `scripts/build.sh` (Invoke-CimMethod recipe,
  `local-toolchain` memory). Confirm timing stays positive.
* **Deploy and board-verify.** The payoffs are the CD-install disk/CD
  collision (per-target lba) and IRIX's vendor `0xc9` to the CD-ROM. Minimum
  bar: IRIX still boots to the login chooser with no new SCSI errors. Real
  bar: exercise the CD-ROM (a CD install, or at least `hinv`/mount of the ISO)
  and watch for `cmd=0xc9 timeout` / `Resetting SCSI bus` - which should be
  GONE from the CD path. The `run-scsiwr` sim already proves the mechanics
  (disk WRITE(6/10) interleaved with CD READ(10)); the board proves it live.
* **Do NOT expect the fit to silence** `NOTICE: wd93 SCSI Bus=0 ID=1: SYNC
  negotiation error, resetting bus` at IRIX boot. That is a SEPARATE,
  pre-existing, non-fatal issue (the IRIX kernel driver's sync negotiation
  with the disk, distinct from the PROM path the ratchets cover; IRIX falls
  back to async and boots fine). It has been present since build 15 and these
  fixes do not touch it. It is a candidate for a LATER look, not a fit
  acceptance criterion.

### 2. Video performance (highest-visible-payoff)

* **~14 Hz refresh is the single most visible slowness.** PIX_DIV=2 in
  newport.sv exists because the display fetches EIGHT bytes per pixel and uses
  one (fb_linecache.sv header, docs/18). Fetch-width fix -> PIX_DIV=1 ->
  ~27 Hz. Highest-payoff video project.
* **Rasteriser speed**: one pixel per DDR3 round trip. A span cache / burst-fill
  path (accumulate a 64-bit word = 8 CI pixels per write, burst spans) would
  cut X fills by ~8x. DR_FILL is the place.
* Sim harness: `verilator/sim_video_cap.h`, `tests/run-rex3.sh` (per-pixel
  replay, ~15 min via an LF copy), tb_rex3/tb_vc2.
* Fidelity leftovers, roughly in desktop-hit order: BT445 gamma LUT (bypassed),
  DRAWMODE1 swapendian + 24bpp byte order, line address modes + stipple,
  colour DDAs / shading + blending + dither, double-buffer switching (DBLSRC
  draw side untested). Verify each against IRIS.

### 3. Desktop drag/menu tests (finish the shakedown)

The overlap/occlusion path is confirmed, but two desktop DRAW paths stayed
unverified this session because the input tooling could not place the pointer:

* **SCR2SCR copies** (window moves, scrolling) and **popup planes** (menus,
  overlay) - never exercised by a real overlapping-window workload.
* **The blocker is input, not the core.** `ws_send.py`'s mouse is
  RELATIVE-only, the guest applies velocity-dependent X11 acceleration
  (measured ~1.9x on sustained X moves, ~0.8x on Y, and it drifts), and the
  8-bit delta path WRAPS above ~127 - so blind pointer targeting is
  unreliable and the cursor repeatedly shot off-screen. **Fix the tooling
  first**: either (a) reach a shell and `xset m 0 0` to kill mouse
  acceleration, then relative deltas are 1:1; or (b) add absolute pointer
  warping (XWarpPointer via a tiny guest helper, or an `mousePos:`-style
  path the guest honours). Keyboard delivery works (the guest login proved
  it); pointer focus is 4Dwm pointer-focus, so keys need the pointer parked
  over the target window. Screenshot BOTH ways (`fbgrab`+`fbpng` framebuffer
  vs `scripts/grab.sh` monitor) at every step.

### 4. CPU: swap the R4300i-derived core for the R4600 from Killer Instinct

The measurement (item under STATE) says the CPU core itself is fine on the
cached path but the L1-miss-with-no-L2 penalty is the whole slowness. The
current CPU is `rtl/cpu/r4300_wrap.vhd` - an R4300i-derived core PRESENTING as
R4400 (PRId 0x440), with **16 KB / 16 KB DIRECT-MAPPED, 16-byte-line** L1s.
The user wants to move to the **R4600 core used in
`MiSTer-devel/Arcade-KillerInstinct_MiSTer`** (Robert Peip / FPGAzumSpass).

* **Why it fits the measured problem AND accuracy.** The Indy shipped in
  R4400 AND R4600 variants, and **the R4600 config has NO secondary cache by
  design** - so "no L2" stops being a deficiency and becomes an honest Indy.
  The R4600's L1s are **16 KB / 16 KB TWO-WAY set-associative with 32-byte
  lines** (vs the current direct-mapped 16-byte lines): two-way roughly halves
  conflict misses and 32-byte lines fetch twice per miss, both attacking the
  measured 36-cycle-miss bottleneck directly. IRIX 5.3 detects it via PRId and
  uses its R4600 cache tuning, which does not lean on an L2.
* **The source.** KI's CPU is VHDL under `rtl/cpu/`: `cpu.vhd` (top-level
  pipeline), `cpu_instrcache.vhd` / `cpu_datacache.vhd` (the 2-way caches),
  `cpu_TLB_instr.vhd` / `cpu_TLB_data.vhd`, `cpu_cop0.vhd`, `cpu_FPU.vhd` (+
  `cpu_FPU_sqrt.vhd`), `cpu_mul.vhd`, `divider.vhd`, plus `functions.vhd`,
  `dpram.vhd`, `RamMLAB.vhd`, `SyncFifoFallThroughMLAB.vhd`, `export.vhd`,
  `cpu.qip`/`mem.qip`. VHDL is already in this project's toolchain (the current
  wrap is VHDL->GHDL->Verilog), so language is not the barrier.
* **The integration is the work, and it is large. Scope it before touching a
  fit:**
  - **Bus adaptation.** The KI core has its OWN memory/cache-linefill
    interface; the Indy side is `rtl/cpu/r4300_bus.sv` into MC/ram_arb/DDR3.
    Write an adapter, not a rewrite. The KI core drives DDR directly for KI;
    map its linefill/writeback onto the Indy bus.
  - **Endianness.** The Indy is big-endian and IRIX/PROM assume it end to end;
    confirm the KI core's byte order and add swaps at the adapter if it runs
    little-endian for KI.
  - **CP0 / exception / TLB fidelity is the acceptance gate.** The bar is the
    IRIS CPU suite: `make -C verilator cpuonly` (364 checks in seconds) and
    `tests/run-cputest.sh`, plus `tests/run-cputest-hw.sh` on the board. The
    current core PASSES all of identity/alu/muldiv/mem/branch/excep/cp0/tlb
    (the one standing FAIL is `fpu/vec_cvt_from_l`, cvt.s.l/cvt.d.l of a
    64-bit int - a known FP corner, not blocking). The R4600 core must clear
    the same suite, and its identity test will need the R4600 PRId/Config
    (update `tests/identity` expectations OR present R4400-compatible IDs -
    decide which machine IRIX should think it is).
  - **The debug bus.** `sgi_indy.sv` connects nine `dbg_*` pins (dbg_retire,
    PC, exc, etc.) that the beacon and sim harness read. Either expose
    equivalents from the KI core or stub them; `verilator/wholemachine` and
    `syn_top` both wire them.
  - **Re-measure with the same `bench` group** after it boots - the point of
    the swap is the miss numbers, so prove them.
* This is a multi-fit project. Land item 1 (SCSI) and ideally item 2 (video)
  first so the CPU swap is not entangled with an unfitted backlog.

### 5. Ethernet (contract already mapped this session)

IRIX configures ec0 unconditionally and the boot burns 2+ minutes on
no-carrier timeouts (the repeating `ALERT: ec0: no carrier: check Ethernet
cable` seen live this session). Contract, read out of IRIS + the guest's own
/unix driver:

* **The Seeq 8003 MAC is at HPC3 offset 0x54000 (phys 0x1FBD4000), 8
  word-strided registers, and it is currently an UNCLAIMED HOLE** - which is
  why the driver reads nothing and reports no carrier. enetr/enetx descriptor
  DMA windows are at 0x14000 / 0x16000 (decoded as STORAGE only, no engine).
  INT2 L0 bit 3 (Ethernet) is hardwired 0.
* **"Honest carrier" is a REGISTER MODEL, not the full DMA engine.** Read from
  the kernel this session: `seeq_init` (0x880b3bec) only WRITES registers
  (station address to Seeq regs 0-5, enetr DMA config) and never spin-waits on
  Seeq status. The carrier decision is `ec_watchdog` reading 80C03 read-mode
  reg 5 (`NO_CARRIER` bit clear = carrier present); `coll_xmit[0]==0` (reg 0
  read-mode) is how the driver detects the SGI EDLC. IRIS `src/seeq8003.rs` is
  the full register/DMA/interrupt oracle (banks, OLD bits, the RX status byte
  appended as the last DMA byte). READ `ec_watchdog` (0x880b4238) and `ec_reset`
  next to confirm a carrier-present register model quiets the boot without
  moving the hang into an RX/TX wait.
* Full shape for ping (later): Seeq MAC regs + RX/TX rings through HPC3's
  enetr/enetx descriptor DMA (walker pattern exists in hpc3_scsi_dma.sv),
  ethernet interrupt on L0 bit 3, and an ARM-side bridge daemon moving frames
  through a DDR3 mailbox ring (the beacon proved the channel; `ddr3_peek.py`
  is the read side). MAC address already flows: mac_addr -> eeprom/NVRAM ->
  PROM eaddr.
* First milestone is honest carrier (kills the boot timeouts); ping and NFS
  ride on the RX/TX engine after.

### 6. Housekeeping that pays for itself

* **Stop power-cutting the guest.** This session power-cut it twice (the
  benchmark boot.rom and the restore). Every dirty boot fscks the 2 GB EFS for
  5-10 min. Log in and `shutdown -y -g0` / `init 0` before redeploying, or keep
  a cleanly unmounted image copy. Reaching a shell for this is gated on item 3
  (input tooling).
* `SGIIndy53.img` is the pristine copy; `SGIIndy53-wedged-fsck.img` is the
  boots-fine board image.
* Leftover SCSI (item 5 of docs/34, now the only one left): 64-bit CPU PIO
  stores to REX3 drop a half (newport.sv takes one word); nothing issues them
  today, fix when something does.

## Instruments (all present, all proven)

* **`tests/hw-cputest` + the `bench` group (NEW, `7123efb`).** `tests/
  run-cputest-hw.sh --no-build` deploys the suite as boot.rom, runs it, reads
  the Count-tick counts out of DDR3. The `bench` group prints i_cached/
  i_uncached/ld/st/ld_miss/count_rate; re-run it after any CPU or memory
  change. Carried as a patch (`tests/hw-cputest/bench.patch`), like
  console-memlog, so the shared IRIS suite checkout stays an unmodified oracle.
  It reboots the board (power-cuts IRIX).
* `bcnread.py` (ver=7, 15 words) - VDMA words 11-13, display word 14, CPU PC
  word 10. **Re-push after any edit; the board copy goes stale silently.** 100
  samples + `ecoffsyms.py` = a statistical profiler.
* **The live IRIS oracle**: boot the same image beside the board (iris-ci +
  parsing `saves/<name>/rex3.bin`). Traps: CI overlay mode hardcodes /tmp (use
  a disposable image COPY); `screenshot` takes a POSITIONAL path and its rgba
  can lag - PrintWindow-capture the iris window instead.
* `fbgrab.py`+`fbpng.py` (framebuffer) vs `scripts/grab.sh` (monitor) - ALWAYS
  check both. `ws_send.py` drives keyboard+mouse over the MiSTer ws API (mouse
  caveats in item 3). `launch_unstable_core.py` (clean reboot + OSD launch) is
  the reliable core-launch; the bare no-reboot OSD nav can select the wrong
  core.
* `efsread.py` / `ecoffsyms.py` / `disbin.py` - the guest's own binaries answer
  register contracts for free (/unix has if_ec for Ethernet, seeq_init/
  ec_watchdog decoded above). `unix.ecoff` is already extracted in the tree.
* Sim: `make -C verilator cputest | cpuonly | mcdmatest | rex3test | vc2test`;
  `tests/run-scsi.sh` / `run-scsiwr.sh` / `run-cdrom.sh` / `run-rex3.sh` (run
  via LF copies - the .sh files are CRLF and die under WSL bash).
* `scripts/build.sh` detached via Invoke-CimMethod; `scripts/deploy.sh`;
  `scripts/setopt.sh` (viddbg=raw is the palette-bypass view).

## Traps already paid for (do not re-pay)

* **`cputest` and `cputest-dcb-debug` now build with WM_OPT, not -O3.** The
  per-target sd_lba/sd_buff_din arrays (a top-level unpacked-array port) tip
  every level above -O0 into the no-location Verilator 5.020 internal fault
  the wholemachine targets already dodge. sim_top.sv FLATTENS those arrays to
  packed vectors at the top-level port (Verilator miscompiles an unpacked-array
  top port); sim_scsi.h reads them per lane. Keep that shape.
* **The ws mouse is unreliable for targeting** (item 3): relative-only,
  velocity-dependent acceleration, 8-bit delta wrap above ~127. `mouseMove`
  bursts in the same direction accumulate acceleration and fly off-screen.
  Park at a corner with many large opposite deltas (clamping pins it), then
  small single steps with a screenshot between each - or fix the tooling.
* All of docs/34's and docs/32's traps still apply: fits ~40 min, db/ cleanup,
  no qsf edits mid-compile, no Verilator during fits, Invoke-CimMethod for
  detached builds; `-O1+` dies on this design (WM_OPT is the working set);
  `rtl/cpu/generated/r4300_wrap.v` is gitignored - regenerate before
  whole-machine builds; beacon display-word samples include ~30% BLANKING;
  the PROM runs all real draws at cidmatch=0xF; any INT2 line must be retirable
  by its ISR or IRIX starves.
* WSL/Git-Bash: `MSYS_NO_PATHCONV=1` before `wsl.exe -- bash /mnt/c/...` calls,
  and put the work in a SCRIPT FILE (shell vars are eaten crossing into WSL).
  The GHDL shim (`/tmp/llvmshim`) must be recreated every session before
  regenerating the CPU wrap - check the generated file's timestamp before
  believing a Verilator result.
