# The HPC3 SCSI DMA engine

**Status: built, and the PROM reads blocks off a disk image through it.** This
was a plan; it is now a record. The parts of the plan that turned out wrong
are still here, marked **WRONG**, the way `docs/12` keeps its retired
diagnosis. A plan quietly rewritten to match what happened teaches nothing.

What changed, in one line: with a disk attached, the boot used to print
`sc0,1,0: cmd=0x12 timeout after 2 sec` and fail every SCSI command; it now
identifies the disk as `dks0d1s0` and reads its volume header. `tests/run-dma.sh`
and `tests/run-scsi.sh` hold both halves of that.

Where it stops now is somewhere else entirely, and that is the last section.

## Where it stopped, before

With a disk attached at ID 1 (`--disk 1=tests/disks/blank8m.img`):

```
[7511634] WR 1fb91010 HPC3-SCSI-DMA  data 00034801    SCSI_DMACFG
[7555154] WR 1fb90004 HPC3-SCSI-DMA  data 08747d20    SCSI_NBDP  - descriptor in RAM
[7555195] WR 1fb91004 HPC3-SCSI-DMA  data 00000010    SCSI_CTRL  - ACTIVE
[7556450] WR 1fbc0000 WD33C93-SCSI   data 41          DESTINATION_ID = 1
[7556623] WR 1fbc0000 WD33C93-SCSI   data 08          Select-and-Transfer
[7559440] RD 1fbc0000 WD33C93-SCSI   data 31          ASR = BSY | CIP | DBR
...                                                   nothing more, for 2 seconds
sc0,1,0: cmd=0x12 timeout after 2 sec.  Resetting SCSI bus
```

`ASR = 0x31` was the whole diagnosis, and it held up. The chip had selected the
target, reached DATA IN, taken the first INQUIRY byte and raised DBR, and
nothing drained it. The driver would not, because it asked for DMA: it writes
`Control = 0x8D`, and `Control[7:5]` is the DMA mode select.

## The registers, confirmed against the spec

Stage 1 of the plan was "confirm the register map against the HPC3
specification PDF before writing the decode". Done, from
`reference/specs/hpc3.pdf` sections 2.2, 2.5 and 3.3. The PDF has no text layer
but its streams are plain Flate; a layout-aware extractor (track the text
matrix, group runs by Y, sort by X) turns it into readable tables, which is
worth knowing because every other spec in that directory is the same shape.

Channel 8 (SCSI0) is at HPC3 + `0x10000` = `0x1FB90000`. **Every offset in the
original table was right**, and the PROM's own device descriptor table at
`0xBFC7B410` lists the same six.

| Offset | Name | Notes |
|---|---|---|
| `+0x0000` | `SCSI_CBP` | current buffer pointer |
| `+0x0004` | `SCSI_NBDP` | next buffer descriptor pointer. Writing it does *not* start anything |
| `+0x1000` | `SCSI_BC` | byte count and flags of the descriptor in flight |
| `+0x1004` | `SCSI_CTRL` | see below |
| `+0x1008` | `SCSI_GIO` | GIO FIFO pointer — storage is enough |
| `+0x100C` | `SCSI_DEV` | device FIFO pointer — storage is enough |
| `+0x1010` | `SCSI_DMACFG` | bit 12 is `dma_16`; the PROM writes `0x00034801`, so **8-bit** |
| `+0x1014` | `SCSI_PIOCFG` | PIO timing — storage is enough |

`0x00034801` decodes as `half_clock`, `hwm = 100` (the reset value),
`dma_16 = 0`, `dma_parity_en = 1`, `dreq_early = 11`. So the 8-bit conclusion
was right, for the right reason.

`SCSI_CTRL` bits, with the spec's own words where they settle something:

| Bit | Name | Behaviour |
|---|---|---|
| `0x01` | `interrupt` | read-only; set on a descriptor with XIE or on a parity error. **"Interrupt cleared on read of this port."** |
| `0x02` | `endian` | **WRONG in the plan**, which called it "byte swap on 16-bit transfers". That is `dma_swap`, dmacfg bit 13. This is the channel's endian mode: little-endian when 1 |
| `0x04` | `dir` | **WRONG in the plan**, which said "IRIS ignores it". The spec does not: "dir=1 is transmit, dir=0 is receive", and "from main memory to device when dir = '1'". Both are followed — see below |
| `0x08` | `flush` | drain and stop. **"Note that an interrupt does not occur automatically when the flush is complete."** The plan's FLUSH-must-not-interrupt note was right and the spec says so outright |
| `0x10` | `ch_active` | 0→1 is the go edge. "HPC3 will turn ch_active to a '0' when the transfer is complete" |
| `0x20` | `ch_active_mask` | write-only; when set, this write leaves `ch_active` alone |
| `0x40` | `ch_reset` | **the plan under-read this.** Not just a reset pulse: "Resets both external controller and this DMA channel. This bit is active (=1) upon **power-on reset**. This must be programmed to a 0 before the ch_active bit becomes active" |
| `0x80` | `parity_error` | read-only, cleared on a read of this port. Always 0 here |

Two consequences of `ch_reset` that were not in the plan and both matter:

* **The power-on value of `SCSI_CTRL` is `0x40`, not zero**, and `ch_active`
  cannot be set while it stands. The PROM clears it early and never trips over
  this, but the reset value is now what the spec says and `tests/run-dma.sh`
  checks it.
* **The falling edge has to reset the WD33C93B and the SCSI bus behind it.**
  This turned out to be load-bearing — see "What went wrong" below.

`dmacfg`'s reset value is `0x00000800`: high water mark `100`, everything else
clear.

## The descriptor

**WRONG in the plan**, which described four words with `+0x0C` as "filler". The
spec says three: "Each descriptor consists of 3 consecutive 32 bit words. All
descriptors must be quadrupleword aligned in main memory, and must not cross a
page boundary." The 16-byte stride is the alignment rule, not a fourth field,
and nothing reads `+0x0C`.

```
+0x00  BP   buffer physical address
+0x04  BC   EOX(31) EOXP(30) XIE(29) ... count(13:0)
+0x08  DP   next descriptor physical address
```

`EOX = 0x80000000`, `XIE = 0x20000000`. Bit 30 the plan called `EOP` is
**`EOXP`, and it is the Ethernet transmitter's end-of-packet** — "This only
applies to ethernet transfers". It means nothing on a SCSI channel.

**The zero-byte-count rule is not a corner case, it is the normal shape of a
receive chain**, and the spec explains why in a section headed `**** BUG ****`:

> Currently, HPC3 has a problem with the end of a descriptor chain. When
> receiving bytes from the SCSI controller, HPC3 will refuse to take the last
> byte (or bytes if in 16 bit mode). There is a way to make HPC3 behave
> correctly. When receiving, always tack on an extra DMA descriptor to the end
> of the chain. If the bytecount in the extra DMA descriptor is zero, there are
> no extra bytes transferred, and HPC3 will merrily transfer all bytes.

The IP24 PROM does exactly that. Watching it build the INQUIRY descriptors is
the clearest statement of the format there is:

```
WR 08747d20 be f0  08747c40      descriptor 0, BP = the buffer
WR 08747d20 be 03  0024          descriptor 0, BC[15:0] = 36 bytes
WR 08747d28 be f0  08747d30      descriptor 0, DP = descriptor 1
WR 08747d20 be 08  00            descriptor 0, BC[31:24] = 0  - no XIE
WR 08747d30 be 08  80            descriptor 1, BC[31:24] = 0x80 - EOX
WR 08747d30 be 03  0000          descriptor 1, BC[15:0] = 0
WR 1fb90004        08747d20      NBDP
WR 1fb91004        00000010      ch_active, dir = 0 (receive)
```

Note what is *not* there: **XIE is clear on both descriptors.** The PROM polls.
The whole interrupt path can be broken and a boot will not notice, which is
what `tests/run-dma.sh` exists for.

## Cache coherence: the question is answered, and the answer is nothing

The plan called this "the open question here, and the one that can waste a
day". It cost about ten minutes, because the PROM's own device table settles
it: every SCSI buffer address it uses is `0xA874xxxx`, and every descriptor
address is written through the same window. That is **KSEG1 — uncached** — so
the descriptors and the DMA buffers are never in the D-cache and there is
nothing to snoop. The trace agrees: the buffer pool is at physical
`0x0874xxxx` and every CPU access to it is an uncached single-word cycle.

