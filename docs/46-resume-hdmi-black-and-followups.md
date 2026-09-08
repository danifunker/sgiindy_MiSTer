# Work item: the core's video no longer reaches the MiSTer scaler (black picture, OSD visible) on EVERY build - find it; then the KI R4600 follow-ups

Paste everything below the line as the opening message of a fresh session.
This continues [45](45-resume-ki-revendor-board.md). The KI R4600 CPU
re-vendor is DONE: merged to `main` and verified on the board as build 24.
What is open is a display problem that appeared on the board on the morning
of 2026-09-08 and is NOT the CPU work - it is identical on build 22, the
build that showed a full X desktop over HDMI at 21:01 the evening before.
Written 2026-09-08.

---

## STATE AT HANDOFF (read this first)

* **`main` is at `1da05f7`** (merge of `claude/ki-revendor`): the CPU is the
  Killer Instinct R4600 with our changes (`rtl/cpu/r4300/UPSTREAM.md` is the
  authority), the D-cache 16 KB physically indexed, the I-cache 8 KB (one
  R4600 way, full 20-bit tag). **Build 24** = `output_files/sgiindy-b24-seed2.rbf`,
  md5 `ab3ae66db0604ccfa466224785e2cdf5` (rbfs are gitignored; the md5 is
  the record). Verified on the board: hardware cpu-tests 2165/3 (PRId/FIR
  0x2020), bench identical to build 23 (`ld_miss` 114,437 ticks / 8192 loads
  - +7 % over build 22's 106,790, the 32-byte fill; everything else to the
  tick), and **IRIX 5.3 booted twice cleanly to the full desktop with zero
  bus errors / segfaults / illegal instructions** (build 23's storm, caused
  by IRIX colouring only bit 12 for an R4600 against a virtually indexed
  16 KB I-cache, is gone - auto-memory `irix-r4600-colours-one-bit`).
