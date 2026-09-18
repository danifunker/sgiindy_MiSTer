# IP24 Hardware Reference (from the PROM)

Everything here is what **this PROM actually touches**, in the order it touches
it. Addresses are **physical**; the PROM reaches them through kseg1
(`phys | 0xa0000000`). Register names marked ✔ come from hand annotations in
`prom.map` or from the PROM's own diagnostic strings; the rest are named from
the standard IP22/IP24 layout and are consistent with observed use.

Full per-address inventories are `hardware-011.txt` and `hardware-007.txt`,
which `tools/prom/report.py` writes ([README.md](README.md)). The MC and INT2
tables below use the chip specifications' names, not the older ones the
inventory still prints for a few of those registers — see the notes under each.
What this core answers at each address is in
[../address-map.md](../address-map.md).

---

## Address map

| Range | Device |
|---|---|
| `0x00000000`–`0x07ffffff` | GIO64 / EISA low space (Indigo2) |
| **`0x08000000`–`0x0fffffff`** | **Main DRAM** — RAM base is `0x08000000`, not 0 |
| `0x10000000`–`0x1effffff` | GIO64 expansion slot windows |
| `0x1f000000`–`0x1f0effff` | Graphics low window (VC1 / XMAP / DAC) |
| **`0x1f0f0000`** | **GR2 / REX rendering engine** ✔ (from 5.0 strings) |
| `0x1f400000`/`0x1f600000` | GIO64 expansion slots 0 / 1 |
| **`0x1fa00000`** | **MC** — memory & GIO64 arbiter controller |
| `0x1fb80000`–`0x1fbfffff` | **HPC3** peripheral controller and its device windows |
| **`0x1fbe0000`** | **DS1386-8K RTC + NVRAM** |
| `0x1fc00000`–`0x1fc7ffff` | Boot PROM (this image) |

PROM working RAM lives at phys `0x08740000` (`0xa8740000` uncached /
`0x88740000` cached) — 423 distinct locations, 1467 accesses. A core does not
need to model this; it is ordinary DRAM.

---

## MC — Memory Controller, `0x1fa00000`

Registers are 64-bit; **the PROM always accesses the low half at `reg + 4`**.
A core that decodes only `reg + 0` will see nothing.

| Offset | Name | Refs | Notes |
|---|---|---|---|
| `0x00` | `MC_CPUCTRL0` | **59** | Hottest MMIO address in the image. Refresh, endian, parity, GIO/EISA enables, watchdog. Diagnostic string: *"basic_DMA_setup: set CPUCTRL0 = %x (refresh 4 lines)"*, *"(Snoop %s)"* |
| `0x08` | `MC_CPUCTRL1` | 2 | Written `0x16` early in `realstart` |
| `0x10` | `DOGC` / `DOGR` (watchdog) | — | |
| `0x18` | `MC_SYSID` | 3 | Read by `setup_regs` |
| `0x28` | `RPSS_DIVIDER` | 2 | Divider and increment for the 100 ns counter; `realstart` writes `0x104` |
| `0x30` | `EEROM` | **20** | Serial EEPROM bit-bang (CS/SCK/DI/DO). Used by `init_rom` path |
| `0x80` | `GIO64_ARB` | 3 | GIO64 arbitration; `realstart` writes `0x401` |
| `0x98` | `LB_TIME` | 1 | GIO64 long-burst period |
| `0xc0` | `MC_MEMCFG0` | 7 | Banks 0/1 — driven by `szmem`, `init_memconfig` |
| `0xc8` | `MC_MEMCFG1` | 2 | Banks 2/3 |
| `0xd0` | `MC_CPU_MEMACC` | 7 | CPU memory timing; `realstart` writes `0x11453433` |
| `0xd8` | `MC_GIO_MEMACC` | 3 | Printed as `GIO_MEMACC:` in the DMA failure dump; `realstart` writes `0x00034322` |
| `0xe0` | `CPU_ERROR_ADDR` ✔ | 5 | |
| `0xe8` | `CPU_ERROR_STAT` ✔ | 11 | Cleared at reset |
| `0xf0` | `GIO_ERROR_ADDR` ✔ | 5 | Printed as `GIO_ERR_ADDR:` |
| `0xf8` | `CLR_ERROR_STAT` ✔ | 3 | The spec's `GIO_ERROR_STAT`; a write clears it. Printed as `GIO_ERR_STAT:`; cleared at reset |
| `0x150`/`0x158`/`0x160`/`0x168` | `DMA_GIO_MASK` / `DMA_GIO_SUB` / `DMA_CAUSE` / `DMA_CTL` | 1 / 1 / 16 / 3 | The DMA engine's GIO address mask and substitute, its cause register, and its control (interrupt enable, translation) |
| `0x180`/`0x188` | DMA TLB entry 0, hi / lo | 1 / 1 | The first of four entries at `0x180`–`0x1bf` |
| `0x1000` | `RPSS_CTR` | 3 | Free-running 100 ns counter — backs `DELAY` / `calibrate_delay`; `realstart` spins on it at `0xbfc00510` |
| `0x2000`–`0x2048` | GIO DMA engine | 43 | `DMA_MEMADR` and `DMA_RUN` are here (`DMA_CAUSE` is at `0x160`); all three names appear verbatim in the PROM's `VDMA Clear failed` dump |

