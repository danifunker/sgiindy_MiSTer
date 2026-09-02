# 29: the fsck SCSI wedge - what code reading killed, and the DDR3 beacon

Follows [28-fsck-scsi-wedge.md](28-fsck-scsi-wedge.md). Written 2026-09-01,
while the first beacon fit was in the fitter. The measurement section at the
bottom is filled in from the wedged board.

## The reproducer works and is cheap

`SGIIndy.s1` -> `SGIIndy53-wedged-fsck.img`, `load_core` through
`/dev/MiSTer_cmd`, and the board wedges inside ten minutes, every time. The
wedge is a **livelock, not a dead stop**: the framebuffer (via `fbgrab.py` /
`fbpng.py`) shows IRIX still appending a `cmd=0x28 timeout after 60 sec.
Resetting SCSI bus` pair every minute, the driver giving up after four tries
(`dks0d1s0: SCSI driver error`), fsck answering its own `CONTINUE? yes` and
walking into the next read, which fails the same way. Every disk command fails
identically, forever; `diskio.sh` reads FROZEN throughout. The board holds this
state indefinitely, which is what makes it measurable at leisure.

Two other things the screen said that docs/28 could not have known:

* `NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus` at
  kernel attach - **before anything is wrong**. That line is designed-in: the
  target swallows SDTR without answering (scsi.v's MESSAGE OUT arm documents
  the decision), the PROM prints the same thing in simulation, and the boot
  proceeds async regardless. Benign on its own, but it means every retry that
  renegotiates walks a message path we know is imperfect.
* **No ID=6 lines at all during the wedge.** The CD target is not being
  touched when the disk starts timing out. The CD-collision theories below
  stay real bugs, but they are not this wedge's trigger.

## What docs/28's suspect list looks like after reading the actual code

docs/28 ended at "io_ack is the leading suspect, a stuck term the reset cannot
clear". Reading `hps_io.sv` and the fetch/flush engine kills the whole
stuck-term family in steady state, for any *mounted* slot:

* `io_ack` **cannot** be stuck high while the ARM is alive: `sd_ack` is a
  register in hps_io that is cleared at the end of *every* SPI transaction
  (`if(~io_enable) ... sd_ack <= 0`), and the ARM's input polling - the same
  polling that makes `rchar` climb on an idle board - completes transactions
  constantly. `sgi_scsi.sv` wires `io_ack(sd_ack[t])` combinationally; there
  is no latch in between to go stale.
* `io_rd_d` and `io_wr` high *are* `sd_rd[t]`/`sd_wr[t]` high (scsi.v:1861,
  sgi_scsi.sv:258): the ARM would see the request, service it, and the
  counters would climb. They are frozen, so neither is stuck - on a mounted
  slot.
* `wr_pending` self-promotes to `io_wr` on any cycle with `io_ack` low
  (scsi.v:1896). It cannot linger alone.

So on the disk there is **no single stuck bit for a bus reset to fail to
clear**. What remains is either a state that *re-arms deterministically on
every retry* - a livelock, which is also exactly what the framebuffer shows -
or a recovery reset that never reaches the target at all. Both are questions
about events, not about a parked bit, which is why the instrument below is
counters plus a sticky snapshot rather than one status word.

The unmounted-slot loophole is real, though: a request raised on a slot the
ARM has no image for is **never serviced and never acked** - `sim_scsi.h`
declines exactly the same way (`(want_rd || want_wr) && d.mounted`) - and that
parks the requesting target forever. Which leads to the CD.

## The CD target findings (real bugs, parked as not-this-wedge)

* **The board runs with a CD mounted; every earlier simulator run did not.**
  `SGIIndy.s3` has held `IRIX 5.3 XFS.iso` since Aug 31, so on the board the
  ID=6 target is live - answers selection, can fetch, holds bus state - while
  in every "the simulator does not reproduce it" run it was inert. The sim
  runs in this round mount the ISO at `--disk 6=` to close that gap.
* **`wd93 ID=6 cmd=0xc9` timeouts are a CDB-length disagreement, found in the
  RTL.** The initiator's Select-and-Transfer length table is the group rule
  (`wd33c93.sv` cdb_len: groups 1,2 -> 10, group 5 -> 12, else 6), so for
  0xc9 (group 6) it sends 6 bytes. The CD target decodes 0xC0-0xCE as
  10-byte Apple-CD commands (`scsi.v` cmd_apple_cd_op) and REQs for byte 7
  forever; `cmd_wait` only bails while `cmd_cnt == 0`, so the target holds
  BSY until the next bus reset. IRIS cannot hit this (its targets take the
  CDB as delivered), and the real WD33C93A would refuse the group outright -
  NetBSD's sbicreg.h names status 0x87 `SBIC_CSR_UNK_GROUP`, and IRIS carries
  the same constant - which is why IRIX has a byte-banged path for vendor
  CDBs at all. Fix shape, for a later round: raise 0x87 for vendor groups in
  SAT mode like the part does, and give the target a mid-CDB timeout so *any*
  length disagreement self-heals instead of parking the bus.
