# Work item: finish the fsck SCSI wedge fix — READ THE DIAGNOSTICS, STOP GUESSING

Paste everything below the line as the opening message of a fresh session. This
follows [29-scsi-wedge-beacon.md](29-scsi-wedge-beacon.md) (the beacon and the
diagnosis) and [28-fsck-scsi-wedge.md](28-fsck-scsi-wedge.md) (the original
work item). Written 2026-09-01.

---

## STATE AT HANDOFF (read this first)

* HEAD is `00de15a`: the 0x49 read pause code + the interrupt-delivery beacon
  (words 9-10, version 3). It is COMMITTED but **never successfully fitted** —
  the build 8 fit CRASHED mid-routing (Quartus 17.0 Lite flakiness, not a code
  error: placement succeeded, routing died with no error line, same as an
  earlier build). So it needs a clean re-fit before it can be tested.
* **The board is currently running the PREVIOUS fit (the 0x19 code)**, which is
  wedged at fsck Phase 1 with the console visible on screen. Leave it unless
  you deliberately deploy a new build.
* Before re-fitting: kill any orphan `quartus_*` processes and
  `rm -rf db incremental_db` (a crashed fit leaves the db corrupt; the next
  synthesis then fails silently). Do NOT run the Verilator sim during the fit.
* First real step is therefore: re-fit `00de15a`, deploy, read words 9-10.

**The previous session was running in circles: it guessed the SCSI interrupt
STATUS CODE three times (0x48, 0x19, 0x49), one 40-minute FPGA fit each, instead
of instrumenting the interrupt path first. Do not do that. A fit is ~40 minutes.
Read the diagnostics build 8 adds, reason from them, THEN change RTL.**

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly - do not create branches.** The reference emulator IRIS is the sibling
checkout `C:\Temp\mistercore\iris`. Toolchain, build recipe and traps are in the
auto-memory; read those notes before building.

## Two separate jobs. Do NOT conflate them.

1. **The fsck SCSI wedge** (this document). Diagnosed completely; the fix is
   written and 90% there. One question remains, and build 8 was fitting the
   instrument to answer it when this was written.
2. **The video / black screen** is a SEPARATE, UNTOUCHED problem. Newport pixel
   DMA (`ng1 pixel dma write timeout`): X draws its cursor and nothing else, so
   a multiuser board is black. Nobody has worked on it. It is NOT the fsck wedge
   and NOT caused by any SCSI change. The fsck console text renders fine (read
   it with `fbgrab.py` + `fbpng.py`); the fsck wedge is why nothing new appears
   there, not the video bug.

## The SCSI wedge — what is PROVEN by direct board measurement. Do NOT re-derive.

IRIX 5.3 boots to fsck but wedges partway through Phase 1 on `cmd=0x28 BLK 1006`.
The DDR3 debug beacon (docs/29, read live with `tools/misterdeploy/bcnread.py`)
established, on the wedged board:

* **It is a transfer-count segmentation livelock, not a stuck bit.** docs/28's
  `io_ack`-stuck theory is DEAD: the beacon shows the bus reset reaching the
  target every retry and changing nothing.
* **The mechanism.** fsck issues an 804,352-byte READ (`tlen=1571`, lba 5581).
  IRIX can only map ~64 pages of DMA at once, so it programs the WD33C93
  transfer count to the first segment — **261,808 bytes** (64*4096 minus a
  336-byte page offset) — and sets up a matching HPC3 DMA descriptor chain.
  The chip serves 261,808 bytes; its count hits 0 (`R_CMDPH=0x46`
  CP_XFER_COUNT) while the target still holds the bus with 542,544 bytes to go.
  The original code just waited there forever → 60-second driver timeout →
  reset → re-issue → re-park. Livelock.
* **IRIX watches the CHIP for the segment boundary, not the DMA channel.** At
  the wedge the HPC3 DMA engine is `dstate=IDLE, bc=0, eox=1, xie=0, ctrl_int=0,
  ctrl_active=0` — it finished its chain and raised NO interrupt, because the
  descriptor's XIE bit was clear. So IRIX did not arm a DMA-completion
  interrupt here; it expects the wd33c93 to interrupt when the count is spent.
