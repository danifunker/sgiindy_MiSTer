# 33 - The Newport pixel-DMA black screen: the MC's VDMA engine was never built

**Status: fix implemented and sim-verified; this section's board result is
recorded at the bottom.** Follows [32-resume-newport-dma.md](32-resume-newport-dma.md).
Work done 2026-09-02.

## The symptom

IRIX 5.3 boots to multiuser (docs/29-31), X starts, the screen goes black.
The kernel logs `ng1 pixel dma write timeout`; X draws its hardware cursor
and nothing else. The PROM console, fsck transcript and boot text all render
correctly, so the framebuffer and scan-out path were never suspects.

## The diagnosis, from the driver binary (zero fits spent)

Following the docs/31 method: `efsread.py IMAGE get /unix`, then
`ecoffsyms.py` + `disbin.py` on the ng1 driver. The whole chain:

* **`Ng1PixelDma` (0x88190080)** is the kernel end of every pixel X moves.
  It does NOT program the Newport to fetch anything. It:
  1. takes the mcgdma lock, calls `vdma_set_tlb` (0x880fd418) to program
     the **MC chip's four-entry DMA µTLB** with the user buffer's page
     table, printing `ng1: vdma_set_tlb failed!` if that fails;
  2. builds a descriptor: memory vaddr, `{lines<<16|width}`, `{yinc<<16|
     stride}`, and a GIO address = physical address of the REX3 **HOSTRW
     window** + the page offset X passed in (always HOSTRW0|GO = offset
     0xA30 - IRIS's dma path accepts nothing else);
  3. spins on REX3 `USER_STATUS` (0x133C) bit 3 until the drawing engine
     is idle;
  4. installs `ng1_dma_intr` on **local interrupt vector 4** =
     INT2 **LOCAL0 bit 4**, the MC DMA-done line (`setlclvector(4, ...)`
     at 0x881904dc), starts the `ng1dmatimer` timeout, and calls
     **`MCdma` (0x880fd2b4)**;
  5. sleeps on the `ng1dmaintr` semaphore. If the interrupt never comes,
     the timer fires: `ng1 pixel dma %s timeout`.

* **`MCdma`** programs the MC's GIO64 DMA engine registers (all big-endian
  low-word addresses, base 0x1FA00000): clears CAUSE (0x164), sets CTL
  (0x16C) to XLATE|INT_ENABLE (0x110), writes MEMADR (0x2004), MODE
  (0x2034 = **0x50** for writes = LONG|DIR, **0x52** for reads adds
  TO_HOST), SIZE (0x2014), STRIDE (0x201C), and starts the transfer with
  the write to **GIO_ADRS (0x202C)**. `ng1intrena` is 1 in the shipped
  kernel: the interrupt path is the default, not an option.

