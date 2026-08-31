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

  **THOSE TWO BULLETS WERE RIGHT AND THE CODE ONLY DID HALF OF EACH, WHICH IS
  WHY THIS PARAGRAPH IS HERE.** `ram_inflight` gated the DMA and did not gate
  the CPU, so a CPU access landing inside a DMA transaction re-asserted
  `ram_req` and rewrote `ram_owner_dma` to 0 while the DMA's answer was still
  coming — the CPU then took the DMA's acknowledgement with the DMA's data on
  it, and the DMA got none at all. On hardware that is a PROM panic on a
  freshly loaded pointer, a SCSI command that hangs, and POST's device/cable
  diagnostic failing the disk while the CD-ROM beside it passes.

  It survived because the window is exactly as wide as memory is slow:
  `verilator/sim_ram.v` answers in one cycle and DDR3 takes tens, so it is
  effectively unreachable in simulation and constant on a board. The arbiter is
  `rtl/sgi/ram_arb.sv` now, on its own so it can be driven against a slow
  memory, and `verilator/tb_ramarb.cpp` is that test. **`tests/run-dma.sh`
  passes either way and always did** — it is a test of the engine, not of the
  port, and nothing in it makes the CPU ask for memory while a descriptor fetch
  is outstanding. `docs/18-mister-integration.md` has the whole diagnosis.
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
disk". It does not, and the next section is the record of two wrong theories
about why. What is held instead is something the machine demonstrably does:
`tests/run-scsi.sh` requires the PROM to identify the disk and read its volume
header, and `tests/run-dma.sh` requires 31 properties of the channel. The boot without a disk is unchanged (`tests/run-prom.sh` still
passes), as are `run-int.sh`, `run-scc.sh` and the 240-test CPU suite.

## The message phases, and what they did and did not fix

Built after the engine, in the same session, because the boot's next visible
failure was one bus phase this core had never had:

```
sc0,1,0: SYNC negotiation error, resetting SCSI bus
```

**That line is gone.** Four things were missing and all four are real parts:

1. **`scsi.v` ignored `atn` and had no MESSAGE OUT phase.** It has one now -
   `PHASE_MSG_OUT`, `{msg,cd,io} = 110` - entered from selection when ATN is
   asserted and left when the initiator negates ATN, which is the bus's own
   rule for how a message ends without the target parsing it. Note that this
   file's `PHASE_MESSAGE_OUT` is MESSAGE *IN* in SCSI's naming; every phase
   name in it reads from the target's side.
2. **Select-and-Transfer sends its own IDENTIFY.** That is the entire
   difference between command 0x08 and 0x09, and the PROM issues 0x08. The
   chip builds the message from `TARGET_LUN`; the driver never sees it.
3. **A plain SELECT is two interrupts, not one.** The first says the target
   answered (`0x11`); the second says which phase it is asking for, and a
   driver that has just selected with ATN is waiting for exactly that. This
   model stopped at the first and sat in `ST_IDLE`, so the negotiation waited
   out its 5000-tick timeout on every boot.
4. **A message that is more than an IDENTIFY has to end the exchange.** The
   PROM sent IDENTIFY + SDTR, this target went straight to COMMAND, and the
   driver sat out another timeout waiting for an answer. The target now
   completes and frees the bus instead, and the PROM treats the negotiation as
   concluded and goes on to issue its commands with Select-and-Transfer.

   **This is the one place the target is knowingly not a real disk, and it was
   the right answer only after the standards-correct one was built and
   measured.** A real disk answers an unsupported message with MESSAGE REJECT
   and continues to COMMAND. That was implemented, and it made the machine
   worse: the reject reaches the driver, nothing then sends a CDB, the target
   waits in COMMAND phase, and the PROM prints the same
   `SYNC negotiation error` the message phases were built to remove. Reporting
   the follow-on phase to the driver after the message - which is also real
   chip behaviour, `ST_DONE` handing off to the phase-reporting state - did not
   change it either. Whatever the driver is waiting for at that point is still
   unidentified, and it is on the initiator side, not the target's.

### Three bugs, and the third only showed up in review

**IDENTIFY was sent twice.** A target needs a clock to leave MESSAGE OUT after
the last ACK falls; the sequencer was back in `ST_SAT_PHASE` before that, saw
MESSAGE OUT and REQ still asserted, and sent the message again. The second byte
landed as the first byte of the CDB. It presented as a target that answered
selection and then never recognised a command, with `cmd[0] = 0x80` - and 0x80
is IDENTIFY, which is the clue. `sat_identify_sent` is the fix.