This is a property of *this* software, not of the machine. An operating system
that put DMA buffers in KSEG0 would break, and nothing here would detect it.
`tests/dma/dmatest.c` uses KSEG1 for the same reason and says so.

## What was built

### 1. HPC3 is now a bus master, and there is an arbiter

`rtl/sgi/sgi_indy.sv` used to wire main memory straight off the CPU bus:

```systemverilog
assign ram_req   = bus_req && sel_ram && mem_hit;
assign ram_addr  = mem_off;
```

There are now two masters on that port, the CPU winning every tie. Three things
that had to be right:

* **`ram_inflight` covers the gap between a request and its answer.** The CPU's
  bus pulses `bus_req` for one cycle and then waits for `bus_ack`, so a DMA
  cycle started inside that window would be answered on top of a CPU cycle that
  is still outstanding.
* **`ram_owner_dma` remembers whose answer is coming.** `bus_ack` is an OR of
  every device's ack. Without this, a DMA read's `ram_ack` completes the CPU's
  cycle, with the DMA's data on it.
* **A second `sgi_memmap` instance**, not a mux on the existing one. The DMA
  address has to go through the same MEMCFG decode, but the CPU's `mem_hit`
  feeds the grant, and feeding the grant back into the address input closes a
  combinational loop.

An address outside every valid bank is acked with zeros rather than left
hanging, so a descriptor chain pointing at nothing terminates instead of
wedging the run three layers from its cause. `tests/run-dma.sh` checks that.

### 2. The engine — `rtl/sgi/hpc3_scsi_dma.sv`

Fetch, evaluate, run, advance, complete, as planned. `sgi_hpc3.sv` keeps the
decode and routes sub-block 8 to it; every other channel is still storage.

`sgi_hpc3` also gained an `aoff` input. It needs it: the doubleword at
`0x1FB91000` is the byte count *and* the control register, byte enables are
meaningless on a read (`rtl/cpu/r4300_bus.sv`), and the control register clears
its interrupt when read. Without `aoff` a driver reading the byte count
acknowledges an interrupt it never saw.

### 3. The WD33C93B hands bytes over instead of parking on DBR

`Control[7:5] == 0` still means polled I/O and the DBR path is untouched;
anything else hands the byte to the engine. The direction comes from the SCSI
phase. TRANSFER INFO in DMA mode is *not* implemented — the PROM and IRIX both
use Select-and-Transfer.

**On `dir`: both sources are followed, in order.** The spec says `dir` decides;
IRIS takes the direction from the phase. The phase wins here, because it is
what the target is actually driving, and `dir_mismatch` latches the
disagreement rather than hiding it. No disagreement has been observed.

## What went wrong, and what it cost

**The DMA request was a one-cycle pulse.** The CPU's port pulses `bus_req` for
one cycle because it is the only master and the port is always its to take. The
engine copied that shape and it is wrong for the loser of a tie: on any cycle
the CPU wanted memory, the request was simply dropped, and the engine then
waited forever for an answer nobody had heard.

The symptom is worth recording because it is a nasty one. It did not look like
an arbitration bug. It looked like a transfer that moved eight bytes and
stopped — and eight is exactly a doubleword, which sent the first guess
straight at byte lanes and alignment. It was neither: the ninth byte was simply
the first one whose request collided with a CPU cycle, and the count would have
been different on any other run. `dma_req` is now held until `dma_ack`.

**The other one cost nothing, because the test caught it immediately.** The
first version of `tests/dma/dmatest.c` waited for the channel to go idle by
polling `SCSI_CTRL` — and reading that register acknowledges the interrupt the
next check was about. That is not a modelling artefact, it is the register, and
a driver that spins on `ch_active` there loses its own interrupt exactly the
same way. The test now waits on INT2's status register, which has no side
effect, and says why.

## Staging, as it actually went

1. **Confirm the register map.** Done. Four corrections, above.
2. **The arbiter and a bus-master read.** Done. `tests/run-dma.sh` — 31 checks,
   no SCSI in it at all.
3. **DATA IN, one descriptor.** Done. The INQUIRY completes.
4. **Chaining and XIE.** Done, and tested by stage 2's image rather than by the
   boot, because the PROM's descriptors do not set XIE.
