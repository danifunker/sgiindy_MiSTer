# Plan — the HPC3 SCSI DMA engine

**Status: not started.** This is a plan, not a record. When it is built, the
parts that turned out wrong stay in, marked, the way `docs/12` keeps its
retired diagnosis — a plan that is quietly rewritten to match what happened
teaches nothing.

This is the one thing between here and a disk the PROM can see. Everything
upstream of it works: the controller selects a target, walks the COMMAND
phase, and reaches DATA IN.

## Where it stops, exactly

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

`ASR = 0x31` is the whole diagnosis. The chip selected the target, reached DATA
IN, took the first INQUIRY byte and raised **DBR** — "there is a byte in the
data register, come and get it" — and nothing ever does. The driver will not,
because it asked for DMA: it writes `Control = 0x8D`, and `Control[7:5]` is the
DMA mode select (`100`, not the `000` that means polled I/O). IRIS agrees:
`Wd33c93a::use_dma()` is `(regs[CONTROL] >> 5) & 7 != 0`.

Three registers took the setup and there is nothing behind them. `sgi_hpc3.sv`
stores `dma_ctrl[]` and reads it back.

## The registers

Channel 8 (SCSI0) lives at HPC3 + `0x10000`, which is `0x1FB90000`. Offsets
from IRIS's `src/hpc3.rs`; **confirm each against the HPC3 specification PDF in
`reference/specs/` before writing the decode** — that is the project's standing
order of authority, and it has been right every time it disagreed with a
secondary source.

| Offset | Name | Notes |
|---|---|---|
| `+0x0000` | `SCSI_CBP` | current buffer pointer — the physical address the next byte moves to or from |
| `+0x0004` | `SCSI_NBDP` | next buffer descriptor pointer. Writing it does *not* start anything |
| `+0x1000` | `SCSI_BC` | byte count and flags of the descriptor in flight |
| `+0x1004` | `SCSI_CTRL` | see below |
| `+0x1008` | `SCSI_GIO` | GIO FIFO pointer — storage is enough |
| `+0x100C` | `SCSI_DEV` | device FIFO pointer — storage is enough |
| `+0x1010` | `SCSI_DMACFG` | bit 12 is `DMA16`; the PROM writes `0x00034801`, so **8-bit** |
| `+0x1014` | `SCSI_PIOCFG` | PIO timing — storage is enough |

`SCSI_CTRL` bits:

| Bit | Name | Behaviour |
|---|---|---|
| `0x01` | `INT` | set on completion when the descriptor asked for it; **cleared by reading `SCSI_CTRL`** |
| `0x02` | `ENDIAN` | byte swap on 16-bit transfers |
| `0x04` | `DIR` | direction. IRIS ignores it and takes the direction from the SCSI phase; do the same, and log a mismatch rather than trusting either alone |
| `0x08` | `FLUSH` | drain and stop. Must **not** raise an interrupt — IRIX's teardown writes FLUSH after acking the real one, and firing again leaves the bit stuck and the line in a storm. IRIS carries that scar in a comment |
| `0x10` | `ACTIVE` | 0→1 is the *go* edge: fetch a descriptor and run |
| `0x20` | `AMASK` | if set, this write leaves `ACTIVE` alone |
| `0x40` | `RESET` | on its **falling** edge, pulse the WD33C93's own reset |
| `0x80` | `PERR` | parity error, read-only, always 0 here |

## The descriptor

Four words in main memory at `NBDP`, big-endian:

```
+0x00  buffer physical address
+0x04  byte count in bits 13:0, flags in the top bits
+0x08  next descriptor physical address
+0x0C  filler
```

Flags: `EOX = 0x80000000` (end of chain), `EOP = 0x40000000` (end of packet),
`XIE = 0x20000000` (interrupt when this descriptor completes). A descriptor
with a **zero byte count** is not a transfer: if `EOX` it ends the chain, and
otherwise it is a link and the engine fetches `next` immediately without moving
a byte. Getting that wrong hangs the chain on its first link.

`XIE` fires on descriptor completion — byte count exhausted *or* the device
signalling end-of-transfer — and is orthogonal to `EOX`.

## What has to be built

Three pieces. They are separable and each is testable on its own, which is how
this should be staged.

### 1. HPC3 becomes a bus master

**Nothing in this core is a bus master yet.** The CPU is the only thing that
issues a cycle; `sgi_indy.sv` wires `ram_req`/`ram_addr`/`ram_wdata` straight
off the CPU bus:

```systemverilog
assign ram_req   = bus_req && sel_ram && mem_hit;
assign ram_addr  = mem_off;
```

The smallest honest change is a two-master arbiter on **that port only** — the
descriptors and the buffers are in main memory and nothing else needs mastering
— with the CPU winning ties and the DMA taking the port when the CPU is idle.
Do not build a general bus arbiter for this; the Ethernet channels will want
the same port later and the same arbiter will serve, but a full crossbar is
work nobody has asked for.

The engine's addresses are physical; `ram_addr` is an offset from the base of
RAM, so the conversion is the same `mem_off` arithmetic and should be shared
rather than copied.