* **The CPU is alive while wedged** (kernel RAM at ARM 0x30100000 keeps
  ticking; `alive.py` at its default 0x30740000 reads the PROM stack and is
  misleading — use 0x30100000 for IRIX-kernel liveness). So IRIX is running and
  idle-waiting on I/O, not hung.

## The fix, and exactly what has and has not worked

The fix is in `rtl/scsi/wd33c93.sv`, two halves that mirror IRIS
(`src/wd33c93a.rs`) and the real WD33C93:

1. **In `ST_SAT_PHASE`**, when the transfer count is 0 and the target is still
   in a data phase (after a ~126 us settle window), raise a pause interrupt and
   drop to `ST_IDLE` with `CP_XFER_COUNT` set.
2. **A `C_SEL_XFER`/`C_SEL_ATN_XFER` issued while `R_CMD_PHASE==CP_XFER_COUNT`
   and the target still holds BSY** resumes the same connection instead of
   re-selecting (the resume arm in the R_COMMAND handler).

This changed the failure on the board: the 60-second reset-loop **stopped**
(no more `timeout ... Resetting SCSI bus` on the console). The chip now raises
the pause interrupt: beacon goes from `state=11 cip=1 intp=0` (original) to
`state=0 cip=0 intp=1`. **But IRIX still does not resume** — `sel_xfer` stays
flat, no new command issued, `intp=1` stays set, and it hangs silently at
Phase 1.

**Status codes tried for the pause interrupt, all fits, all on the board:**

| code | for READ | result |
|---|---|---|
| `0x48` (my first guess, direction inverted) | sent 0x48 | wedged, intp=1 stuck |
| `0x19` (S_XFER_DATA_IN, the "xfer-count-done" group) | sent 0x19 | wedged, intp=1 stuck |
| **`0x49`** (IRIS by CODE PATH: READ→send_data_chunked→UNEXPECTED_SEND_DATA) | sent 0x49 | **build 8 — UNTESTED** |

IRIS is unambiguous when read by code path, not by the misleading constant
names: a READ (`data_direction_in`, op 0x28) pauses with
`UNEXPECTED_SEND_DATA`=**0x49**; a WRITE with `UNEXPECTED_RECV_DATA`=0x48
(`src/wd33c93a.rs` ~2236/2272). The committed code (`00de15a`) now sends
0x49 for a read.

## THE ONE UNRESOLVED QUESTION — and why guessing more codes is wrong

Across BOTH failed codes the chip interrupt sat **pending and unserviced**
(`intp=1`). A running interrupt handler clears `int_pending` by reading the SCSI
Status register (0x17) **regardless of the code value** (`wd33c93.sv` ~674). So
`intp=1` stuck means the ISR is **not reading 0x17 for this interrupt** — i.e.
the interrupt may not be reaching/being-serviced at all. If that is true, 0x49
will fail the same way and the real bug is **interrupt delivery**, not the code.

**Build 8 answers this.** It adds beacon words 9-10 (`bcnread.py` decodes them,
version 3):

* word 9 — INT2 state: `scsi_irq`, `scsi_dma_irq`, `IP2..IP6` (`irq_lines`),
  and `int2_state` (L0 mask + L0 source). SCSI is INT2 **L0 bit 1**.
* word 10 — the CPU: decode `pc`, and `cop0` (bit 3 = Status.EXL, bit 12 =
  executing, bits 17:13 = stall).

## Where to go next — a decision tree, not a guess

1. **Read build 8's result first.** `tail b8.console` / `b8.log`; if the fit
   isn't done, wait for it, then `bash scripts/deploy.sh` and let the board
   re-wedge (~8 min; slot 1 is already the reproducer image). Then
   `ssh ... python3 /media/fat/sgidbg/bcnread.py --loop 4 --interval 3`.
   **Confirm word 0 shows `ver=3`** or you are reading an old fit.
