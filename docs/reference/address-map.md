# IP22 / IP24 address map and registers

All addresses are **physical**. The PROM reaches them through kseg1
(`phys | 0xA0000000`, uncached); kseg0 (`phys | 0x80000000`) is the cached
alias. MIPS is **big-endian** on these machines.

Three sources stand behind this map. The PROM's own MMIO access inventory —
every address the image forms with a `lui`/`addiu` or `lui`/`ori` pair, which
`tools/prom/report.py` writes out as `hardware-011.txt`
([prom/README.md](prom/README.md)) — says what the firmware touches. IRIS, the
Rust Indy emulator this project uses as its behavioural oracle, says what
software expects where nothing else does.

**The third source outranks both of them.** SGI's MC and HPC3 chip
specifications (kept locally, not in this repository) have authoritative
register tables. Where they and the PROM inventory disagreed, the specs were
right every time — the inventory's *addresses* are correct (it is generated
from the image) but several of its *names* are shifted by one slot, which sent
this project looking for RPSS_CTR at MC + 0x80 when the counter is at
MC + 0x1000 and 0x80 is the GIO64 arbiter. `tools/prom/hwmap.py`, which names
the inventory's entries, still carries the shifted names. The tables below are
the specs', and the "In this core" column says what `rtl/` does at each address.

## Top-level map