**The service-required status base is 0x88, not 0x80.** The first version
computed `0x80 | phase`, so a MESSAGE OUT request went out as `0x86`. That is
not an unrecognised code - it is close enough to `0x85`, "disconnected", that
the driver answered it by disconnecting, and the failure looked exactly like
the one before the change. IRIS's `src/wd33c93a.rs` carries the list and it is
`0x88 | phase`: `0x88` DATA OUT, `0x89` DATA IN, `0x8A` COMMAND, `0x8B` STATUS,
`0x8E` MSG OUT, `0x8F` MSG IN, while `0x80..0x87` are a different group
entirely. **An off-by-eight in a status code does not produce a nonsense value,
it produces a plausible and wrong one**, which is the kind of bug that survives
a trace being read.

**The reject was never actually on the wire.** `msg_reject` was cleared by the
same `stb_adv` that the phase machine used to read it, one cycle earlier, so
the target announced MESSAGE IN and then sent COMMAND COMPLETE - and the PROM
accepted that and the boot came out clean. It was found by reading the diff,
not by a test, because every test passed. Fixing the race is what revealed that
a genuine reject makes the machine worse, which is the whole of point 4 above:
**a passing test said nothing about whether the thing under it was real.**

### `hinv` lists the disk, and the harness was hiding it

```
>> hinv
                   System: IP22
                Processor: 16 Mhz R4400, with FPU
     Primary I-cache size: 16 Kbytes
     Primary D-cache size: 16 Kbytes
              Memory size: 64 Mbytes
                SCSI Disk: scsi(0)disk(1)
```

**Nothing was ever wrong with the device tree.** `tests/run-scsi.sh` ended its
run on `--stop-on 'Mbytes'`, and the PROM prints the SCSI lines *after*
`Memory size:` - so the simulator was being stopped a few thousand cycles
before the one line anybody was looking for was transmitted. Every "the disk is
missing from the ARCS device tree" claim in this repository was a claim about a
console log that had been truncated by our own test script.

Three theories were built on top of that missing line. The sync negotiation was
not it, this PROM's `hinv` does report SCSI, and the probe was not failing to
run: all three were investigations into a machine that already worked. The
first two were at least disproved cheaply. The third was not, and it would have
cost a lot more, because the next step in the plan was to start building
device-tree registration that the PROM was already doing correctly.

**What settled it was watching the printf, not reading the tree.** The
`--watch` flag added for this run reports every bus access to an address, and
PROM text is uncached, so a watch on a PROM address is a PC watch. Watching
`0xBFC41370` - the instruction that loads `"SCSI Disk"` into the printf
argument - showed one hit. The PROM was printing the line. From there the only
remaining question was where the line went, and the answer was that the harness
had already exited.

The path the watches confirmed, and which the test now asserts as one line:

| Address | What it proves |
|---|---|
| `0xBFC1B854` | the adapter node is created from the template at `0xBFC77D78`, class 4 **type 0x0b** |
| `0xBFC1BAE8` | the disk *controller* node is added under it, type `0x0e` |
| `0xBFC1BB98` | the INQUIRY said fixed disk, so the `"scsidisk"` branch was taken, not `"floppy"` |
| `0xBFC1BBB8` | the disk node itself is added, class 6 type `0x1a` |
| `0xBFC0BEE8` | **zero hits** - no `AddChild` on that path failed |
| `0xBFC41370` | the node printer reached `"SCSI Disk"` |

The node printer is where the chain has to be right rather than merely present.
`FUN_bfc4119c` dispatches on `(class << 24) | type`, so the disk is
`0x0600001A`, and that case at `0xBFC4130C` walks *two* levels up: it bails
unless the node's **grandparent** has type `0x0b`, and then picks CDROM or disk
from the parent's type. So `SCSI Disk: scsi(0)disk(1)` asserts
adapter(`0x0b`) -> controller(`0x0e`) -> disk(`0x1a`) as a shape, which is why
`tests/run-scsi.sh` now expects that exact line instead of a `dks0d1s0`
substring.

**The rule this cost enough to be worth writing down: `--stop-on` fires on the
cycle its substring completes, and a substring is not a line.** Stopping on
`Mbytes` truncated the run; the first fix, stopping on `disk(`, truncated the
line itself and printed `scsi(0)disk(` into a test that was looking for
`scsi(0)disk(1)`. `tests/run-prom.sh` had already written this rule down at the
top of the file for the number after a label, and this was the same rule one
level up. When a run is stopped on console text, stop on text that comes after
everything being asserted, not on the last thing you expect to see.

### DATA OUT works, and finding out cost four bugs

`tests/run-scsiwr.sh` writes a 512-byte block through Select-and-Transfer and
the DMA channel, reads the same block back, and compares. It passes. That is
the first byte this core has ever sent to a disk.