5. **DATA OUT.** The path exists and the descriptor side of it is tested;
   **no byte has ever gone out through it**, because nothing in the boot writes
   to a disk and the bare-metal image has no device to write to. This is the
   one part of the engine with no evidence behind it.

**Definition of done, restated honestly.** The plan said "`hinv` lists the
disk". It does not, and the reason is not in this subsystem — see below. What
is held instead: `tests/run-scsi.sh` requires the PROM to identify the disk and
read its volume header, and `tests/run-dma.sh` requires 31 properties of the
channel. The boot without a disk is unchanged (`tests/run-prom.sh` still
passes), as are `run-int.sh`, `run-scc.sh` and the 240-test CPU suite.

## What is between here and `hinv`

**Synchronous transfer negotiation, and it is a target-model problem, not a DMA
one.** The boot now prints:

```
dks0d1s0: volume header not valid          <- correct: blank8m.img is zeroes
sc0,1,0: SYNC negotiation error, resetting SCSI bus
```

and `hinv` lists no disk. The diagnosis is complete and is in the PROM's own
disassembly, so the next session should not have to redo it:

* `0xBFC1CA6C` calls `FUN_bfc1f320(dev, 5000)` — wait for an interrupt, with a
  timeout. It returns 0 on one path, 7 on another, and anything else falls
  through to `LAB_bfc1ccc0`, which issues DISCONNECT and prints the error.
* `0xBFC1CB24` reads the SCSI status register and does `andi $t0, $v0, 7;
  bne $t0, 6` — it is looking for **status `0x8E`, "service required, MESSAGE
  OUT phase"**, so it can send the SDTR message with `FUN_bfc1cf8c`.

So the driver issues SELECT-with-ATN, gets the `0x11` select-complete
interrupt, and then waits for a *second* interrupt that says which phase the
target has asked for. Two things are missing:

1. **`wd33c93.sv` raises no phase interrupt after a plain SELECT.** It reaches
   `ST_IDLE` and stops. It needs to watch for the target's first REQ and
   interrupt with `0x80 | phase`.
2. **`scsi.v` has no MESSAGE OUT phase and ignores `atn` entirely.** Its
   `PHASE_MESSAGE_OUT` is MESSAGE IN in SCSI's naming — `{msg,cd,io} = 111`,
   target to initiator — and only ever sends COMMAND COMPLETE. A real MESSAGE
   OUT is `{msg,cd,io} = 110` and receives, and `PHASE_CMD_IN` is the model to
   copy.

The bus reset that follows the failure now works, and that is new. `scsi_rst`
used to be hardwired to zero, so **nothing in this core could ever free a
wedged target**: after the failed negotiation the target held BSY, the ASR read
`0x20` for the rest of the boot, and every command after it failed. HPC3's
`ch_reset` falling edge now resets the controller and pulses RST on the bus,
which is what the driver's "resetting SCSI bus" message has always claimed to
do. Without it the boot did not get past this point at all.

## What to be suspicious of

* **The PROM polls; it does not take interrupts during POST**, and its
  descriptors do not set XIE. Everything the boot proves about this engine, it
  proves about the polled path only. `tests/run-dma.sh` is the only evidence
  the interrupt path works.
* **DATA OUT has never moved a byte.** See stage 5.
* **The INT2 `intstat` register is wiring, not a tested path.** It is
  implemented per the spec, including the documented read-back bug that splits
  it across `0x1FBB0000` and `0x1FBB000C`, and nothing has ever read it.
* **`ch_reset` is a level in the spec and a pulse here.** Read literally, the
  WD33C93B is held in reset from power-on until the PROM's first write. IRIS
  pulses on the falling edge instead, that is what boots IRIX, and that is what
  is done. The gating half of the rule is real and is enforced.
* **There is no FIFO.** The high water mark, the gio/dev pointers and the
  burst-sizing apparatus are storage. A driver that reasons about fifo
  occupancy would be reasoning about nothing.
* **`use_dma` is sampled live, not latched at the command.** Whether the real
  part latches the DMA mode select when the command is issued is still not
  established. A driver that changed `Control` mid-transfer would tell the
  difference; none does.