* **The board** (Indy MiSTer at `192.168.99.92`, `scripts/local.env`; the
  other session's `192.168.99.143` is a different MiSTer): build 22 in
  `_Unstable` (md5 `bd342f18e6be032fee53bfdc07fae3aa`), the real PROM as
  boot.rom (md5 `11bb4acd64fb7c79c985d3d09390668b`), `SGIIndy53.img` in slot
  1, guest halted at "Okay to power off" since 08:41. Deploy build 24 with
  `bash scripts/deploy.sh --rbf output_files/sgiindy-b24-seed2.rbf`.
* **THE OPEN PROBLEM: the monitor shows BLACK with the MiSTer OSD visible,
  on build 22 and build 24 alike.** All of this was measured on 2026-09-08:
  - The OSD appears over black. So the HDMI transmitter, the scaler output
    and the monitor are fine; what is missing is the CORE's video into the
    scaler (or the scaler's lock on it). Not a cable, not the monitor.
  - `scripts/grab.sh` (the MiSTer screenshot API) returns "STALE: no new
    frame" at EVERY stage of BOTH builds - PROM screen, fsck, "The system is
    coming up", the X login chooser, the desktop, the halt screen. The last
    frame it ever captured is `20260907_210318-screen.png` (21:03 on 09-07,
    build 22's halt screen); `20260907_210129-screen.png` is build 22's full
    desktop with `hinv` in the Console - HDMI worked then, same MiSTer.ini,
    same `[SGIIndy] video_mode=8 vscale_mode=1` (untouched since 08-30; its
    comment says this monitor does not take a 5:4 1280x1024 mode, so do not
    "fix" it to 4). `echo screenshot > /dev/MiSTer_cmd` produces nothing.
  - The core's display engine is healthy the whole time (`bcnread.py` on the
    device): `did_en=1 walk=RUN`, `did`/`cidx` changing, `rgb_miss=0
    aux_miss=0` (zero is the GOOD reading - docs/36), `aux_skips` ~28.0k/s on
    both builds at every stage (that is the normal rate; a half-rate theory
    was wrong). The frame buffer read back by `scripts/screen.sh` is a
    perfect desktop. So the fetch path (docs/36's bug class) is not it.
  - MiSTer main is alive (~100 % CPU as always with a core loaded),
    `MiSTer_fb` reconfigures to 1920x1080 on every core load and its
    `frame_count` advances at 60/s (that is the Linux/OSD framebuffer, not
    the core's video). The MiSTer's Linux rebooted at ~07:00 on 09-08
    (`launch_unstable_core.py` reboots by design; `tests/run-cputest-hw.sh`
    uses it) and the fault was present from the first launch after it.
    Timeline: 21:03 last good capture (09-07) -> nothing between -> 07:00
    harness reboot + build-24 hardware suite -> black ever since, through
    builds 24, 22, 24, 22.
  - The core's video output is the VC2 timing table (`rtl/newport/np_vc2.sv`
    interprets the table the PROM loads; `vtg_enable = DC_CONTROL[2] &&
    CONFIG[0]`) -> pixel pipeline -> the `VGA_*`/`CE_PIXEL` port to the
    framework. Nothing in the beacon says whether HSYNC/VSYNC/DE are being
    emitted - that is the missing instrument.

## RESOLVED 2026-09-08 09:15 - a full `reboot` from the MiSTer's shell brought the
## video back. The framework's API reboot (`/api/settings/system/reboot`, what
## `launch_unstable_core.py` and `scripts/deploy.sh` use) had NOT cleared the
## wedge on its own during the morning's A/B; after the user's shell `reboot`
## the picture returned, and a subsequent `deploy.sh` (API reboot + launch) of
## build 24 kept it: `scripts/grab.sh` captured a fresh PROM screen at 09:16.
## So: black picture with the OSD visible = an HPS/framework video wedge, not
## the core; the cure is `ssh root@<mister> reboot`. Build 24 is on the board.
## Everything below is kept as the diagnosis trail and the instrument plan
## should it recur.

## The queue

### 1. First, the free experiments (no fit)
1. **Power-cycle the MiSTer** (the user's hands) and launch build 22 alone.
   If the picture is back, the fault was framework/HPS state left by the
   07:00 harness reboot - record that `launch_unstable_core.py`'s reboot
   path can leave the scaler dead, and make `run-cputest-hw.sh` warn.
2. **Read the OSD's System info page** on the monitor (the OSD works): it
   shows the core's INPUT video mode as the framework measured it
   (e.g. "1280x1024 60.0Hz") - or nothing / 0x0 if the core emits no sync.
   That single line decides between "no sync from the core" and "sync the
   scaler rejects".
3. Try the MiSTer's menu core, then a known-good other core, to prove the
   scaler path once more; try build 21 (`output_files/sgiindy-b21-seed2.rbf`,
   md5 `5f02393b96f9e1361d5b6da6ed7b2a93`, in the worktree's output_files).
4. `scripts/console.sh --baud 9600` while the PROM boots: with graphics
   fitted the PROM's console goes to the frame buffer, so silence there is
   expected - but "Graphics board: None"-style output would mean the PROM
   did not find Newport, i.e. the board never got a timing table.

### 2. Then the instrument, if it is still black (one fit, per `hardware-bug-instrument-first`)
Add a beacon word (`sgiindy.sv`, `bcn_src[..]`; the decoder is
`tools/misterdeploy/bcnread.py`, pushed to `/media/fat/sgidbg/`) carrying:
HSYNC and VSYNC edge counters (16 bits each, wrapping), a DE-active pixel
counter, `vtg_enable`, `DC_CONTROL` and `CONFIG` of the VC2, and the
framework-side `CE_PIXEL`/pixel-clock enable state. Read it on a black
build 22: "vsync advancing at 60/s, DE active" means the core emits a valid
frame and the SCALER is not taking it (then look at `sys/` - the video
pipeline's `vga_*` -> scaler handoff, `direct_video`, the `sys_top` HDMI
config the framework programs from `video_mode`); "no vsync" means the VC2
never got enabled/loaded (then trace the PROM's DCB writes to the VC2 -
`np_rex3.sv`'s DCB path - and whether `R_CONFIG[0]`/`DC_CONTROL[2]` were
ever written). Gate any display-path change on `make -C verilator
fetcharbtest linecachetest run-newport run-rex3`.

### 3. KI R4600 follow-ups (independent of the display)
* **16 KB two-way I-cache** with the way selected by PHYSICAL bit 13 (no
  replacement policy, no alias): a second tag lookup and a second data-RAM
  read per fetch path plus a mux on KI's shortened fetch path. Today's 8 KB
  cache costs nothing on the bench; measure before spending the timing.
* `hinv` on build 24 was never captured; docs/45 has the pointer recipe
  (30x `mouseMove:-60,-60`, 39x `mouseMove:7,10`, `root`+Enter, at +35 s
  `hinv > /hinv.txt` then `init 0`, read with `efsread.py IMAGE cat`).
  Expect "MIPS R4600 Processor Chip Revision: 2.0", FPU R4600 2.0.
* The cpu-tests suite's R4600 support is applied but UNCOMMITTED in
  `C:\Temp\mistercore\iris\cpu-tests` (`harness/testlib.c`,
  `tests/identity/identity.c`, `tests/cache/cache.c`); commit it there or the
  next refresh of `~/cputests` loses it and the suite refuses to run (rc=127).
* Core clock slack: build 22 +2.459, build 23 +2.904, build 24 +1.697 ns.
  The 20-bit I-cache tag compare cost ~1.2 ns on KI's FetchIndex path; if
  timing ever bites, that compare is the first thing to pipeline.
* The sim-only post-init idle wait (`irix-sim-postinit-livelock`) is
  unchanged: the sim never reaches "The system is coming up"; the board does.

## Recipes (self-contained)
* Board instruments run ON THE DEVICE: `ssh root@192.168.99.92 python3
  /media/fat/sgidbg/bcnread.py` (beacon), `.../alive.py`, `.../probe.py`;
  `scripts/screen.sh NAME --mode grey --full --scale 0.5` reads the FRAME
  BUFFER (not HDMI); `scripts/grab.sh NAME` is the HDMI screenshot and says
  STALE when the scaler has no frame; `/media/fat/screenshots/SGIIndy/` holds
  the history. Never `scripts/bootok.sh` for an IRIX boot (it relaunches
  anything not at the PROM prompt within a minute).
* Native-FS sim tree `~/kicpu` (WSL): rsync rtl/tools/verilator, de-CRLF,
  GHDL shim (`/tmp/llvmshim`), `tools/gen_r4300_verilog.sh` (10 s), `make -C
  verilator cpuonly` (728/0), `cputest`, the IRIX boot recipe in docs/45.
  Launch long sims from a script file under `nohup ... & disown`.
* Fit: `SEED=2 bash scripts/fit_when_free.sh bNN` detached via
  `Invoke-CimMethod Win32_Process Create`; it waits for the other session's
  Quartus (MacQuadra800 fits back-to-back for hours - ask the user before
  fitting concurrently).
* Read the auto-memory first: `ki-revendor-wip` (done), `irix-r4600-colours-
  one-bit`, `prom-config-ec-per-family`, `display-fetch-path-board-only`,
  `vc2-line-numbering-off-by-one`, `newport-vdma-pixel-path`,
  `mister-main-death-instruments`, `hardware-bug-instrument-first`,
  `indy-desktop-input-recipe`, `shutdown-hang-kdsp-audio`, `local-toolchain`.