It is also the most productive test in the repository, because **three of the
four bugs it found were in code that every boot runs**, and one of them had
been corrupting every disk read since the day SCSI was fitted.

| Where | What was wrong |
|---|---|
| `rtl/scsi/sgi_scsi.sv` | the target's `sd_buff_din` was unconnected and the module's own output tied to `16'h0000` |
| `rtl/scsi/sgi_scsi.sv` | the replacement mux selected on `sd_wr`, which drops on the first ack |
| `rtl/scsi/wd33c93.sv` | one CDB byte too many, every command |
| `rtl/scsi/wd33c93.sv` | **every DATA IN byte after the first was the previous one** |

**The tie-off was the expected one.** `scsi.v` assembles a written block
correctly and offers it; the wrapper threw it away, so every byte written to a
disk would have arrived as zero. Nothing could see that without writing a byte
and reading it back.

**The mux that replaced it was wrong in a more interesting way.** Selecting the
flush source with `sd_wr` looks right - that is the write request line - but
`scsi.v` clears `io_wr` the moment the ack arrives, and the flush that follows
runs for the whole ack session. The block came back with its first word intact
and 510 zero bytes behind it, which is nearly indistinguishable from the
tie-off it replaced. `sd_ack` is the line that holds for a session, and it is
the one to mux on.

**The extra CDB byte is the same race this file has now hit three times.** The
target holds REQ for one cycle past the last handshake of a phase before it
changes the phase lines, and this sequencer reads REQ as a level, so every
phase needs its own bound:

| Phase | Bound | When it was found |
|---|---|---|
| MESSAGE OUT | `sat_identify_sent` | the IDENTIFY went twice, and the second landed as `cmd[0] = 0x80` |
| COMMAND | `sat_cdb_sent` | here |
| DATA IN / DATA OUT | the Transfer Count | here |

On a WRITE the seventh CDB byte lands in the cycle the target has already moved
to DATA OUT, so the target takes the stale `data_latch` - the control byte,
`0x00` - as data byte 0, every real byte arrives one place late, and the last
one falls off the end. A READ survives it, because an extra initiator ACK
cannot manufacture a byte the target is driving. That is why it had never been
seen.

**And the DATA IN bug is the one to remember.** `scsi.v` serves DATA IN out of
a dual-port RAM whose address advances on the FALLING edge of the previous ACK,
so the byte is not on the bus when REQ rises. Its own `scsi_dpram` header says
so - the timing contract is that the outputs are consistent "no later than 7
clocks after the advance", and the MacLC initiator it was written for holds
DREQ down for `dma_settle` = 8 cycles to cover it. This initiator had no
equivalent and sampled on the cycle it saw REQ.

The result is that **byte 0 of every DATA IN transfer is correct and every byte
after it is the previous one.** Four measured clocks of settle fix it and
`DIN_SETTLE` is six.

Nothing in a boot could see that either, and it is worth being precise about
why, because it is the same reason three times over: the INQUIRY response this
target sends is mostly zeroes, the volume header on `blank8m.img` is entirely
zeroes, and a block of zeroes shifted by one byte is a block of zeroes. **Every
consumer of DATA IN in this project so far has been reading data that could not
show the bug.** A round trip through a pattern with no repeats can, which is
what `fill()` in `tests/scsiwr/scsiwr.c` is for.

### What the test image itself got wrong

Two of the failures on the way were in the test, not the core, and both are
worth knowing before writing another bare-metal image against this engine.

**The channel starts from `NBDP`, not `CBP`.** Priming `cbp` with descriptor 0
and `nbdp` with the EOX marker reads like "here is the chain and here is its
end" and is wrong: the engine fetches from `nbdp`, so it starts on the marker,
retires an empty descriptor, reports the chain complete without moving a byte,
and the WD33C93B then waits forever for an engine that has already stopped.
`tests/dma/dmatest.c`'s `start()` has always done this correctly.

**`ch_reset` resets the chip, not just the channel.** The HPC3 spec's words are
"resets both external controller and this DMA channel", and `wd33c93.sv`
honours them. Writing it between two commands throws away the `CONTROL`
register that selects DMA mode - so the next command silently runs in PIO, on
the DBR path, and completes without the engine moving anything. It completed
and reported `0x16`, which is what a working command looks like.

### The first byte of every block, and the ACK the target never asked for

**The IRIX 5.3 installer's copy to disk was corrupt, and it was one byte per
512-byte block.** This is the fault that `run-scsiwr.sh` passing six phases
could not have caught, and it is worth reading before adding a seventh.