* **`sd_lba` is a last-match-wins mux across all requesting targets**
  (`sgi_scsi.sv:279`). Two simultaneous requests and the higher-numbered
  target's LBA wins for both - the disk's fetch would be served from the CD's
  address. Needs an outstanding-request qualifier eventually; not this wedge
  (the counters would climb, and they do not).

## The instrument: a DDR3 beacon (this round's change)

Everything above narrows the question to *which event fails at each retry*,
and that needs eyes on the RTL while the board is wedged. The JTAG debug
words exist but nothing on this bench reads JTAG; the DDR3 bridge, however,
is already ARM-visible - `ddr3_peek.py` reads the guest's RAM and the
framebuffer through it. So: stream the SCSI state into DDR3 and read it with
the tooling that already exists.

* `sgiindy.sv` gains a writer that streams eight 64-bit words to the unused
  window at byte offset `0x0580_0000` in the core's 256 MB region - ARM
  physical `0x3580_0000`, above the PROM's 512 KB at `0x0500_0000` - one word
  every 64 cycles, full set every ~16 us. It runs on `pll_locked` alone, so a
  wedged or resetting guest cannot stop the reporting.
* `ddr3_mux.sv` gains a sixth master for it with **strictly lowest static
  priority**, outside the rotation: the beacon is taken only on cycles where
  nothing else is pending, so observing the machine cannot change it. The
  rotate loop's bound is now spelled `3` (the rotating group's size) rather
  than `NM - 2`, which it stopped being.
* The words: w0 heartbeat/magic `BEC0`; w1 bus+HPS live (`sd_rd/sd_wr/sd_ack`
  and per-target BSY vectors, initiator's sel/atn/ack/rst, bus phase lines,
  live `sd_lba`); w2 wd33c93 (counters for chip_reset pulses, `scsi_rst`
  loads, accepted `C_RESET` writes, accepted select-and-transfers, LCI
  refusals, plus `R_COMMAND`/`R_CMD_PHASE`/cip/int_pending/state); w3/w4 and
  w5/w6 target 1 and 6 live pairs (op, phase, the four io_busy terms and
  their friends, cmd_cnt, data_cnt, tlen, lba, data_len, ring fill); w7 a
  **sticky first-stall snapshot** in target 1, cleared only by system reset -
  a bus reset must not erase the evidence - latching the first 129 ms-long
  park with a reason code: REQ suppressed (io_busy/dpc class) vs REQ
  unanswered (initiator-absent class). Bit maps live next to each assembly
  and in `tools/misterdeploy/bcnread.py`, the decoder that runs on the board.
* The wd33c93 counters are the sharpest single question: IRIX prints
  `Resetting SCSI bus` every minute while wedged. If `rst_load` (bus-visible
  resets) counts up in step, recovery reaches the target and the livelock is
  in the retried command; if only `c_reset` moves, the kernel's recovery is
  chip-local and no reset ever reaches the wedged target - scsi.v's watchdog
  comment block predicted exactly that failure shape. The HPC3 path is
  falling-edge on ch_reset (`hpc3_scsi_dma.sv`), and the byte-lane merge in
  `sgi_hpc3.sv` is width-agnostic, so if the counter stands still the answer
  is in *what the driver writes*, not in how it is decoded.

Synthesis cost: 38,990 registers against the design's usual ~39k - the beacon
is noise. The register-ceiling check and the uninferred-RAM list in
`build.sh` both stayed clean (the six known instances, no new ones).

## Measurement - the beacon named it on the first read

One fit, deployed, board re-wedged itself in ten minutes, and
`bcnread.py --loop 50 --interval 2` sampled 100 s straight through the retry
loop. Every one of the 50 samples of the target was **byte-identical**:

```
id1: op=28 phase=DATA_OUT cmd_cnt=10 data_cnt=261808 tlen=1571 lba=5581
     data_len=804352 rdblk=31 [bsy req mnt sbsel]
wd:  ... c_reset=8 sel_xfer=93 R_CMD=08 R_CMDPH=46 cip=1 intp=0 state=11
```

