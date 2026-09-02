# 31: the fsck wedge's real second half - the driver spins on ASR before it will listen

Follows [30-scsi-wedge-resume.md](30-scsi-wedge-resume.md). Written
2026-09-01/02, while build 10 was in the fitter; the measurement sections are
from the board.

## Where 30 left it, and what its one open question turned out to be

docs/30 ended with the pause interrupt raised and pending (`intp=1`) and IRIX
never servicing it, across three different status codes - and the standing
question "is the interrupt even delivered?". Build 8's words 9-10 (INT2 state
and CPU PC) were fitting to answer that. The answer, measured on the board, is
that **delivery was never the problem**:

    int: scsi_irq=1  L0_stat=02 L0_MASK=83 (scsi src=1 msk=1) IP2=1
    cpu: pc=0x880b2154 EXL=0

Interrupt asserted, unmasked, IP2 up, and the CPU took it - and is executing
kernel text. Six samples of the PC oscillate between 0x880b2154 and
0x880b215c and never leave that range.

## Reading the driver itself, for free

The step that broke the code-guessing loop cost no fit at all: the IRIX 5.3
kernel is sitting on every boot image, and its ECOFF symbol table is intact.

    python3 efsread.py SGIIndy53.img get /unix ./unix     # on the board
    python ecoffsyms.py unix syms 'wd93'                  # externals
    python ecoffsyms.py unix lsyms 'wd93|unex'            # static procs
    python ecoffsyms.py unix dump 0x880b2124 0x684 hi.bin
    python disbin.py hi.bin 0x880b2124