| Range | Device | In this core |
|---|---|---|
| `0x00000000`–`0x0007FFFF` | Alias of the first 512 KB of low local memory | Decoded by adding `0x08000000`: whatever MEMCFG maps there shows through, and when POST has moved bank 0 away the alias is a hole, as on hardware |
| `0x00080000`–`0x07FFFFFF` | GIO64 / EISA low space (Indigo2) | unclaimed |
| **`0x08000000`–`0x17FFFFFF`** | **Low local memory — the RAM base is `0x08000000`, not 0** | Banks wherever `MEMCFG0/1` put them (`sgi_memmap.sv`); 32, 48 or 64 MB of DDR3, from the OSD. Outside a valid bank: reads 0, writes dropped |
| `0x18000000`–`0x1EFFFFFF` | GIO64 space | unclaimed |
| `0x1F000000`–`0x1F0EFFFF` | Graphics low window | Newport claims it and answers 0 |
| **`0x1F0F0000`–`0x1F0F1FFF`** | **Newport REX3** rendering engine | `rtl/newport/` — [below](#graphics--newport-rex3-0x1f0f0000) |
| `0x1F0F2000`–`0x1F0FFFFF` | Rest of the graphics window | answers 0 |
| `0x1F400000`–`0x1F5FFFFF` | GIO64 expansion slot 0 | Decoded; no card is fitted on MiSTer, so it reads all ones |
| `0x1F600000` | GIO64 expansion slot 1 | unclaimed |
| **`0x1FA00000`–`0x1FA1FFFF`** | **MC** — memory & GIO64 arbiter controller | `sgi_mc.sv`, with the DMA engine in `mc_gio_dma.sv` |
| `0x1FB80000`–`0x1FB8FFFF` | HPC3 PBUS DMA channels 0–7 | Storage that reads back (`sgi_hpc3.sv`) |
| **`0x1FB90000`–`0x1FB91FFF`** | **HPC3 SCSI channel 0 DMA** | Real: `hpc3_scsi_dma.sv` |
| `0x1FB92000`–`0x1FB9FFFF` | HPC3 SCSI channel 1, Ethernet receive and transmit DMA | Storage that reads back |
| `0x1FBB0000`–`0x1FBB001F` | HPC3 general: `INTSTAT`, misc, the serial EEPROM port, `GIO_BUS_ERROR` | `INTSTAT` is generated (below); the rest is storage |
| **`0x1FBC0000`–`0x1FBC0007`** | **WD33C93 SCSI controller 0** | Real: `rtl/scsi/` |
| `0x1FBC8000` | WD33C93 SCSI controller 1 | unclaimed |
| `0x1FBD4000` | SEEQ 8003 Ethernet controller | unclaimed |
| **`0x1FBD8000`–`0x1FBD83FF`** | **HAL2 audio** (PBUS PIO channel 0) | `hal2.sv`; reports no audio present |
| `0x1FBD8400`–`0x1FBD87FF` | PBUS PIO channel 1 — the PROM's HAL2 init writes `0x1FBD8484`–`0x1FBD8500` when audio is present | unclaimed |
| `0x1FBD9000`–`0x1FBD93FF` | PBUS PIO channel 4 — where an Indigo2 keeps its interrupt controller | unclaimed |
| **`0x1FBD9800`–`0x1FBD98FF`** | **IOC2: SCC, keyboard/mouse, panel, `SYS_ID`, INT2, 8254** (PBUS PIO channel 6) | `sgi_ioc.sv`, `sgi_scc.sv`, `i8042.sv`, `pit8254.sv` |
| `0x1FBDC000`–`0x1FBDCFFF` | HPC3 PBUS DMA channel configuration | Storage |
| `0x1FBDD000`–`0x1FBDDFFF` | HPC3 PBUS PIO channel configuration | Storage |
| `0x1FBDE000`–`0x1FBDFFFF` | HPC3 write-only ports (`prom_we`, `prom_swap`, `gen_out`) | Writes accepted and discarded; reads 0 |
| **`0x1FBE0000`–`0x1FBE7FFF`** | **Dallas DS1386-8K RTC + NVRAM** | `sgi_ds1386.sv`, the whole part |
| **`0x1FC00000`–`0x1FC7FFFF`** | **Boot PROM (512 KiB)** | Read from DDR3, where the framework loads `boot.rom` at core start |
| **`0x20000000`–`0x2FFFFFFF`** | **High local memory** — reachable through the TLB only, and where `szmem` maps each bank while sizing it | As low local memory |

The rows marked unclaimed, and every address the table does not list, answer
as an **unclaimed** cycle: a read returns all ones, a write is dropped, and
`sgi_indy.sv` raises `bus_unclaimed` for one cycle so the simulator can list it
on exit. A real machine would take a bus error; this one never does.

---

## MC — Memory Controller, `0x1FA00000`

**Registers are architecturally 64-bit and the PROM always accesses the low
half, i.e. at `reg + 4`.** A decoder that matches only `reg + 0` sees nothing.

The spec says why, and it is not a convention — it is wiring. "The MC is
connected to the least significant 32 bits of the sysad bus… If the processor
is running in big endian mode the odd word addresses, (addresses that end in 4
and 0xc), are used. When the processor is running in little endian mode the
even word addresses, (addresses that end in 0 and 8) are used." A big-endian
access to the even word is not the other half of the register: the real MC
raises `ADDR` in `CPU_ERROR_STAT` for it. `rtl/sgi/sgi_mc.sv` returns zero
there instead, because a spurious bus error is a worse trap than a zero, and
the PROM never does it — all 190-odd MC references in the image end in 4 or
0xc.

| Offset | Name | PROM refs | Notes |
|---|---|---|---|
| `0x00` | `CPUCTRL0` | **59** | Hottest MMIO address in the image. Refresh, endian, parity, GIO/EISA enables, watchdog. `realstart` enables refresh at four lines a burst and sets `MUX_HWM` from the cache line size `Config` reports |
| `0x08` | `CPUCTRL1` | 2 | Written `0x16` early in `realstart` |
| `0x10` | `DOGC` / `DOGR` | — | The watchdog: counts refresh bursts; any write clears it |
| `0x18` | `SYSID` | 3 | Read-only. Spec §5.4: bits `[3:0]` = MC chip revision (0 = Rev A, 1 = Rev B), bit 4 = EISA present, `[31:5]` reserved. `setup_regs` (`0xBFC01B08`) and `0xBFC0AB64` both mask with `0xF` and branch on `rev < 5`, so the revision is free; this core reports **`0x13`**, matching IRIS and MAME's rev C, with the EISA bit set because the IRIX vino driver gates its probe on it |
| `0x28` | `RPSS_DIVIDER` | 2 | Bits `[7:0]` DIV — "the amount to divide the CPU minus one", so 4 means one tick every five CPU clocks. Bits `[15:8]` INC — what to add per tick. The PROM writes **`0x104`**, which the spec gives as the setting for a **50 MHz processor**: that is the register that tells you this machine's R4000 bus clock, and it is why `sgi_mc.sv` treats 50 MHz as the core clock |
| `0x30` | `EEROM` | **20** | R4000 configuration EEPROM, bit-banged. Bits: `[1]`=CS, `[2]`=SCK, `[3]`=DI, `[4]`=DO — confirmed against the PROM's own routines at `0xBFC0A83C`/`0xBFC0A89C`/`0xBFC0A99C`. Only five bits exist; the rest read 0. `rtl/sgi/eeprom_93c56.sv` is the part. **Word `0x11` must read 0**: it is CACHSZ_REG, the secondary cache size in 4 KB pages, and an erased `0xFFFF` tells firmware there is a 256 MB L2 to flush. The core also writes the Ethernet address into words `0x7D`–`0x7F`, as IRIS does; the PROM does not read it from there |
| `0x40` / `0x48` | `CTRLD` / `REF_CTR` | | The refresh counter's preload, and the counter, which counts down from it and reloads |
| `0x80` / `0x88` / `0x98` | `GIO64_ARB` / `CPU_TIME` / `LB_TIME` | 3 / — / 1 | GIO64 arbitration parameters, CPU time slice, long-burst period. The PROM writes `0x401` to `GIO64_ARB` in `realstart` — ONE_GIO for a single-bus Indy, plus HPC at 64 bits |
| `0xC0` / `0xC8` | `MEMCFG0` / `MEMCFG1` | 7 / 2 | SIMM bank descriptors — driven by `szmem`, `init_memconfig`. Encoding below |
| `0xD0` | `CPU_MEMACC` | 7 | `realstart` writes `0x11453433` |
| `0xD8` | `GIO_MEMACC` | 3 | `realstart` writes `0x00034322`. Printed as `GIO_MEMACC:` in the DMA failure dump |
| `0xE0` / `0xE8` | `CPU_ERROR_ADDR` / `CPU_ERROR_STAT` | 5 / 11 | Cleared at reset, and a write to the status register clears both. Nothing in this core sets them |
| `0xF0` / `0xF8` | `GIO_ERROR_ADDR` / `GIO_ERROR_STAT` | 5 / 3 | Printed as `GIO_ERR_ADDR:` / `GIO_ERR_STAT:` in the DMA failure dump. A write to the status register clears both — `prom.map` names `0xF8` `CLR_ERROR_STAT` |
| `0x100` / `0x108` / `0x110` | `SYS_SEMAPHORE` / `LOCK_MEMORY` / `EISA_LOCK` | | A semaphore read returns the bit **and sets it** — the machine's only atomic test-and-set. Both locks reset to 1 (unlocked) |
| `0x10000` + n × `0x1000` | 16 user semaphores | | The same read-and-set, one per 4 KB page (spec §5.18) |
| `0x150` / `0x158` / `0x160` / `0x168` | `DMA_GIO_MASK` / `DMA_GIO_SUB` / `DMA_CAUSE` / `DMA_CTL` | 1 / 1 / 16 / 3 | `DMA_CAUSE` bits 0–2 are FAULT / TLB_MISS / CLEAN and bit 3 COMPLETE; writing it zero retires the DMA interrupt. `DMA_CTL` bit 4 enables that interrupt and bit 8 turns on translation |
| `0x180`–`0x1BF` | DMA TLB, four entries | 2 | Entry n's hi word at `0x180 + 0x10n`, its lo word 8 above. With translation on, the engine's memory-side addresses are virtual and resolve through these |
| **`0x1000`** | **`RPSS_CTR`** | 3 | **Free-running 100 ns counter**, read-only. `DELAY()` and `calibrate_delay()` busy-wait on it; `realstart` waits for it to advance by `0x271` at `0xBFC00500` before touching anything else, so a counter that does not count hangs the PROM before a single character reaches the console. Not at `0x80` — the PROM inventory names it there and is wrong |
| `0x2000`–`0x2070` | **GIO DMA engine** | **43** | `DMA_MEMADR` `0x2000`, `DMA_MEMADRD` `0x2008`, `DMA_SIZE` `0x2010`, `DMA_STRIDE` `0x2018`, `DMA_GIO_ADR` `0x2020`, `DMA_GIO_ADRS` `0x2028`, `DMA_MODE` `0x2030`, `DMA_COUNT` `0x2038`, `DMA_STDMA` `0x2040`, `DMA_RUN` `0x2048`, `DMA_MEMADRDS` `0x2070`. A write to `DMA_GIO_ADRS`, to `DMA_STDMA` with bit 0 set, or to `DMA_MEMADRDS` starts a transfer. `DMA_RUN` bit 6 is set while the engine runs, and its low nibble mirrors `DMA_CAUSE` |

Reference counts are distinct instructions in the PROM's MMIO inventory. Those
for `0x80`–`0x98`, `0x150`–`0x1BF` and `0x1000` were counted again, without
`prom.map`, when their names were corrected; a run without the map finds a few
fewer references at some addresses than the rest of the column records.

The `VDMA Clear failed` path prints, in order: `DMA_RUN:`, `DMA_CAUSE:`,
`DMA_MEMADR:`, `GIO_MEMACC:`, `GIO_ERR_ADDR:`, `GIO_ERR_STAT:` — a ready-made
checklist of what the DMA engine must actually do for the boot memory clear
to succeed. `rtl/sgi/mc_gio_dma.sv` does it: fill for that clear, and
memory-to-GIO and GIO-to-memory copies, translated through the DMA TLB, for
IRIX's Newport driver, which moves every pixel X draws through this engine into
REX3's `HOSTRW` register. Descending copies are not implemented; nothing issues
one. [newport-vdma.md](../design/newport-vdma.md) has the whole contract.

### MEMCFG encoding (from the SGI MC spec)

**The memory decode has to follow these registers.** They are not a report of
where memory is, they are the control: the MC compares address bits `[29:22]`
against the per-bank base field and answers only for a valid bank, and `szmem`
uses exactly that to size the SIMMs — it maps a bank into high memory, writes a
pattern at one offset and looks for it reappearing at another. Where it
reappears is the real SIMM size. A core with RAM hardwired at `0x08000000`
fails every probe and POST prints *"No usable memory found. Make sure you have
a full bank (4 SIMMs)"*. `rtl/sgi/sgi_memmap.sv` is the decoder.

Two more things POST depends on:

- **Reads outside a valid bank return zero**, and writes are dropped. The probe
  at `0xBFC016EC` zeroes four words and then requires them to read back zero
  after writing a pattern elsewhere; unmapped memory answering `0xFFFFFFFF`
  fails the data test before the size test starts.
- **The bank under test is mapped in high memory**, at physical `0x20000000`,
  through four 16 MB TLB pages that `map_high_memory` (`0xBFC01A00`) installs.
  A CPU that cannot form a physical address above `0x1FFFFFFF` never sees any
  of it — which is how this core's CPU, descended from an N64's, first failed
  POST ([chipset.md](chipset.md#the-one-that-was-not-a-chipset-problem-at-all)).

Each register holds two banks, the high half first. Per bank: `[14]` BNK (the
SIMMs carry two sub-banks), `[13]` VLD (bank installed), `[12:8]` MSIZE (the
SIMM size code below), `[7:0]` BASE (compared against address bits `[29:22]`).
BNK is set for the 512Kx36, 2Mx36 and 8Mx36 SIMMs.

| Size code | SIMM | Sub-banks |
|---|---|---|
| `00000` | 256K × 36 | 1 |
| `00001` | 512K × 36 | 2 |
| `00011` | 1M × 36 | 1 |
| `00111` | 2M × 36 | 2 |
| `01111` | 4M × 36 | 1 |
| `11111` | 8M × 36 | 2 |

SIMMs install in groups of four, all the same size, configured **largest-first
at the lowest base address**, each bank aligned to its own size. Address bits
`[31:30]` must be zero for main memory.

This core models single-sub-bank banks only — 4, 16 and 64 MB — so the sizes
the OSD offers are the sums of those it can build: 32 MB is two 16 MB banks, 48
MB three, 64 MB one bank. Changing the size resets the machine, because `szmem`
sizes memory once per boot.

---

## IOC / INT2 / SCC block — `0x1FBD9800`

Byte-wide registers on 32-bit words, stride 4, value in the low byte.

| Address | Register | In this core |
|---|---|---|
| `0x1FBD9830` | SCC channel **B** (tty1, the console) **command** | `sgi_scc.sv` + `z8530_scc.sv` |
| `0x1FBD9834` | SCC channel B (tty1) **data** | `sgi_scc.sv` + `z8530_scc.sv` |
| `0x1FBD9838` | SCC channel A (tty2) command | `sgi_scc.sv` + `z8530_scc.sv` |
| `0x1FBD983C` | SCC channel A (tty2) data | `sgi_scc.sv` + `z8530_scc.sv` |
| `0x1FBD9840` | Keyboard/mouse controller data | `i8042.sv` |
| `0x1FBD9844` | Keyboard/mouse controller command (write) / status (read) | `i8042.sv` |
| `0x1FBD984C` | `GENCON` general control | Storage |
| `0x1FBD9850` | `PANEL_REGISTER` | Storage; resets to `0x01`, bit 0 being "the power is on" |
| `0x1FBD9858` | `SYS_ID` | **`0x26`** on an Indy (IRIS's value for guinness; `0x11` is an Indigo2). **Bit 5 says where the interrupt controller is**: set means INT2 at IOC + `0x80`, clear sends the PROM to `0x1FBD9000` — the Indigo2 location — and its "INT path test" then fails and drops it into an endless diagnostic loop at `0xBFC04070`. `0xBFC03FA0` reads this register to make exactly that choice, and `calibrate_delay` makes it again for the 8254 |
| `0x1FBD9860` | `READ` | Resets to `0x70`: bits 6:4 are the Ethernet and SCSI "power good" lines |
| `0x1FBD9870` | `RESET_REG` (6 bits, mirrored to the front-panel LEDs) | Storage; resets to 0. Nothing drives an LED from it |

### INT2 interrupt controller — `0x1FBD9880`

Byte-wide registers on a 32-bit bus: **stride 4, data in the low 8 bits.** The
PROM reads them with `lbu` at `base + 3`, confirming big-endian low-byte
placement.

| Offset | Register | To the CPU |
|---|---|---|
| `+0x00` | `LOCAL0_STATUS` (read-only) — 24 referencing instructions | `& LOCAL0_MASK` → `Cause.IP2` |
| `+0x04` | `LOCAL0_MASK` | |
| `+0x08` / `+0x0C` | `LOCAL1_STATUS` / `LOCAL1_MASK` | `&` → `Cause.IP3` |
| `+0x10` | `MAP_STATUS` (read-only) | bit 0 → `IP4`, bit 1 → `IP5` |
| `+0x14` / `+0x18` | `MAP_MASK0` / `MAP_MASK1` | `&` → `LOCAL0` bit 7 / `LOCAL1` bit 3 |
| `+0x1C` | `MAP_POLARITY` | stored; selects the active edge of the two GIO expansion lines, neither fitted |
| `+0x20` | timer interrupt clear (write-only) | a 1 bit clears that `MAP_STATUS` counter latch |
| `+0x24` | error status | → `Cause.IP6`; a real zero here, nothing reports a bus error |
| `+0x30`…`+0x3C` | 8254-style timer: counters 0, 1, 2, then the control word | counters 0 and 1 latch into `MAP_STATUS[1:0]` |

`rtl/sgi/sgi_ioc.sv` implements all of it. The three status registers are
driven by their sources and ignore writes — a register that merely read back
what was written would pass the same power-on tests and then lie as soon as
anything real was connected.

Every status bit is a level that follows its device, with two exceptions. The
counter bits in `MAP_STATUS[1:0]` are set by an edge — a counter output is a
pulse — and cleared only by writing `+0x20`. The sources wired: SCSI 0 on
`LOCAL0` bit 1, the MC's DMA-done on `LOCAL0` bit 4, vertical retrace on
`LOCAL1` bit 7, the keyboard/mouse controller and the SCC on `MAP_STATUS` bits
4 and 5, and the two counters. [chipset.md](chipset.md#int2-as-built) has the
table.

Worth knowing before reading anything into a boot log: **the PROM leaves
`LOCAL0_MASK` at zero.** It writes a walking pattern through both masks as an
INT path test, settles on `LOCAL1_MASK = 0x02` (the front panel) and nothing
else, and polls the SCSI chip's AUX STATUS register instead of taking its
interrupt. INT2 is for IRIX; `tests/run-int.sh` is what proves it works.

`+0x30`…`+0x3C` are an 8254-style timer, and it is **not optional**:
`calibrate_delay` (`0xBFC31490`) programs counter 2 in mode 2 with 10000, runs
a fixed 512-iteration loop, latches the counter and reads back how far it got.
That number is how many microseconds the loop took and every later `DELAY()` is
scaled by it. A counter that reads back the byte last written to it returns
`0x2727`, which is greater than 10000, and the routine concludes the
measurement is garbage and starts over — forever. The input clock is 1 MHz, so
one count is one microsecond. `rtl/sgi/pit8254.sv`.

---

## SCSI — WD33C93 × 2 + HPC3 DMA

Read straight out of a descriptor table at `0xBFC7B410` (two 44-byte records,
walked by `FUN_bfc1beec`):

| Field | Controller 0 | Controller 1 |
|---|---|---|
| WD33C93B address/command port | `0x1FBC0003` | `0x1FBC8003` |
| WD33C93B data port | `0x1FBC0007` | `0x1FBC8007` |
| HPC3 DMA control (`0x40` = reset) | `0x1FB91004` | `0x1FB93004` |
| HPC3 DMA byte count | `0x1FB91000` | `0x1FB93000` |
| HPC3 DMA descriptor / CBP | `0x1FB90000` | `0x1FB92000` |
| HPC3 DMA NBDP | `0x1FB90004` | `0x1FB92004` |
| HPC3 DMA PIO config | `0x1FB91010`, `0x1FB91014` | `0x1FB93010`, `0x1FB93014` |
| flags word | `0x60800000` | `0x60800000` |

WD33C93 ports are byte-wide at word stride 4, data in the low byte (`…0003` /
`…0007` are the byte lanes of the words at `…0000` / `…0004`).

**Reset sequence** (`FUN_bfc2fd34`): write `0x40` to the HPC3 DMA control
register, `DELAY(0x19)`, write `0`. That is `ch_reset`, and the HPC3 spec says
it "resets both external controller and this DMA channel" — so the falling edge
of it is what resets the WD33C93 and pulses RST on the SCSI bus. It is also
the register's power-on value, and `ch_active` cannot be set while it stands.

SCSI may be absent — the PROM reports the failure and continues. In this core
controller 0 and its DMA channel are real (`rtl/scsi/`, `hpc3_scsi_dma.sv`),
with disks on IDs 1 and 2 and a CD-ROM on ID 6; controller 1 is not fitted and
its window is unclaimed.

**Channel 0's full register set**, confirmed against the HPC3 chip
specification's section 3.3 rather than against the table above, which names
only the six the PROM's descriptor uses:

| Offset from `0x1FB90000` | Name | |
|---|---|---|
| `+0x0000` | `cbp` | current buffer pointer |
| `+0x0004` | `nbdp` | next buffer descriptor pointer |
| `+0x1000` | `bc` | byte count `13:0`, `XIE` bit 29, `EOX` bit 31 |
| `+0x1004` | `control` | see below |
| `+0x1008` / `+0x100C` | `gio` / `dev` | FIFO pointers; no FIFO is modelled |
| `+0x1010` | `dmacfg` | bit 12 `dma_16`; reset value `0x00000800` |
| `+0x1014` | `piocfg` | PIO timing |

`control`: `0x01` interrupt (read-only, **cleared by reading this port**),
`0x02` endian, `0x04` dir (1 = memory to device), `0x08` flush (**must not
interrupt**), `0x10` `ch_active`, `0x20` `ch_active_mask` (write-only),
`0x40` `ch_reset` (**set at power-on**), `0x80` parity error.

A descriptor is **three** words at a 16-byte alignment — `BP`, `BC`, `DP` — and
a zero byte count is not a transfer: with `EOX` it ends the chain, without it
the next descriptor is fetched immediately. Every receive chain the PROM builds
ends in a zero-count `EOX` descriptor, because the spec tells drivers to append
one. `rtl/sgi/hpc3_scsi_dma.sv`'s header has the whole contract, and
[note 13](../history.md#13) the history of building it.

`INTSTAT` at `0x1FBB0000` has SCSI channel 0 at bit 8, and the spec's own bug
note splits the register: bits 4:0 read at `0x1FBB0000`, bits 9:5 at
`0x1FBB000C`. So channel 0 only ever appears at `+0x0C`. The PROM never looks
there — it polls the WD33C93.

---

## Ethernet — SEEQ 8003

The SEEQ's byte-wide registers are in HPC3's space at `0x1FBD4000`: the PROM's
device probe (`FUN_bfc03eb0`) reads `0x1FBD4007` and writes `0x1FBD4003`
between its SCSI and RTC tests. Its DMA descriptors are in the HPC3 Ethernet
block (`ENETR_CBP` at `0x1FB94000`, `ENETR_NBDP` at `0x1FB94004`), and the
PROM's register test walks a bit through `ENETR_CBP`, looping forever if it
does not read back. The MAC address comes from the RTC/NVRAM device: the
routine at `0xBFC118DC` reads it with `nvram_read(0xFA, 6, …)` — NVRAM offsets
`0xFA`–`0xFF`, device bytes `0x13A`–`0x13F`. May be absent.

**In this core it is absent.** The SEEQ window is unclaimed and the Ethernet
DMA registers are plain storage, which passes the register test and moves
nothing; IRIX attaches `ec0` and logs `ec0: no carrier`. The address is
needed anyway — without an `eaddr` in the environment the IRIX 5.3 installer
dereferences a null pointer (`eeprom_93c56.sv` has the chain) — so
`sgi_ds1386.sv` writes one into those six NVRAM bytes at every reset. It comes
from `games/SGIIndy/boot1.rom`, which the framework uploads at core start and
`scripts/deploy.sh` generates with the MiSTer's own last octet in it;
`sgiindy.sv` falls back to `08:00:69:12:34:56` without it.

---

## RTC / NVRAM — Dallas DS1386-8K, `0x1FBE0000`

**One device byte per 32-bit word, stride 4, data in the low 8 bits:**

```
device byte N  <->  word at 0x1FBE0000 + N*4

device 0x00-0x3F : DS1386 RTC + control registers
device 0x40+     : general NVRAM  ==  the PROM's "offset 0"
```

Both `nvram_read(off,len,dst)` (`FUN_bfc110b0`) and `nvram_write(off,len,src)`
(`FUN_bfc11144`) compute `0xBFBE0100 + off*4` and step by 4 — so the PROM's
NVRAM offset 0 is device byte `0x40`. See [boot-prom.md](boot-prom.md)
for the checksum and validity rules.

`rtl/sgi/sgi_ds1386.sv` is the whole 8 KB part. Device bytes `0x00`–`0x0F`
are the clock: a BCD calendar in `0x00`–`0x0A` (hundredths, seconds, minutes,
hours, day of week, date, month, and a year counted from 1940), the alarm
registers (stored; no alarm fires), and the command register at `0x0B`, whose
bit 7 (TE) freezes the clock while software reads or sets it. `0x10`–`0x3F`
are plain storage. The time comes from the MiSTer's clock — `hps_io`'s RTC, in
local time, loaded when the core starts — and a reset leaves it running;
without that input the clock starts at 1996-02-12 12:00
([r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md), "The
clock"). The NVRAM survives a reset of the core but not a reload, so the first
boot after loading the core prints *"NVRAM checksum is incorrect:
reinitializing"* and rebuilds the environment; [nvram.md](nvram.md) has what
survives what.

The **RTC path test** in the device probe (`0xBFC03F48`) writes `0xA5`/`0x5A`
to device bytes `0x3E`/`0x3F`, reads them back and restores what was there;
failing it prints but does not hang.

---

## HAL2 audio — `0x1FBD8000`

Indirect register file. Direct registers:

| Offset | Register | Behaviour the PROM depends on |
|---|---|---|
| `+0x10` | `HAL2_ISR` | **bit 0 = busy**; the PROM spins on it after every indirect access |
| `+0x20` | `HAL2_REV` | **bit 15 set ⇒ audio not present** — the whole audio path is then skipped |
| `+0x30` | `HAL2_IAR` | writing latches the indirect access |
| `+0x40`…`+0x70` | `HAL2_IDR0`…`IDR3` | indirect data |

Only four indirect addresses are ever written by the PROM: `0x2104` (BRES2
clock select ← 1), `0x2108` (BRES2 inc/mod ← `IDR0=1`, `IDR1=0xFFFF` ⇒ 22050 Hz),
and `0x9100`/`0x9104` (`RELAY_C`, the speaker relay).

The HAL2 init at `0xBFC00BD0` ends by writing a block at
`0x1FBD84A0`–`0x1FBD8500`, which the PROM analysis reads as HPC3's PBUS DMA
descriptors for audio:
`0x1FBD84A0 ← 4`, zeroes over `0x1FBD84A8`–`0x1FBD8500`, then
`0x1FBD848C ← 9`, `0x1FBD8484 ← 0` and `0x1FBD8488 ← 0x83`.

**As built:** `rtl/sgi/hal2.sv` is the register file — ISR, REV, IAR, the four
IDRs, and the indirect registers behind them (the codec and AES control words,
the three Bresenham clock generators, the global DMA enable, drive, endian and
relay words), every transaction completing in the cycle its IAR write lands.
**`HAL2_REV` reads `0xC010`: bit 15 set, audio not present.** The PROM
therefore leaves its HAL2 init at the first branch (`0xBFC00BE0`) without
touching anything, `hinv` lists no audio device, and IRIX's `audio.sm` probe of
the same bit keeps the `kdsp_a2` driver out of the kernel. There is nothing
behind the registers — no PBUS DMA channel feeding HAL2 and no sample path to a
DAC — and `sgiindy.sv` ties the MiSTer's audio outputs to zero.

With bit 15 clear — `0x4010`, IRIS's value — `hinv` prints

```
Audio: Iris Audio Processor: version A2 revision 4.1.0
```

The PROM's node printer at `0xBFC41664` splits `REV` as
`(v >> 12) & 7 . (v >> 4) & 0xF . v & 0xF`, so `0x4010` is `4.1.0`; the `A2` is
a hardcoded string at `0xBFC54B58`, not something the chip reports. The core
reported that for a while, and it is what let IRIX load `kdsp_a2`, which ran
against a HAL2 with nothing behind it and froze the desktop the first time
anything played a sound
([scsi-fit-and-framebuffer-layout.md](../design/scsi-fit-and-framebuffer-layout.md)).

**Clearing bit 15 also commits the PROM to its init.** The routine at
`0xBFC00BD0` then writes `IAR`/`IDR` and spins on `ISR` bit 0 three times.
`hal2.sv` holds that bit at 0, so each spin exits on its first pass, and the
init never reads indirect data back — checked, not assumed: there are exactly
four loads in `0xBFC00BD0`–`0xBFC00D50`, one `REV` and three `ISR`. If the
busy bit were ever made to stick, this **hangs the boot** rather than skipping
audio. Playing the boot tune would take the busy bit, the PBUS DMA path and a
sample pipeline to the DAC.

---

## Graphics — Newport (REX3), `0x1F0F0000`

**Built.** `rtl/newport/` is REX3, VC2, two XMAP9s, two CMAPs and a BT445, and
`sgi_indy.sv` claims `0x1F000000`–`0x1F0FFFFF` for it. Only REX3 is on the bus:

| Address | What | Note |
|---|---|---|
| `0x1F000000`–`0x1F0EFFFF` | graphics low window | reads zero; nothing is fitted there |
| `0x1F0F0000`–`0x1F0F1FFF` | **REX3**, 8 KB | page 0 drawing registers, page 1 config at `+0x1300` |
| `0x1F0F2000`–`0x1F0FFFFF` | unused | reads zero |

**Bit 11 of the offset is the GO bit.** Writing `reg | 0x800` writes the
register and starts the drawing command; there is no command register.

**Everything except REX3 is behind the Display Control Bus**, driven from
`DCBMODE` (`0x1F0F0238`) and `DCBDATA0` (`0x0240`). `DCBMODE[10:7]` is the chip
address: 0 VC2, 1 both CMAPs, 2 and 3 one each, 4 both XMAP9s, 5 and 6 one
each, 7 the RAMDAC. `DCBMODE[6:4]` is the register within the chip and
`DCBMODE[1:0]` the transfer width.

**The window must never be left unclaimed.** An unclaimed read answers
`0xFFFFFFFF`, which makes REX3's `STATUS` at `0x1F0F1338` read busy forever,
and `Ng1Probe` polls it 100000 times before giving up. Both the fitted and the
unfitted paths in `sgi_indy.sv` answer zero for the parts they do not model.

**Finding the board moves the console.** ARCS installs a `DisplayController`
with `ConsoleOut|Output` and the PROM stops printing to the serial port
entirely ([note 16](../history.md#16)). `sgi_indy.sv` takes a `gfx_present`
input so a serial-console test can ask for a machine without a graphics board,
which is what the serial-console scripts in `tests/` do (`--no-gfx`);
`run-newport.sh` and `run-rex3.sh` fit the board. On MiSTer the OSD's
**Graphics board: None** is the same switch.

The MC's DMA engine reaches REX3 through this window too: IRIX aims every
pixel DMA at REX3's `HOSTRW` register. Inside the window only REX3 answers a
DMA beat and the rest acknowledge and drop it; a beat aimed outside the window,
or at a machine with no board fitted, is answered with zeros by `sgi_indy.sv`.

The frame buffer is **not** in this window: it is a private port into DDR3,
two plane sets — the drawing planes and the auxiliary planes, 24 bits each —
each stored as four bytes a pixel on a 2048-pixel stride, two pixels to a
64-bit word, with the auxiliary set 8 MB above the drawing set. The spare byte
of a drawing-plane slot carries a copy of the pixel's window-ID nibble, so a
CID-clipped draw costs one read, not two (`np_rex3.sv`). Newport's VRAM has a
random port and a serial port and this core models both, because the
rasteriser and the display run at the same time.

## Keyboard / mouse / console

PC-style keyboard/mouse controller at IOC `+0x40`/`+0x44`, diagnosed by the
PROM (`_init_mouse` at `0xBFC21E54`); in this core, `i8042.sv`, fed from
MiSTer's decoded `ps2_key`/`ps2_mouse`. Layout table at `0xBFC77EB8` selects
among `DE FR IT DK ES de_CH SE FI GB BE NO PT JP fr_CH US`, chosen by the
`keybd` environment variable.

The serial console is the Zilog 85C30 SCC above, two channels, control/data
pair each. Baud from the `dbaud` / `rbaud` NVRAM environment variables
(default 9600). On MiSTer, channel B — tty1, the console — is wired to the
UART pins (`UART_TXD`/`UART_RXD`) and channel A's receive line is held idle.