2. **If `id1 data_cnt` advances past 261808 / `sel_xfer` climbs** → 0x49 was
   the answer. Confirm fsck runs to completion (framebuffer to a login prompt,
   `diskio.sh` counters climbing) and write it up. Done.
3. **If still wedged**, read words 9-10 and follow the data:
   * `L0_MASK[1]==0` (SCSI masked) → IRIX is NOT using the chip interrupt for
     the DMA wait. The chip-interrupt approach is wrong; look at whether IRIX
     wants the **HPC3 DMA channel** interrupt (XIE) instead — but the
     descriptor had `xie=0`, so also question whether IRIX **polls**. See PC.
   * `L0_MASK[1]==1 && IP2==1` (interrupt asserted to the CPU) but not serviced
     → CPU-side. Check `EXL` (stuck in an exception) and `pc`.
   * **`pc` in a tight range across several reads** → IRIX is POLLING, not
     interrupt-driven, for this transfer. Disassemble the code at that PC
     (`guestmem.py` + `disbin.py`) to see what register/condition it waits on,
     and satisfy THAT. This is the most likely finding and the thing to chase
     before touching any more status codes.
   * `scsi_irq==1 but l0_stat[1]==0` → the interrupt is not reaching INT2 (a
     wiring bug in `sgi_indy.sv`'s `l0_source`).

**Do not change a status code again without a reading that says the code is the
problem.** The evidence currently points AWAY from the code and toward
delivery/polling.

## Instruments (all present)

* **`tools/misterdeploy/bcnread.py`** (on the board at `/media/fat/sgidbg/`) —
  decodes all 11 beacon words. Re-push it after any local edit; the board copy
  goes stale silently.
* The beacon streams to ARM `0x35800000` on `pll_locked` alone, so it reports
  even while the guest is wedged/resetting. It is the lowest-priority `ddr3_mux`
  master, so it cannot perturb the guest.
* `scripts/diskio.sh` — is the core still asking the HPS for blocks (FROZEN =
  wedged). `fbgrab.py`+`fbpng.py --mode text` — read the console. `ddr3_peek.py`
  / `guestmem.py` / `disbin.py` — read and disassemble guest memory while
  wedged.
* Board reproducer: `SGIIndy.s1` → `SGIIndy53-wedged-fsck.img` (pristine + one
  unclean reset). Deploy re-wedges in ~8 min. Do not delete the reproducer
  images.

## Traps already paid for (do not re-pay)

* **A fit is ~40 minutes. Instrument to a definitive reading BEFORE changing
  RTL.** The last session burned three fits guessing one 8-bit value.
* **Killing `quartus_fit` mid-run corrupts `db/`** → the next synthesis fails
  silently (exits non-zero, no error line). Recover with
  `rm -rf db incremental_db` before rebuilding.
* **Do not run the Verilator sim and a Quartus fit at once** — CPU contention
  crashed a fitter mid-routing. Kill `Vsim_top` before fitting.
* **The simulator does NOT reproduce this** — sim's fsck issues sub-segment
  reads (`tlen`<=192) that never exhaust the count mid-transfer. The board is
  the only reproducer. Validate the fix on the board.
* **The beacon's sticky word is polluted by a benign boot-time op=03 stall** and
  latches once; watch the LIVE `id1`/`hpc3`/`int` words, not the sticky.
* **The `SYNC negotiation error, resetting bus` NOTICE at attach is benign** and
  on every boot (target declines SDTR → async mode). Not the wedge.

## Still open, untouched

* **Video / Newport pixel DMA** (the black screen). Separate problem, never
  started. This is what makes a working multiuser board still show nothing.
* **`wd93 ID=6 cmd=0xc9` CD-ROM timeouts** — a CDB-length disagreement
  (initiator sends 6 bytes by group rule, `scsi.v` decodes 0xC0-0xCE as 10-byte
  Apple-CD and parks; real part would answer status 0x87 UNKNOWN_GROUP).
* **`sd_lba` last-match-wins mux** in `sgi_scsi.sv` — wrong if two targets
  request at once.