`ecoffsyms.py` is new (tools/misterdeploy/). With it, the wedged PC resolves
to `handle_intr` (the wd93 ISR's dispatcher), and its first basic block is:

    880b2140  lbu  $a2, (ASR)
    880b2144  andi $t6, $a2, 0x30        # CIP | BSY
    880b2148  beqz $t6, proceed
    880b2150  lbu  $a2, (ASR)            # <- the wedge lives here
    880b2154  andi $t7, $a2, 0x30
    880b2158  bnel $t7, $zero, 880b2154
    880b215c  lbu  $a2, (ASR)

**The driver spins until `ASR & 0x30` clears before it reads any register.**
And this model's ASR bit 5 was wired to the SCSI bus BSY line - which a
transfer paused at count zero leaves ASSERTED, by design, for as long as the
pause lasts. So the ISR entered fine and parked in those three instructions
forever. The status code in SCSI Status was never read, which is why 0x48,
0x19 and 0x49 all produced byte-identical wedges. On the real part bit 5
means "Level I command in progress"; IRIS never sets it at all, and the same
IRIX boots there.

The clock keeps running because the 8254 timers interrupt on IP4/IP5, above
LOCAL0's IP2 - which is exactly the "kernel RAM ticking but nothing
happening" liveness signature docs/30 warned about misreading.

## The second bug, found in the same disassembly before it cost a fit

The resume arm committed in `00de15a` triggered on
`R_CMD_PHASE == CP_XFER_COUNT (0x46)`. The real driver's resume path is, in
order (`unex_info` at 0x880b2b8c, then `setdest`):

  1. `save_datap` - reads the count residual out of regs 0x12-0x14 (this
     model decrements them in place, so it reads 0: correct);
  2. `wd93_dma` - builds the next DMA map segment and WRITES THE NEW COUNT
     into regs 0x12-0x14;
  3. writes **Command Phase := 0x45** (0x44 without sync) - not 0x46;
  4. `setdest` - DEST_ID, TARGET_LUN, then COMMAND = 0x08 (SEL_ATN_XFER).

Step 3 means the 0x46 match could never fire: the resuming command would have
taken the fresh-selection path and re-selected a target that is mid-transfer
and holding BSY. The arm now triggers on an explicit `sat_paused` flag
(set at the pause, cleared on resume/selection/reset/abort/completion) - the
RTL equivalent of IRIS's "paused data outstanding" test, which is also not a
phase-register match.

Also confirmed from the same pass, for the record: 0x49 is the right code for
a read (`unex_info`'s 0x49 arm requires the subchan's direction flag 0x40 SET,
phase 0x46 or 0x45; 0x48 requires it CLEAR), the ISR's register reads rely on
data-port auto-increment (0x0F→0x10, 0x16→0x17, 0x12→0x13→0x14 - all held),
and every segment re-arms through the same unex_info path, so the pause code
must keep firing per segment (it does: CP_XFER_COUNT is set on each 1→0
count decrement).

## The fix, first try: build 10, and what it taught about bit 5

`f9b86c6` made ASR bit 5 a constant 0 ("Level I busy, never set, like
IRIS") plus the `sat_paused` resume arm, beacon version 4. **Build 10 broke
the PROM boot**: `Boot device not responding: scsi(0)disk(1)...` before IRIX
ever loaded. The give-up state on the beacon: target 1 parked mid-CDB on the
op=03 REQUEST SENSE (the "benign" boot-time park docs/29's sticky had been
recording on every boot), `R_CMD=04` (Disconnect), `intp=1` abandoned,
counters frozen - and `rst_load` stuck at 2 where build 9's boots counted it
climbing.

The PROM's own binary explains it (boot.rom, all offsets ROM-resident):

* Command issue (`0x9fc1f64c` area) waits on **CIP (0x10)** and handles
  **LCI (0x40) + INT (0x80)** - the eat-stale-interrupt dance the LCI rule
  in the R_COMMAND handler was built from. No bit 5 there.
* But the command-abort CLEANUP (0x9fc1c650..0x9fc1c740) is **gated on ASR
  bit 5**: read ASR, `andi 0x20`; only if set does it Disconnect, eat the
  pending interrupt, re-check, and - if the bus is STILL engaged - call the
  bus-reset routine at 0x9fc1e6fc. That reset is what frees the parked
  target on every boot (build 9's climbing `rst_load`). Bit 5 = 0 made the
  cleanup `beqz` straight past its own recovery.

So the two drivers want different things from bit 5 at chip-identical
moments (idle, INT pending, bus BSY held): the PROM's cleanup needs it SET
for an abandoned connection; IRIX's handle_intr needs it CLEAR at the
segmented-transfer pause. The one state bit that separates those moments is
`sat_paused` - the pause is the only time the chip itself has parked the
connection on purpose, expecting a resume. Hence the final rule:

    ASR.BSY = scsi_bsy && !sat_paused

which is byte-identical to the old always-bus-BSY behaviour everywhere the
PROM can observe (it never triggers the pause path - its transfers never
exhaust the count mid-phase), and reads 0 for exactly the stretch from the
pause interrupt to the accepted resume that IRIX's ISR needs to traverse.

## Build 11 on the board: fixed

Deployed 2026-09-02 00:40 (`7d05b95`, beacon ver 5), against the wedged-fsck
reproducer image. The beacon showed the PROM probe recover exactly as it
used to (one park-recovery reset, counters then quiet at 6/6/7), the
804,352-byte `tlen=1571` read complete (`R_CMDPH=60`, phase back to IDLE),
and then sustained mixed read/WRITE traffic - fsck correcting the
filesystem. The console:

    fsck: checking /dev/dsk/dks0d1s0
    ** Phase 1 - Check Blocks and Sizes       <- wedged here on every
    ** Phase 2 - Check Pathnames                 prior build
    ** Phase 3 - Check Connectivity
    ** Phase 4 - Check Reference Counts
       (3 unref files cleared/reconnected, superblock counts fixed)
    ** Phase 5 - Check Free List
    ** Phase 6 - Salvage Free List
    36791 files 1909517 blocks 2092795 free
    REMOUNT ROOT?  yes
    ***** REMOUNTING ROOT . . . *****
    The system is coming up.

All six phases, a repaired filesystem, root remounted, multiuser boot
proceeding. No timeouts, no reset loop, `intp` never stuck.

**Note on the reproducer:** fsck has now REPAIRED
`SGIIndy53-wedged-fsck.img` and the boot wrote to it - it no longer
reproduces the wedge. To make a new one, start from `SGIIndy53.img`
(pristine) and pull the plug mid-write as before. The bug it reproduced is
fixed, so none is needed for this issue.

## What this cost, and the lesson restated

docs/30's lesson was "instrument before changing RTL". This session's
addendum: **the guest's own driver binary is an instrument that costs
nothing.** Three fits went into guessing a status code the ISR was never
going to read; zero fits went into the disassembly that proved it, named the
actual gate (`ASR & 0x30`), and caught a second latent bug (the phase-match
resume arm) before it burned a board cycle of its own.

## Still open, unchanged from 30

* Video / Newport pixel DMA black screen (`ng1 pixel dma write timeout`) -
  untouched, next in line.
* CD-ROM `cmd=0xc9` CDB-length disagreement (initiator 6 bytes, scsi.v
  decodes Apple-CD 10-byte and parks; real part answers 0x87).
* `sd_lba` last-match-wins mux in `sgi_scsi.sv`.
