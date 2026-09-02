# Work item: the Newport pixel-DMA black screen (and two small SCSI bugs)

Paste everything below the line as the opening message of a fresh session.
This follows [31-scsi-wedge-asr.md](31-scsi-wedge-asr.md) (the fsck SCSI
wedge, now FIXED and verified) and picks up the last known blocker to a
usable desktop. Written 2026-09-02.

---

## STATE AT HANDOFF (read this first)

* **The fsck SCSI wedge is FIXED. Do not reopen it.** docs/29-31 tell the
  whole story; the fix is commits `f9b86c6` + `7d05b95` on `main`, verified
  on the board 2026-09-02: fsck runs all six phases on a dirty filesystem,
  repairs it, remounts root, and IRIX 5.3 proceeds into multiuser boot. HEAD
  is `77d4693` and every commit is fitted, deployed, and confirmed.
* **The board is running build 11** (beacon `ver=5`) and boots to multiuser.
  The machine is ALIVE when the screen is black - the beacon shows steady
  disk I/O, it is X that cannot draw. Confirm liveness with the beacon, not
  the screen.
* The old wedged-fsck reproducer image was REPAIRED by the successful fsck
  run and now just boots. `SGIIndy.s1` still points at it; it is a fine
  boots-to-multiuser test image. `SGIIndy53.img` is the pristine copy.
* Build 11's rbf is `output_files/sgiindy.rbf`; a copy of build 9's is
  `output_files/sgiindy-b9-00de15a.rbf` (obsolete, delete freely).

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly - do not create branches.** The reference emulator IRIS is the
sibling checkout `C:\Temp\mistercore\iris`. Toolchain, build recipe and
traps are in the auto-memory; read those notes before building anything.

## The job: video / Newport pixel DMA

IRIX now boots to multiuser but the screen goes BLACK when X starts. The
kernel logs `ng1 pixel dma write timeout`; X draws its cursor and nothing
else. Nobody has ever worked on this bug - there is no prior diagnosis to
inherit and nothing in docs/28-31 beyond the symptom.

What is already known, so you do not re-derive it:

* **The framebuffer and scan-out work.** The PROM console, the fsck
  transcript, and all boot text render correctly (read them any time with
  `fbgrab.py` on the board + `fbpng.py --mode text` locally). The failure
  is specifically the path X uses to move pixels - REX3 drawing / pixel DMA
  from host memory - not the display pipeline.
* The Newport RTL is `rtl/newport/` (`np_rex3.sv`, `np_vc2.sv`,
  `np_xmap9.sv`, `np_cmap.sv`, `np_bt445.sv`). The oracle is IRIS's
  `src/rex3.rs` (frame buffer layout notes are in docs/18 section 0).
* "ng1" is the IRIX Newport graphics kernel driver. It is IN /unix on the
  boot image, with symbols - see the instrument list below for how to
  disassemble exactly what it programs and what it polls when it times out.

## HOW to work this - the two lessons that ended the last bug

The previous work item burned three 40-minute fits guessing an 8-bit status
code before switching method. What actually fixed it, in one session:

1. **Read the guest's own binaries FIRST - they are instruments that cost
   no fit.** `efsread.py IMAGE get /unix ./unix` pulls the kernel off any
   boot image; `tools/misterdeploy/ecoffsyms.py unix syms|lsyms 'ng1|rex'`
   finds the driver functions; `ecoffsyms.py unix dump ADDR LEN out.bin` +
   `disbin.py out.bin ADDR` disassembles them. For this bug: find the ng1
   code that prints `pixel dma write timeout`, walk back to the wait loop,
   and read WHAT REGISTER AND BIT it polls and what it wrote to start the
   DMA. That is the hardware contract the RTL must meet - get it from the
   binary, not from guesses.
2. **Read EVERY consumer before changing shared semantics.** The ASR bit-5
   regression (docs/31) happened because the fix satisfied IRIX's driver
   and broke the PROM's - both binaries had to be read. The Newport is used
   by the PROM (console text - currently WORKING, do not break it), by the
   IRIX text console, and by X/ng1. Any register-semantics change must be
   checked against all three.