The guest reported it as a header:

```
Illegal f_magic number 0x363, expected MIPSELMAGIC or MIPSEBMAGIC
```

`0x0163` is `01 63`; it read `03 63`. One byte in two.

**A SCSI image on this core is an ordinary file on the SD card, and the
installer copies its miniroot verbatim from the CD, so the CD is a byte-exact
reference and the core can be taken out of the loop entirely.** That is what
`tools/misterdeploy/imgdiff.py` does, and it is the tool that separates a write
fault from a read fault. Of 26,214,400 bytes:

| where the wrong bytes are | count |
|---|---|
| offset `+0x000` of a 512-byte block | 37,925 |
| each of the other 511 offsets | ~1,030 (≈875 wholly different blocks) |

The first byte of nearly every block was wrong and the other 511 were right.
`tools/misterdeploy/firstbyte.py` then asked what landed there, over the 4,924
blocks whose *only* wrong byte was offset 0:

```
source[N+2][0]     4924   (100.0%)
```

Every one, no exceptions. **`scsi.v` buffers writes in two 512-byte halves, so
block N+2 fills the same half as block N** — a byte for N+2 arriving while N is
still being flushed lands at offset 0 of the half being flushed. The measurement
is the mechanism.

**The target's half of this was already right, and its comment says so.**
`scsi.v:474` documents the identical bug from the Mac core this file came from
— *"a 7.5 MB write otherwise perfect except the FIRST WORD of one 512-byte
block ... this window's exact signature"* — and the `wr_pending` term in
`io_busy` fixes it by withdrawing REQ while the fill would enter the half being
flushed.

**What was missing was the initiator obeying the withdrawal.** `wd33c93.sv`'s
`ST_SAT_ACK` raised `scsi_ack` unconditionally, and it is reached from
`ST_SAT_DMA`, whose own comment says the byte "may be several cycles away — the
engine could be part way through fetching a descriptor". During those cycles the
target drops REQ; the initiator acknowledged anyway and the target latched the
byte on the ACK edge. Both ACK states now wait for `scsi_req`.

Three things generalise:

* **This is the third REQ-as-a-level race in this initiator**, after MESSAGE OUT
  (`sat_identify_sent`) and the CDB byte too many. If a fourth appears, look for
  a state that asserts ACK without re-reading REQ.
* **REQ/ACK is interlocked but REQ is not a promise.** A target may withdraw it
  before it is answered, and this one does, for flow control. An initiator that
  treats a REQ it saw N cycles ago as still valid is wrong however short N is.
* **No simulation here could have found it.** `verilator/sim_scsi.h`
  acknowledges a flush instantly, so the fill never gets two blocks ahead of one
  in flight and the window never opens. That is the same shape as the memory
  arbiter fault in `docs/18` and as `fb_linecache` and `DR_FILL` before it: **a
  model kinder than the hardware.** The honest fix for the test is to make
  `sim_scsi.h`'s flush slow and variable, which would turn `run-scsiwr.sh` into
  a real ratchet for this class.

**`-fno-gate` builds `scsi.v` under Verilator 5.020.** The crash that has kept
this file out of every unit test — `V3Gate.cpp:693: No pending substitutions` at
`scsi.v:2761` — is one optimisation pass, and that flag turns it off. With it,
`sgi_scsi.sv` + `wd33c93.sv` + `scsi.v` + `cd_audio.sv` build with `--top-module
sgi_scsi`, which is exactly the right unit for a SCSI test: it holds the
initiator, the targets, the HPS block-device interface and the DMA interface and
nothing else. **A testbench there that flushes slowly is the missing ratchet**,
and it is the next thing to build in this area. (The whole-machine `sim_top`
still faults in a later pass, so `tests/run-*.sh` is unaffected.)

## What to be suspicious of

* **The PROM polls; it does not take interrupts during POST**, and its
  descriptors do not set XIE. Everything the boot proves about this engine, it
  proves about the polled path only. `tests/run-dma.sh` is the only evidence
  the interrupt path works.
* **The data path is tested at width now, and it passed first time.**
  `tests/run-scsiwr.sh` grew from one WRITE(6) of one block to six phases:
  four blocks in one command, WRITE(10)/READ(10), a three-descriptor
  scatter-gather chain read back over two, 16 KB over four descriptors each
  way, and four 2048-byte logical blocks off the CD-ROM over a chain. Every
  byte of all six compares. What that retires is the leading theory about the
  IRIX 5.3 installer's panic - see `docs/08-resume-prompt.md`. What it does
  *not* cover is sustained traffic: the widest single command tested is 16 KB,
  and the installer copies megabytes.
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