The rows for `0x80`, `0x98`, `0x150`–`0x188` and `0x1000` are the MC
specification's names. The inventory (`tools/prom/hwmap.py`) names those
addresses a slot out of step — `RPSS_CTR` at `0x80`, the arbiter at `0x150`,
memory parity at `0x180` — and `realstart` itself says which is right: it
writes `0x401` to `0x1fa00084` and then spins on `0x1fa01004` waiting for it to
count. The reference counts for those rows were taken again, without
`prom.map`, when they were renamed.

The `VDMA Clear` failure path prints, in order: `DMA_RUN:`, `DMA_CAUSE:`,
`DMA_MEMADR:`, `GIO_MEMACC:`, `GIO_ERR_ADDR:`, `GIO_ERR_STAT:` — a ready-made
checklist of what a core must implement for the memory clear to succeed.

---

## HPC3 — `0x1fb80000`, and INT2

Named by `prom.map`:

| Address | Name ✔ |
|---|---|
| `0x1fbb0000` | `INTSTAT` |
| `0x1fbb0010` | `GIO_BUS_ERROR` |
| `0x1fbd9850` | `PANEL_REGISTER` |
| `0x1fbd9858` | `SYS_ID` |

### INT2 interrupt controller — `0x1fbd9880`

Byte-wide registers on a 32-bit bus: **stride 4, data in the low 8 bits**
(the PROM reads them with `lbu` at `base + 3`, confirming big-endian low-byte
placement).

| Offset | Register |
|---|---|
| `+0x00` | `LOCAL0_STATUS` (read-only) — 24 referencing instructions |
| `+0x04` | `LOCAL0_MASK` |
| `+0x08` | `LOCAL1_STATUS` |
| `+0x0c` | `LOCAL1_MASK` |
| `+0x10` | `MAP_STATUS` (read-only) |
| `+0x14` / `+0x18` | `MAP_MASK0` / `MAP_MASK1` |
| `+0x1c` | `MAP_POLARITY` |
| `+0x20` | timer interrupt clear (write-only) |
| `+0x24` | error status |
| `+0x30`…`+0x3c` | 8254-style timer: counters 0, 1, 2, then the control word |

The layout from `+0x10` on is IRIS's and this core's (`rtl/sgi/sgi_ioc.sv`);
the inventory's older names put the timer clear at `+0x30`, the error status at
`+0x34` and the counters at `+0x40`. `calibrate_delay` (`0xbfc31490`) settles
it: it takes the INT2 base from `SYS_ID` bit 5, adds `0x30` for the 8254,
writes the control word at `+0x3f` and counter 2's LSB/MSB pair at `+0x3b`.