and the wd33c93 counters stepped **exactly once per ~60 s retry**
(`chip_rst`/`rst_load`/`c_reset` 7->8->9 over the capture, `sel_xfer`
93->94->95). Read straight off the hardware, that is the whole bug:

* **The transfer is large and segmented.** `tlen=1571` is an 804,352-byte
  READ(10). IRIX cannot map that in one DMA window, so it programs the
  wd33c93's Transfer Count to the first segment - **261,808 bytes** - and the
  target has served exactly that (`data_cnt=261808`) and stopped.
* **The target is not stuck - it is waiting, correctly.** `phase=DATA_OUT`
  (scsi.v's name for serving a read), `[bsy req]`: BSY held, REQ up, offering
  byte 261,808. It has 542,544 bytes left and will hand them over the instant
  it is ACKed. Nothing in the target is wrong.
* **The initiator parked and said nothing.** `state=11` is `ST_SAT_PHASE`;
  `R_CMDPH=46` is `CP_XFER_COUNT` (count hit zero); `cip=1`; and **`intp=0` -
  no interrupt was ever raised.** The Select-and-Transfer sequencer reached
  "count exhausted, target still in a data phase" and took the branch that
  *waits for the target to move on* - which a target with half a megabyte
  still to give never does.
* **The reset reaches the target and changes nothing** - which kills docs/28's
  standing theory. `rst_load` (bus-visible `scsi_rst` load edges) increments
  in lockstep with IRIX's "Resetting SCSI bus", so the recovery reset is real
  and reaches the target. The wedge survives it because after the reset IRIX
  re-issues *the same* Select-and-Transfer, the target re-serves the same
  261,808 bytes, count hits zero again, and it re-parks. A livelock, exactly
  as the framebuffer showed - not a stuck input a reset fails to clear.

`io_ack` was never it. There is no stuck bit at all: the target is idle-correct
and the initiator is asleep at a branch that should have interrupted.

### Why the simulator never saw it

The pre-fix sim runs "sail through fsck" because sim's fsck issued only small
reads - `tlen` of 8, 46, 128, 192 in this session's capture - each of which
fits one DMA segment, so the count never exhausts mid-transfer. The board's
fsck clustered an inode read into `tlen=1571`, three segments deep, and only a
multi-segment transfer hits the missing pause. The bug is invisible below the
DMA-map size, which is why 50 minutes of simulation could not find what one
beacon read did.

## The fix

`wd33c93.sv`, the Select-and-Transfer sequencer, two halves that mirror what
IRIS and the real part do:

* **Report the pause.** In `ST_SAT_PHASE`, when the Transfer Count is zero and
  the target is still asking in a data phase, raise
  `S_UNEX_INFO | phase` (0x48 | phase - the "unexpected information phase"
  group, `0x48` DATA IN / `0x49` DATA OUT), set `int_pending`, and drop to
  `ST_IDLE` with `CP_XFER_COUNT` already in the command-phase register. That
  is the interrupt the driver's `unex_info()` path is waiting for; IRIS posts
  the identical `queue_interrupt(TRANSFER_COUNT, 0x48/0x49)` from its own
  chunked-DMA pause. A 4096-cycle (~126 us) settle counter distinguishes a
  real pause from the cycle-or-two tail where a *completed* transfer also
  reads {count 0, REQ, data phase} before the target changes the phase lines.
* **Resume without re-selecting.** A `C_SEL_XFER`/`C_SEL_ATN_XFER` issued while
  the command-phase register still reads `CP_XFER_COUNT` and the target still
  holds BSY is a *continuation*, not a new command: skip selection, IDENTIFY
  and the CDB, and go straight back to following the target's phase with the
  reloaded count. The target's own `data_cnt` never moved, so it serves byte
  261,808 onward. NetBSD's `wd33c93` driver issues exactly this write per
  segment (and once more at the end, when the target is already in STATUS and
  the ordinary phase walk concludes the command); IRIS implements both halves
  on its `cmd_phase == 0x46` arm.

Cost: one 12-bit counter and a 16-bit-to-nothing status constant. No new
warnings over the baseline lint; the V3Gate crash needs the project's usual
`-fno-gate`. Second fit in progress; board test to follow, and it is the only
place that reproduces, so it is the only place that can confirm.

The beacon stays in the tree behind its lowest-priority DDR3 master. It cost
one fit and turned a multi-day "which stuck bit" hunt into a single 100-second
read, and the CD-changer CDB-length wedge and the `sd_lba` mux race above are
both waiting for the same instrument.