Then, and only then, instrument. The DDR3 debug beacon is built for
extending: `sgiindy.sv` streams words to ARM `0x35800000` (currently 11
words, `ver=5`, decoded by `tools/misterdeploy/bcnread.py`); add Newport
state words (REX3 command/status, DMA engine state, whatever the ng1 wait
loop polls), bump the version byte, extend `bcnread.py`, ONE fit, read the
live answer while X is timing out. Bundle the best-guess fix and the
diagnostics into the same fit so one build is conclusive either way.

The Verilator whole-machine sim (`make -C verilator wholemachine2`, see the
auto-memory note) boots the PROM and IRIX and may well reproduce a graphics
protocol bug - the SCSI bugs it missed were DDR3-latency-timing bugs, which
this may not be. `verilator/sim_video_cap.h` exists for capturing video. A
sim reproduction turns 40-minute fits into minute-long iterations - worth
one 30-minute boot attempt to find out before touching the board.

## Instruments (all present, all proven this week)

* `tools/misterdeploy/bcnread.py` - the beacon reader (on the board at
  `/media/fat/sgidbg/`; **re-push after any local edit, the board copy goes
  stale silently**). Words 9-10 are INT2 state + CPU PC - `cpu: pc=` plus
  `guestmem.py`/`disbin.py` locates any wait loop the kernel is stuck in.
* `tools/misterdeploy/ecoffsyms.py` - ECOFF symbols/disassembly for /unix
  (header documents the format). `efsread.py` - pull files off EFS images.
* `fbgrab.py` (board) + `fbpng.py` (host) - read the console framebuffer.
* `guestmem.py` (board) - dump guest RAM by MIPS address; `disbin.py`
  (host) - disassemble it. `ddr3_peek.py` underlies everything.
* `scripts/deploy.sh` - build+push+launch. `scripts/build.sh --log bNN.log`
  detached via the `Invoke-CimMethod` recipe in the local-toolchain memory
  (~40 min; monitor the log, and on a crashed fit `rm -rf db
  incremental_db` before rebuilding).
* The PROM disassembles too: `disbin.py boot.rom 0x9fc00000` (whole image).

## Also open, smaller (SCSI, both diagnosed in docs/29)

* **CD-ROM `wd93 ID=6 cmd=0xc9` timeouts** - a CDB-length disagreement:
  the initiator sends 6 bytes by SCSI group rule, `scsi.v` decodes
  0xC0-0xCE as 10-byte Apple-CD commands and parks holding BSY. The real
  part answers status 0x87 UNKNOWN_GROUP. Fix is in `scsi.v`'s CDB-length
  table / group decode.
* **`sd_lba` last-match-wins mux** in `sgi_scsi.sv` - wrong if two targets
  request at once.

Both are register-level protocol bugs - the kind the sim DOES reproduce.
Consider fixing them in sim and riding along on the next video fit rather
than paying fits of their own.

## Traps already paid for (do not re-pay)

* A fit is ~40 minutes. Instrument to a definitive reading BEFORE changing
  RTL, and read the driver binaries before that.
* Killing `quartus_fit` mid-run corrupts `db/` -> next synthesis fails
  silently. `rm -rf db incremental_db` to recover. Quartus 17.0 Lite also
  just dies mid-routing sometimes (no error line) - same recovery.
* Do NOT touch `sgiindy.qsf` (including via git) while a compile runs.
* Do NOT run the Verilator sim and a Quartus fit at once (CPU contention
  has crashed the fitter mid-routing).
* `Start-Process` cannot launch detached builds - use the
  `Invoke-CimMethod` recipe in the local-toolchain memory, and confirm a
  `quartus_*` process exists rather than trusting the log file.
* `alive.py`'s default address reads the PROM stack and is misleading for
  IRIX-kernel liveness - use the beacon heartbeat and `cpu: pc=` instead.
* The `SYNC negotiation error, resetting bus` NOTICE at attach is benign
  (target declines SDTR). The beacon sticky word latches a benign boot-time
  op=03 park - watch the LIVE words, not the sticky.
