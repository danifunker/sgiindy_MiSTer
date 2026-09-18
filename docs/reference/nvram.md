# NVRAM — where the PROM environment lives, and what survives

The PROM keeps its environment — `setenv`, the boot variables
(`SystemPartition`, `OSLoadPartition`, …), the console selection, the monitor
type, `netaddr` — in the NVRAM of the Dallas DS1386 real-time clock, and so
does the machine's Ethernet address. In this core that NVRAM **survives a reset
of the core but not a reload**: nothing saves it to the SD card, so the first
boot after the core is loaded prints

```
NVRAM checksum is incorrect: reinitializing.
```

and writes a default environment, and a `setenv` made after that lasts until
the core is loaded again.

## What survives what

A **reset** here is anything that asserts the core's reset: the OSD's
**Reset** and **Reset and close OSD**, a change of the **Memory** option, and
a PROM download (the OSD's **Load PROM**, or the framework's own load of
`boot.rom` at start). A **reload** is loading the core again from the MiSTer
menu, or powering the MiSTer off.

| State | Where | Reset | Reload |
|---|---|---|---|
| The PROM environment | DS1386 NVRAM, device bytes `0x40`–`0x13F` (the PROM's offsets `0x00`–`0xFF`) | kept | lost — the PROM rebuilds it |
| The rest of the NVRAM, and device bytes `0x10`–`0x3F` | DS1386 | kept | lost |
| The Ethernet address | NVRAM offsets `0xFA`–`0xFF` | rewritten, with the same value | written again from `boot1.rom` |
| The time of day | DS1386 clock registers, device bytes `0x00`–`0x0A` | keeps running once the MiSTer has set it | set from the MiSTer's clock when the core starts |
| The R4000 configuration EEPROM | 93C56 behind `MC + 0x30` (`eeprom_93c56.sv`) | kept; words `0x7D`–`0x7F` rewritten with the Ethernet address | back to erased (`0xFFFF`), except word `0x11`, which powers up 0, and words `0x7D`–`0x7F`, written again |
| HPC3's serial EEPROM port | `0x1FBB0008` | cleared | cleared |

Why, in the RTL:

- **The NVRAM's banks have no reset path at all** (`sgi_ds1386.sv`). They
  power up zero, which is what a reload gives the PROM; the tag byte then reads
  0 where the PROM wants 8, so it rejects the image whatever the checksum says.
- **The clock registers are reset only until the MiSTer has sent its time.**
  `hps_io`'s RTC output carries the MiSTer's own clock, in local time, sent by
  Main once when the core starts; the part loads it, and from then on a reset
  leaves the time running the way a battery-backed part ignores the machine's
  reset. Without it the clock starts at 1996-02-12 12:00.
  [r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md)
  ("The clock") has why, and why IRIX wants `TZ=GMT0` to show the MiSTer's
  time.
- **The Ethernet address is seeded, not stored.** `sgiindy.sv` latches it from
  `games/SGIIndy/boot1.rom`, which the framework uploads at `ioctl` index
  `0x40` at every core start and `scripts/deploy.sh` generates with the
  MiSTer's own last octet in it (without the file, `08:00:69:12:34:56`).
  `sgi_ds1386.sv` writes it into device bytes `0x13A`–`0x13F` in the three
  clocks after every reset, and `eeprom_93c56.sv` into its words `0x7D`–`0x7F`.
- **The EEPROM's array has no reset path either**, and its power-up contents
  are the erased part plus `CACHSZ_REG` = 0 — no secondary cache, which the
  PROM reads because `Config` reports none.
- **`0x1FBB0008` is a plain register** in HPC3's store, which a reset sweeps
  to zero. The PROM never forms its address, and a `setenv` does not touch it
  (below).

## Which store holds the environment, and how that was settled

**Not by reading.** SGI machines have more than one non-volatile store, and the
obvious documentation is about the wrong one.

IRIS, the emulator this project uses as its oracle, persists **two** files,
each loaded at startup if it exists and written back only on an explicit
command:

| IRIS file | chip | what its own comments say it holds |
|---|---|---|
| `nvram.bin` | `Ds1x86` — the DS1386 RTC | the RTC's 8 KB of NVRAM |
| `nveeprom.bin` | a 93CS56 at **`0x1FBB0008`**, on the HPC3 side | "env vars + MAC @ words 0x7D-0x7F" |

and its MC-side 93C56 — the R4000 configuration EEPROM, which is the one this
core models in `rtl/sgi/eeprom_93c56.sv` — has no persistence at all.

Taken at face value that says the environment is in the HPC3-side EEPROM. It
is not, on an IP24. IRIS's `src/config.rs` calls that file the "Indigo2
motherboard EEPROM", and the measurement agrees with the file name rather than
with the comment. Booting to the Command Monitor and typing
`setenv zork frobozz` with both candidate addresses watched:

```
  1fbe0100  62 hits      <- the DS1386's NVRAM
  1fbb0008   0 hits      <- the HPC3-side 93CS56
```

**So on this machine the environment is the DS1386's NVRAM and nothing else.**
That also agrees with the PROM's own primitives: `nvram_read` and `nvram_write`
(`0xBFC110B0` / `0xBFC11144`) both compute `0xBFBE0100 + off*4`.

The Ethernet address is there too, not in either EEPROM. The PROM builds
`eaddr` from NVRAM offsets `0xFA`–`0xFF` — the routine at `0xBFC118DC` is
`nvram_read(0xFA, 6, …)` — and the machine said so before the disassembly did:
with the address in the MC-side EEPROM at the words IRIS uses, `printenv`
listed no `eaddr` at all, and the IRIX 5.3 installer, which asks the PROM for
one, dereferenced the null it got back. `eeprom_93c56.sv`'s header has that
chain.
The core still writes the EEPROM copy, because IRIS writes both and two copies
that disagree are a trap for whoever reads them next.

## The NVRAM in the RTL

`rtl/sgi/sgi_ds1386.sv` models a Dallas DS1386-8K: 8192 device bytes, of which
`0x00`–`0x3F` are the clock and its control registers and `0x40`–`0x1FFF` are
the NVRAM proper. It sits in HPC3's battery-backed-RAM window at `0x1FBE0000`
with **one device byte per 32-bit word**, so 8 KB of device occupies 32 KB of
address space. Only device bytes `0x00`–`0x0F` are clock registers, held in
flip-flops of their own; everything from `0x10` up is one store.

That store is **two banks with exactly one reader and one writer each**, and
that is not an accident:

```systemverilog
logic [7:0] nv0 [0:4095];        // device bytes whose index bit 0 is 0
logic [7:0] nv1 [0:4095];        // ...and whose index bit 0 is 1
```

It used to be one `logic [7:0] nv [0:8191]`. That array had four ports —
`dev_rd(0)` and `dev_rd(1)` each read it and the unrolled write loop wrote it
twice — a memory block has two, so Quartus could not infer one and built all
65,536 bits out of flip-flops: **65,713 registers and 30,430 ALUTs, more logic
than the entire R4300i** the core then had, and on its own most of what made
the design miss the device. Worse, Quartus said *nothing*: no "uninferred RAM
logic" message, no warning, just the registers. The split costs nothing,
because the bit that separates the two halves of a doubleword access is bit 0
of the device index; `sgi_ds1386.sv`'s header has that, and the read-path shape
inference also needs.

**A port added carelessly here costs more logic than the CPU, and the tool
will not tell you.** That is the constraint that decides how persistence can be
added.

## Adding persistence

Nothing saves or loads the NVRAM today: `CONF_STR` has no slot for it and the
simulator has no option for it. Whatever adds it has to respect three things:

- **Share the two ports; do not add a third.** A save reads one byte per clock
  and a load writes one per clock, and neither needs to run while the guest is
  touching the device, so both fit behind a mux in front of the ports the bus
  already uses. The Ethernet-address seed already shares the write port that
  way, as one plain enabled store per bank with only its address and data
  muxed. After a synthesis, check `Total registers` in the map summary: a jump
  of about 65,000 means the banks are flip-flops again.
- **Keep the file a plain 8192-byte device image**, byte N at offset N, and do
  the de-interleave into the banks at the port. `tools/prom/nvram.py` verifies
  that format, and `xxd` reads it. The clock is not in the banks, so a load
  cannot disturb the time, which comes from the MiSTer anyway — and should: a
  restored clock would be wrong by however long the machine was off, which is a
  worse lie than a fixed date, because software cannot tell it is stale.
- **The PROM is the acceptance test.** A boot from a saved image must not print
  *"NVRAM checksum is incorrect: reinitializing."* That is a sharper check than
  reading a `setenv` back: it is the PROM's own opinion of every byte of the
  checksummed window, and it catches a de-interleave error that happens to
  round-trip.

On MiSTer the usual shape is a virtual drive — an `S` entry in `CONF_STR`, a
load when that slot's image is mounted (sixteen 512-byte blocks through
`sd_lba` and `sd_buff_*`), and a save when the OSD closes or on an explicit
menu item — with the block-to-byte conversion in `sgiindy.sv` and nothing but
wires through `sgi_indy.sv`. `sgiindy.sv` already declares four `hps_io`
virtual drives and uses slots 1–3 for SCSI; slot 0 is free.