**Cache coherence is the open question here, and it is the one that can waste a
day.** The CPU's data cache is on. If the PROM's DMA buffers are cached, a
descriptor the CPU wrote may still be in the D-cache when the engine reads it,
and INQUIRY data the engine writes may be invisible to a CPU that has the line.
Before writing any RTL, check what the PROM actually does: the descriptor is at
`0x08747D20` and the trace shows `WR 08747d20 RAM` reaching the bus, which
suggests uncached, but *suggests* is not *is*. If the PROM uses KSEG1 for DMA
buffers there is nothing to do. If it does not, the honest options are to snoop
or to document the hazard loudly — not to quietly assume it away.

### 2. The engine itself

A state machine in `sgi_hpc3.sv`:

```
IDLE      -> wait for the 0->1 edge on SCSI_CTRL.ACTIVE
FETCH     -> read 3 words at NBDP; latch CBP, BC, flags, next NBDP
              zero count + EOX     -> COMPLETE
              zero count, no EOX   -> FETCH again (link descriptor)
RUN       -> one byte per handshake with the WD33C93:
              DATA IN  : take the byte, write it to CBP
              DATA OUT : read CBP, hand it over
             CBP++, BC--
              BC hits zero -> EOX ? COMPLETE : FETCH
COMPLETE  -> clear ACTIVE; if XIE, set SCSI_CTRL.INT and raise
             HPC3 INTSTAT bit SCSI0_DMA
```

The device can also end a transfer early — a MODE SENSE response shorter than
the allocation length — so an end-of-transfer from the chip has to complete the
descriptor even with byte count left. IRIS forces `bc_done` for channels 8 and
9 on `caller_eop` for exactly that reason.

### 3. The WD33C93 hands bytes over instead of parking on DBR

`wd33c93.sv`'s `ST_SAT_PHASE` currently latches a DATA IN byte and sets `dbr`,
then waits forever. In DMA mode it should instead handshake with the engine:

```systemverilog
input  logic       dma_ready,   // the engine has a descriptor and can move a byte
output logic       dma_req,
output logic       dma_dir_in,  // from the SCSI phase, not from SCSI_CTRL.DIR
output logic [7:0] dma_wdata,
input  logic [7:0] dma_rdata,
input  logic       dma_ack,
output logic       dma_eop      // the target ended the phase
```

PIO mode stays exactly as it is — `Control[7:5] == 0` keeps the DBR path — so
this is an addition, not a replacement, and the existing SCSI tests keep
running through the old path.

Interrupt-wise, `l0_source[1]` in `sgi_indy.sv` is the SCSI chip's `irq` today.
It becomes the OR of that and the HPC3 DMA interrupt, which is what IRIS's
callback does: `Scsi0 => intstat & (SCSI0_DEV | SCSI0_DMA) != 0`.

## Staging, with a test at each step

Each stage should end somewhere the boot is measurably further along, because
a subsystem this size built in one go has no bisection points.

1. **Confirm the register map against the HPC3 spec PDF.** No RTL. Correct the
   table above where it is wrong, and say so.
2. **The arbiter and a bus-master read.** `sgi_hpc3.sv` fetches the descriptor
   at `NBDP` on the ACTIVE edge and exposes it read-back through `SCSI_CBP` and
   `SCSI_BC`. A bare-metal image in the shape of `tests/int/` writes a
   descriptor into RAM, starts the channel, and reads back what the engine
   fetched. This proves mastering and the descriptor format with no SCSI in the
   picture at all.
3. **DATA IN, one descriptor, no chain.** The INQUIRY completes and the PROM
   stops printing the two-second timeout. This is the first point at which the
   boot changes.
4. **Chaining and `XIE`.** The interrupt on completion, and the link-descriptor
   case. MAME's `indy_indigo2.cpp` carries the note "Fix SCSI DMA to handle
   chains properly", so it is fiddly there too; expect to spend time here and
   do not take a passing INQUIRY as evidence that chaining works.
5. **DATA OUT.** Nothing in the boot path writes to a disk, so this needs its
   own bare-metal test rather than the PROM.

**Definition of done:** `hinv` lists the disk, and a new `tests/run-scsi.sh`
holds it there. Not "the INQUIRY completed" — the visible result is the test.

## What to be suspicious of

- **The PROM polls; it does not take interrupts during POST.** `XIE` and the
  INTSTAT bit can be completely broken and the INQUIRY will still work. Do not
  conclude the interrupt path is right because the disk appeared — that is the
  same mistake `docs/12` records, in a different subsystem.
- **IRIS is a tiebreaker, not a specification.** Its `process_scsi_command`
  runs a whole SCSI command atomically on the host side and then pushes the
  result, which is not what the wire does. Take the register semantics, the
  descriptor format and the scars from it — the FLUSH-must-not-interrupt note
  is worth the whole file — and take the phase-by-phase behaviour from the bus.
- **`use_dma()` is read at command time in IRIS.** Whether the real part
  latches the DMA mode at the command or samples it live is not established
  here, and a driver that changes `Control` mid-transfer would tell the
  difference. Assume latched, write it down as an assumption.