* **`ng1_dma_intr` (0x8818be54)** requires `DMA_RUN & 8` (the COMPLETE
  cause mirrored into RUN's low nibble) on success, retires the interrupt
  by writing **0 to DMA_CAUSE**, and wakes the semaphore. On a fault it
  reads the written-back MEMADR, lets `vdma_fault` fix the page, and
  restarts the transfer by writing 1 to **STDMA (0x2044)**.

## What the RTL actually had

Four independent gaps, all in the same chain ([sgi_mc.sv](../rtl/sgi/sgi_mc.sv),
[mc_gio_dma.sv](../rtl/sgi/mc_gio_dma.sv), [sgi_indy.sv](../rtl/sgi/sgi_indy.sv)):

1. **`mc_gio_dma` implemented fill-to-memory only** - the PROM's boot
   memory clear. Mem->GIO and GIO->Mem "reported an instantly-finished
   transfer" without moving a byte, by design, from before the Newport
   existed ("this machine HAS no GIO64 device").
2. **No µTLB translation** (DMA_CTL bit 8). The engine never saw the TLB
   registers at all; IRIX's source addresses are user-space virtual.
3. **The DMA-done interrupt was not wired**: `l0_source` bit 4 in
   sgi_indy.sv was constant zero, and sgi_mc had no interrupt output.
   Even an instantly-completing stub therefore timed X out.
4. **No path from the MC to the Newport**: the engine's only bus master
   went to the RAM arbiter. GIO addresses had nowhere to go.

Plus a fifth, found while building the fix against IRIS's walk loop:

5. **np_rex3's DR_STEP checked word-end before row-end.** In host mode a
   row boundary is a forced word boundary (IRIS breaks with x already
   wrapped to XSAVE and y advanced); the RTL instead ended the primitive
   with x stepped PAST the row. The PROM never saw it - its host-mode
   transfers are one-word primitives - but a DMA'd image hits it on every
   row, and every row after the first would have landed outside its
   rectangle.

## The fix (all against IRIS's src/mc.rs `dma_worker`/`translate_addr`)

* **mc_gio_dma.sv rewritten**: fill (unchanged semantics, now with
  translation), mem->GIO (pack up to 8 bytes MSB-first per 64-bit beat,
  all beats to the same GIO address, short final beat zero-padded),
  GIO->mem (the reverse), and the µTLB: tag = vaddr[31:22], PTE fetched
  from physical memory by the engine itself (ctl bit 0 = 4/8-byte PTE,
  bit 1 = 4/16 KB page), PTE bit 1 valid / bit 2 writable, faults set
  DMA_CAUSE FAULT/TLB_MISS/CLEAN and always interrupt. One-entry
  translation cache. Descending copies stay unimplemented (nothing issues
  them) and keep the old skip-and-report behaviour.
* **sgi_mc.sv**: passes the TLB to the engine; a transfer's end sets
  COMPLETE (only under INT_ENABLE - pollers watch RUN), mirrors cause
  into RUN's low nibble, writes back MEMADR/SIZE/COUNT exactly as IRIS
  does (the ISR's fault-restart path reads them), and drives the new
  `dma_int` level - raised on completion-under-IE or any fault, cleared
  by writing 0 to CAUSE. The engine's final-stride writeback matches
  IRIS: the stride is applied after the LAST line too.
* **sgi_indy.sv**: routes the engine's GIO beats into the Newport
  (anything outside the graphics window answers zero, like the memory
  hole path); wires `dma_int` to L0 bit 4; wires the VC2 vblank level to
  L1 bit 7 (the vertical retrace interrupt, IRIS's exact shape - it was
  also unwired).
* **np_rex3.sv**: a 64-bit VDMA host port. A write beat is IRIS's
  HOSTRW64 push - both host words and GO in one edge, applied under the
  same engine-idle rules as a held CPU write. A read beat is IRIS's
  `dma_read64` - GO first, wait for the engine, then take HOSTRW. And the
  DR_STEP row/word ordering fix above.
* **Beacon**: ver=6, words 11-13 = MC engine state, live descriptor
  addresses, REX3 beat counters. `bcnread.py` decodes them.

## Verification before the fit

* `make -C verilator mcdmatest` - **tb_mcdma.cpp rewritten** as a
  transcription of IRIS's loops including translation: 24 descriptors
  (fill suite unchanged, plus aligned/unaligned/multi-line copies, page
  crossings, 8-byte PTEs, TLB-miss/invalid-PTE/clean faults, both
  directions) x 2 ack timings - all pass, including final-MEMADR
  writeback equality.
* `make -C verilator rex3test` - tb_rex3.cpp grew a VDMA phase: a 32x4
  image streamed as 16 beats through the nd port lands pixel-for-pixel,
  and an OP_READ beat returns the bytes just drawn.
* `tests/run-rex3.sh` - the per-pixel replay of the whole PROM console
  boot, against the DR_STEP reorder.
* Whole-machine PROM boot - the fill engine (boot memory clear) and
  console regression.

## Board result

**Build 12** (commits `19d44ea`+`c8cb25b`): the PROM's 64 MB VDMA clear ran
for real on hardware (beacon: mode=5a, engine idle, memadr advanced, no
fault) and IRIX booted - but the boot then CRAWLED for half an hour and
never started X. The beacon told the story in three lines: `L1_MASK=0xA2`
(IRIX unmasks the retrace bit at gfx init), `l1_stat=0x80` with IP3 held,
and every sampled CPU PC inside `exception_ip12`/`VEC_int`/`intr`. The
"vertical retrace level" I had wired to LOCAL1 bit 7 was VC2's raw blanking
level - high most of the frame and impossible for the ISR to retire - so
the machine spent its life in the interrupt dispatcher.

The correct line is **REX3's VRINT latch**: set at each retrace, held until
the CPU reads STATUS (0x1338) - the read deasserts it, in IRIS and MAME
both. And the consumer confirms it: on IP24, `ng1_init` installs
`ip24_newportInterrupt` on GIO levels 0 and 2, and that handler's FIRST
action is an unconditional STATUS read, then bit 5 dispatches to
`ip24_newportRetrace`. np_rex3 already maintained exactly this latch for
STATUS bit 5; build 13 (`1532d5d`) makes it the interrupt line too.

**Build 13** (`1532d5d`, deployed 2026-09-02): **the IRIX login screen is
on the screen.** The X11 login chooser draws completely - the user icons,
the EZsetup image tile, the IRIS logo, the buttons - and the machine sits
at it healthy. The beacon closes every loop of the diagnosis: `mode=50
xlate=1 ie=1`, `gio_adr=0x1f0f0a30` (REX3 HOSTRW0|GO, exactly as read out
of Ng1PixelDma), engine `beats` == REX3 `wr_beats` == 4802 with `drops=0`
(every beat the MC sent arrived), `cause=0 int=0 eng=IDLE` between
transfers (the ISR retires each one - thousands of interrupt-mode DMAs
with no timeout). The multi-row image tiles also prove the DR_STEP
row-boundary fix: rows land in their rectangle, unskewed.

Fit note: build 13's worst-case setup slack is -0.059 ns on a path
outside the listed core clock domains (build 12 fit the same RTL family
at +0.487) - fitter seed noise, and the board runs; a re-seed is the
cheap fix if instability ever points here.

## Round three: the framebuffer was right and the MONITOR was black

Build 13's login screen was read out of DDR3 by `fbgrab.py` - which
bypasses the display pipeline on purpose. The physical monitor (and the
mrext screenshot API, `scripts/grab.sh`) showed black with the X cursor:
drawing fixed, scan-out interpretation broken. The display chain in
newport.sv hardcoded `did = 0` - fine for the PROM, whose DID table says
"entry 0 everywhere", and wrong for X, which gives every window its own
display ID (VC2's DID table, managed by the kernel's newportCreateDDRN /
newportSetDisplayMode on X's behalf) and its own XMAP mode entry. A
display that reads everything through entry 0 renders X's screen through
a mode X does not maintain: black. The cursor survives because VC2
overlays it past that stage.

Build 14 implements the interpretation stage faithfully to IRIS's
compositor (`compose_pixels` + `decode_did`): the VC2 DID table walker
(sharing the cursor's SRAM port, riding the same blanking window), the
per-pixel mode entry, buf_sel in pixel extraction, popup and overlay
plane priority, packed-RGB expansion, and beacon word 14 (ver=7) showing
the DID and mode entry the screen is actually decoded through. tb_vc2
checks the walker against a decode_did transcription - 1.89M pixel
samples, zero mismatches - and the full PROM-boot replay guards the
DID-off path.

**Build 14 board result (2026-09-02): the login screen is on the MONITOR,
in colour, through the mrext screenshot API - the same channel that
showed black.** The boot console renders through the new stage too (blue
gradient, textport bezel, colour cursor - the DID-off path). At the
login screen the beacon's word 14 confirms the mechanism live:
`did_en=1 walk=RUN did=11 mode=0004ac` - X enabled the DID table and the
bulk of the screen decodes through DID 11's entry (8bpp CI, CMAP page
21), which is precisely what a hardwired DID 0 could never have shown.

Fit note: build 14's worst-case setup is -0.166 ns, same
outside-the-core-domains path family as builds 12/13; every listed clock
domain is positive (min +2.4 ns).

## Round four: the black login panel - FASTCLEAR (and the CID clip)

Build 14 put colour on the monitor and the user pointed at the remaining
wrongness: the clogin panel's background was black. Ground truth came
from booting the SAME disk image in IRIS beside the board (iris-ci +
snapshot): the panel should be white - and IRIS's snapshot showed
identical XMAP mode tables and identical (all-zero) colour-map pages,
which killed every display-side theory. The difference was in the
FRAMEBUFFER: IRIS's panel holds white indices, ours held zeros. The fill
itself drew zeros.

The mechanism, from IRIS's rex3: **FASTCLEAR** (DRAWMODE1 bit 17). When
set - with cidmatch 0xF and no host data - every drawn pixel takes
COLORVRAM replicated to the plane depth, ignoring the colour source, the
logic op, and the patterns. Xsgi fills every large background that way.
np_rex3 accepted the bit and ignored it, so the panel fill used a stale
colour source: index 0. Black.

Implemented (`d9eb4aa`): FASTCLEAR exactly per IRIS (COLORVRAM through
the existing per-depth replication, logicop forced to SRC, patterns
bypassed - the fill fast path still applies), plus the **CID clip**
(CLIPMODE[12:9] != 0xF gates DRAW writes on the aux planes' low nibble,
X's occluded-window clipping) via the dst-read path. The PROM's traced
boot runs everything that draws at cidmatch=0xF, so the gate never
touches the boot path - checked in the replay trace, not assumed.

**Board result (build 15, 2026-09-02): the login screen matches IRIS's
render of the same image.** The panel background is white, the
previously-invisible "Login name:" label and text field show, and every
element sits where the reference puts it. Setup slack +0.404 ns - fully
positive this fit.

## Why it is slow, measured

None of this round's items - and none of "Still open" below - are speed
fixes. The slowness has four independent causes:

* **The CPU sustains roughly a 16 MHz R4400's throughput** (the PROM's
  own measured figure; a real Indy is 100-175 MHz). This dominates boot
  time, fsck time, and X startup. docs/10 has the architecture.
* **Every deploy power-cuts the guest**, so every boot re-runs a full
  fsck over a dirty 2 GB EFS - five to ten minutes at this CPU speed.
  Not a core bug; a clean shutdown before redeploys (or a pre-cleaned
  image) removes it.
* **No Ethernet carrier** adds two-plus minutes of rc-script timeouts.
* **The display refreshes at ~14 Hz** (PIX_DIV=2, newport.sv header):
  everything on screen feels slow regardless of compute. The road to
  ~27 Hz is the frame-buffer fetch-width change described in
  docs/18-mister-integration.md (stop fetching 8 bytes to use 1), and
  the rasteriser's 1-pixel-per-DDR3-round-trip is the same story for
  drawing speed. Real projects, separate from correctness.

## Still open

* The CD-ROM `cmd=0xc9` CDB-length disagreement and the `sd_lba`
  last-match-wins mux (docs/29) - unchanged by this work.
* 64-bit CPU PIO stores to REX3 split wrong (newport.sv takes one word of
  a doubleword store). Nothing in PROM/IRIX 5.3 issues them - o32
  userland cannot, the kernel driver uses word accesses - noted here so
  the next person doesn't rediscover it.