The PROM prints *"Interrupt mask registers (INT%d)"* and *"MIPS cause
register"* in its diagnostic dump.

---

## SCSI — WD33C93B × 2 + HPC3 DMA

`FUN_bfc1beec` walks a **descriptor table at `0xbfc7b410`**, two records of 44
bytes. This is the authoritative wiring, read straight out of the data:

| Field | Controller 0 | Controller 1 |
|---|---|---|
| WD33C93B address/command port | `0x1fbc0003` | `0x1fbc8003` |
| WD33C93B data port | `0x1fbc0007` | `0x1fbc8007` |
| HPC3 DMA control (`0x40` = reset) | `0x1fb91004` | `0x1fb93004` |
| HPC3 DMA byte count | `0x1fb91000` | `0x1fb93000` |
| HPC3 DMA descriptor / CBP | `0x1fb90000` | `0x1fb92000` |
| HPC3 DMA NBDP | `0x1fb90004` | `0x1fb92004` |
| HPC3 DMA PIO config | `0x1fb91010`, `0x1fb91014` | `0x1fb93010`, `0x1fb93014` |
| flags word | `0x60800000` | `0x60800000` |

The WD33C93 ports are byte-wide at word stride 4, data in the low byte
(`…0003` / `…0007` are the byte lanes of the words at `…0000` / `…0004`).

**Reset sequence** (`FUN_bfc2fd34`): write `0x40` to the HPC3 DMA control
register, `DELAY(0x19)`, write `0`.

Diagnostics: *"SCSI controller %d diagnostic *FAILED*"*, *"%sSCSI device/cable
diagnostic *FAILED*"*, *"Reset SCSI controller %d and retry"*, *"No SCSI %d
device available"*, plus ~40 sense-key/ASC strings at `0xbfc77ba4`+.

---

## Ethernet — SEEQ 8003

Device window in HPC3 space at `0x1fbd4000` (the device probe reads
`0x1fbd4007` and writes `0x1fbd4003`); DMA descriptors in the HPC3 Ethernet
block (`0x1fb94000` on). Probed by `FUN_bfc03eb0` at boot alongside SCSI and
the RTC. Related symbols: `seeq_init` (`0xbfc1a364`), `einit`, `ereset`,
`ec_install`, `_eopen`, `ether_sprintf`, `cpu_get_eaddr`. Inventory name:
*"SGI Integral IP22 Enet"*.

The MAC address is read out of the RTC/NVRAM device: the routine at
`0xbfc118dc` is `nvram_read(0xfa, 6, dst)`, so the address is six raw bytes at
NVRAM offsets `0xfa`–`0xff` (device bytes `0x13a`–`0x13f`), inside the
checksummed window. The device probe's accesses to device bytes `0x3e`/`0x3f`
are the RTC path test, not the address.

---

## RTC / NVRAM — Dallas DS1386-8K, `0x1fbe0000`

**One device byte per 32-bit word, stride 4, data in the low 8 bits.**

```
device byte N  <->  word at 0x1fbe0000 + N*4
device 0x00-0x3f : DS1386 RTC + control registers
device 0x40+     : general NVRAM  == the PROM's "offset 0"
```

The PROM's own primitives make this unambiguous — both
`nvram_read(off,len,dst)` (`FUN_bfc110b0`) and `nvram_write(off,len,src)`
(`FUN_bfc11144`) compute `0xbfbe0100 + off*4` and step by 4.

Checksum, validity rule and a verify/repair tool: see
[ANALYSIS.md §4](ANALYSIS.md#4-nvram-and-rtc--fully-decoded) and
`tools/prom/nvram.py`.

A core must implement the stride-4 byte aliasing and keep what the PROM writes.
The PROM checks the 256-byte window's checksum and the
`(nvram[1] & 0x3f) == 8` tag itself, and when either fails it wipes and
reinitialises the environment — which is what it does on the first boot after
this core is loaded, because nothing saves the NVRAM
([../nvram.md](../nvram.md)).

---

## HAL2 audio — `0x1fbd8000`

Indirect register file. Direct registers:

| Offset | Register | Behaviour the PROM depends on |
|---|---|---|
| `+0x10` | `HAL2_ISR` | **bit 0 = busy**; the PROM spins on it after every indirect access |
| `+0x20` | `HAL2_REV` | **bit 15 set ⇒ audio not present** — if a core returns bit 15 set, the whole audio path is skipped |
| `+0x30` | `HAL2_IAR` | writing latches the indirect access |
| `+0x40`…`+0x70` | `HAL2_IDR0`…`IDR3` | indirect data |

Indirect addresses the PROM writes (only four sites in the entire image):

| IAR | Meaning |
|---|---|
| `0x2104` | BRES2 clock select ← 1 (44.1 kHz family) |
| `0x2108` | BRES2 inc/mod ← `IDR0=1`, `IDR1=0xffff` ⇒ 22050 Hz |
| `0x9100`, `0x9104` | `RELAY_C` — speaker relay |

HPC3 PBUS DMA descriptors for audio live at `0x1fbd84a0`–`0x1fbd8500`; the boot
path (`0xbfc00bd0`) writes `0x1fbd84a0 ← 4`, zeroes `0x1fbd84a8`–`0x1fbd8500`,
then writes `0x1fbd848c ← 9`, `0x1fbd8484 ← 0` and `0x1fbd8488 ← 0x83`.

**Minimum viable core behaviour:** return `HAL2_REV` with bit 15 **set** and
the PROM skips audio entirely. To get the boot tune, implement the ISR busy bit
and the PBUS DMA path. This core does the former — `HAL2_REV` reads `0xC010` —
and why it went back to it is in [../address-map.md](../address-map.md).

---

## Keyboard / mouse

Diagnostics: *"PC keyboard/mouse controller diagnostic *FAILED*"*,
*"PC keyboard"*, *"PC mouse"*, *"Check or replace: keyboard and cable"*.
`_init_mouse` at `0xbfc21e54`. Layout table at `0xbfc77eb8` selects among
`DE FR IT DK ES de_CH SE FI GB BE NO PT JP fr_CH` (+ `US`), chosen by the
`keybd` environment variable.

---

## Serial console

`prom.map` names the console structure fields `consoles_array_scc_control` and
`consoles_array_scc_data` — a Zilog 85C30 SCC, two channels, control/data pair
per channel. Baud rates come from the `dbaud` / `rbaud` environment variables
(default `9600`, visible in the NVRAM image). Console routines: `consgetc`,
`consputc`, `ttypoll`, `_ttyinput`, `_circ_putc`.

---

## Bring-up order a core should satisfy

1. `MC_SYSID` and `MC_CPUCTRL0/1` must read back sanely.
2. `MC_RPSS_CTR` must advance — `DELAY` and `calibrate_delay` busy-wait on it.
   A stuck counter hangs the PROM before any output.
3. `MC_MEMCFG0/1` must describe at least one full bank at phys `0x08000000`,
   and the data/address tests over it must pass.
4. The GIO DMA engine (`0x1fa02000`+) must complete the VDMA memory clear, or
   the PROM prints the `DMA_RUN`/`DMA_CAUSE` dump and stops.
5. INT2 `LOCAL0_STATUS` must be readable; masks must stick.
6. RTC/NVRAM must honour the stride-4 byte aliasing and hold a valid checksum.
7. SCSI and Ethernet may be absent — the PROM reports failures and continues to
   the Command Monitor.
8. `HAL2_REV` bit 15 set ⇒ audio skipped.

The order in which this core actually had to meet them, with two the list does
not name (the 8254 and the keyboard controller's status port), is in
[../chipset.md](../chipset.md#order-of-dependencies).
