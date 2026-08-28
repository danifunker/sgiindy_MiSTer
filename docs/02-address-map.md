# IP22 / IP24 address map and registers

All addresses are **physical**. The PROM reaches them through kseg1
(`phys | 0xA0000000`, uncached); kseg0 (`phys | 0x80000000`) is the cached
alias. MIPS is **big-endian** on these machines.

Two independent sources agree on this map: the PROM's own MMIO access
inventory (`indy-prom/out/hardware-011.txt`) and the decode tree in
`DE1_TOP.v` lines ~770–790, which is reproduced below verbatim in the
"decoded in RTL" column.

**A third source now outranks both of them.** `reference/specs/mc.pdf` and
`reference/specs/hpc3.pdf` are the SGI chip specifications, and their register
tables are authoritative. Where they and the PROM inventory disagreed, the
specs were right every time — the inventory's *addresses* are correct (it is
generated from the image) but several of its *names* are shifted by one slot,
which sent this project looking for RPSS_CTR at MC + 0x80 when the counter is
at MC + 0x1000 and 0x80 is the GIO64 arbiter. The table below is the spec's.

## Top-level map

| Range | Device | Decoded in RTL | Status in sandbox |
|---|---|---|---|
| `0x00000000`–`0x0007FFFF` | Mirror of first 512 KB of main RAM | `BANK1_CS` | works |
| `0x00000000`–`0x07FFFFFF` | GIO64 / EISA low space (Indigo2) | — | absent |
| **`0x08000000`–`0x0FFFFFFF`** | **Main DRAM (128 MB) — RAM base is `0x08000000`, not 0** | `MAINRAM_CS` | works |
| `0x10000000`–`0x1EFFFFFF` | GIO64 expansion slot windows | — | absent |
| `0x1F000000`–`0x1F0EFFFF` | Graphics low window (VC2 / XMAP9 / DAC) | — | absent |
| `0x1F0F0000`–`0x1F0F1FFF` | **Newport GR2/REX3** rendering engine | `NEWPORT_CS` | stub → `0xFFFFFFFF` |
| `0x1F400000` / `0x1F600000` | GIO expansion slots 1 / 0 | — | absent |
| **`0x1FA00000`–`0x1FA1FFFF`** | **MC** — memory & GIO64 arbiter controller | `MC_CS` | real model (`sgi_mc.v`) |
| `0x1FB80000`–`0x1FB8FFFF` | HPC3 PBUS DMA | `PBUSDMA_CS` | reads pass through to RAM data |
| `0x1FB90000`–`0x1FB91FFF` | **HPC3 SCSI channel 0 DMA** | `HD_ENET_CS` | real: `rtl/sgi/hpc3_scsi_dma.sv` |
| `0x1FB92000`–`0x1FB9FFFF` | HPC3 SCSI 1 / Ethernet DMA | `HD_ENET_CS` | storage that reads back |
| `0x1FBB0000`–`0x1FBB0003` | `INTSTAT` (HPC3 scratch) | `SCRATCH_CS` | stub → `0xFFFFFFFF` |
| `0x1FBB0010` | `GIO_BUS_ERROR` | — | absent |
| `0x1FBC0000`–`0x1FBC7FFF` | **WD33C93B SCSI controller 0** | `HD0_CS` | 2-register loopback stub |
| `0x1FBC8000`–`0x1FBCFFFF` | WD33C93B SCSI controller 1 | `UNKBUS0_CS` | absent |
| `0x1FBD8000`–`0x1FBD83FF` | **HAL2 audio** | `HAL2_CS` | stub → `0xFFFFFFFF` |
| `0x1FBD8400`–`0x1FBD87FF` | HPC3 PBUS audio DMA descriptors | `HACK_CS` | stub |
| `0x1FBD9000`–`0x1FBD93FF` | PBUS channel 4 regs | `PBUS4_CS` | 6-register loopback stub |
| **`0x1FBD9800`–`0x1FBD9BFF`** | **IOC / INT2 / SCC / panel** | `IOC_CS` | partly real (SCC) |
| `0x1FBDC000`–`0x1FBDD3FF` | Small RAM blocks (per MAME `indy_indigo2.cpp`) | `SMALLRAM_CS` | absent |
| **`0x1FBE0000`–`0x1FBE04FF`** | **Dallas DS1386-8K RTC + NVRAM** | `DS1386_CS` | 2 kludge regs only |
| **`0x1FC00000`–`0x1FC7FFFF`** | **Boot PROM (512 KiB)** | `BIOS_CS` | works (byte-serial Flash port) |
| `0x20000000`–`0x2FFFFFFF` | **High local memory** — reachable through the TLB only, and where `szmem` maps each bank while sizing it | `MAINRAM2_CS` | works |

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
there instead, because a spurious bus error during bring-up is a worse trap
than a zero, and the PROM never does it — all 190-odd MC references in the
image end in 4 or 0xc.

| Offset | Name | PROM refs | Notes |
|---|---|---|---|
| `0x00` | `CPUCTRL0` | **59** | Hottest MMIO address in the image. Refresh, endian, parity, GIO/EISA enables, watchdog |
| `0x08` | `CPUCTRL1` | 2 | Written `0x16` early in `realstart` |
| `0x10` | `WATCHDOG` | — | |
| `0x18` | `SYSID` | 3 | Read-only. Spec §5.4: bits `[3:0]` = MC chip revision (0 = Rev A, 1 = Rev B), bit 4 = EISA present, `[31:5]` reserved. The sandbox's `0x21` sets a reserved bit and is wrong. `setup_regs` (`0xBFC01B08`) and `0xBFC0AB64` both mask with `0xF` and branch on `rev < 5`, so the revision is free; this core reports **`0x13`**, matching IRIS and MAME's rev C, with the EISA bit set because the IRIX vino driver gates its probe on it |
| `0x28` | `RPSS_DIVIDER` | 2 | Bits `[7:0]` DIV — "the amount to divide the CPU minus one", so 4 means one tick every five CPU clocks. Bits `[15:8]` INC — what to add per tick. The PROM writes **`0x104`**, which the spec gives as the setting for a **50 MHz processor**: that is the register that tells you this machine's R4000 bus clock, and it is why `sgi_mc.sv` treats 50 MHz as the core clock |
| `0x30` | `EEROM` | **20** | R4000 configuration EEPROM, bit-banged. Bits: `[1]`=CS, `[2]`=SCK, `[3]`=DI, `[4]`=DO — confirmed against the PROM's own routines at `0xBFC0A83C`/`0xBFC0A89C`/`0xBFC0A99C`. Only five bits exist; the rest read 0. `rtl/sgi/eeprom_93c56.sv` is the part. **Word `0x11` must read 0**: it is CACHSZ_REG, the secondary cache size in 4 KB pages, and an erased `0xFFFF` tells firmware there is a 256 MB L2 to flush |
| `0x40`/`0x48` | `REFCNT_PRELOAD` / `REFCNT` | | |
| `0x80`/`0x88`/`0x98` | `GIO64_ARB` / `CPU_TIME` / `LB_TIME` | 16 | GIO64 arbitration parameters, CPU time slice, long-burst period. The PROM writes `0x401` to `GIO64_ARB` in `realstart` — ONE_GIO for a single-bus Indy, plus HPC at 64 bits |
| `0x100`/`0x108`/`0x110` | `SYS_SEMAPHORE` / `LOCK_MEMORY` / `EISA_LOCK` | | A semaphore read returns the bit **and sets it** — the machine's only atomic test-and-set. Both locks reset to 1 (unlocked) |
| `0xC0` / `0xC8` | `MEMCFG0` / `MEMCFG1` | 7 / 2 | SIMM bank descriptors — driven by `szmem`, `init_memconfig`. Encoding below |
| `0xD0` | `CPU_MEMACC` | 7 | |
| `0xD8` | `GIO_MEMACC` | 3 | Printed as `GIO_MEMACC:` in the DMA failure dump |
| `0xE0` / `0xE8` | `CPU_ERROR_ADDR` / `CPU_ERROR_STAT` | 5 / 11 | Cleared at reset |
| `0xF0` / `0xF8` | `GIO_ERROR_ADDR` / `CLR_ERROR_STAT` | 5 / 3 | Printed in the DMA failure dump |
| `0x150`/`0x158`/`0x160`/`0x168` | `DMA_GIO_MASK` / `DMA_GIO_SUB` / `DMA_CAUSE` / `DMA_CTL` | 16 | |
| `0x180`–`0x1BF` | DMA TLB entries 0–3 (hi/lo) | | |
| **`0x1000`** | **`RPSS_CTR`** | 3 | **Free-running 100 ns counter**, read-only. `DELAY()` and `calibrate_delay()` busy-wait on it; `realstart` waits for it to advance by `0x271` at `0xBFC00500` before touching anything else, so a counter that does not count hangs the PROM before a single character reaches the console. Not at `0x80` — the PROM inventory names it there and is wrong |
| `0x2000`–`0x2048` | **GIO DMA engine** | **43** | `DMA_MEMADR`, `DMA_LINECNT_WIDTH`, `DMA_LINEZOOM_STRIDE`, `DMA_GIO64ADDR`, `DMA_MODE`, `DMA_ZOOM_BYTECNT`, `DMA_RUN`, `DMA_CAUSE`. See `vdma.pdf` |

The `VDMA Clear failed` path prints, in order: `DMA_RUN:`, `DMA_CAUSE:`,
`DMA_MEMADR:`, `GIO_MEMACC:`, `GIO_ERR_ADDR:`, `GIO_ERR_STAT:` — a ready-made
checklist of what the DMA engine must actually do for the boot memory clear
to succeed.

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
  A CPU that cannot form a physical address above `0x1FFFFFFF` — which the
  vendored R4300 could not — never sees any of it.


Four fields per SIMM bank: base address (8 bits, compared against address bits
`[29:22]`), size in MB, valid/installed flag, and a sub-bank bit (set for
512Kx36, 2Mx36 and 8Mx36 SIMMs, which carry two sub-banks).

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

---

## IOC / INT2 / SCC block — `0x1FBD9800`

| Address | Register | Sandbox |
|---|---|---|
| `0x1FBD9830` | SCC channel **B** (tty1, the console) **command** | real Z8530 |
| `0x1FBD9834` | SCC channel B (tty1) **data** | real Z8530 |
| `0x1FBD9838` | SCC channel A (tty2) command | real Z8530 |
| `0x1FBD983C` | SCC channel A (tty2) data | real Z8530 |
| `0x1FBD984C` | `GENCON` general control | loopback reg |
| `0x1FBD9850` | `PANEL_REGISTER` ✔ | absent |
| `0x1FBD9858` | `SYS_ID` ✔ | **`0x26`** on an Indy (IRIS's value for guinness; `0x11` is an Indigo2). **Bit 5 says where the interrupt controller is**: set means INT2 at IOC + `0x80`, clear sends the PROM to `0x1FBD9000` — the Indigo2 location — and its "INT path test" then fails and drops it into an endless diagnostic loop at `0xBFC04070`. `0xBFC03FA0` reads this register to make exactly that choice |
| `0x1FBD9870` | `RESET_REG` (6 bits, mirrored to LEDs) | loopback reg, resets to `0b001111` |

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
| `+0x30`…`+0x3C` | 8254-style timer counters | counters 0 and 1 latch into `MAP_STATUS[1:0]` |

`rtl/sgi/sgi_ioc.sv` implements all of it, and it does **not** take the
sandbox's loopback approach: the three status registers are driven by their
sources and ignore writes. A loopback passes the same tests and then lies as
soon as anything real is connected.

Every status bit is a level that follows its device, with two exceptions. The
counter bits in `MAP_STATUS[1:0]` are set by an edge — a counter output is a
pulse — and cleared only by writing `+0x20`. Sources fitted today: SCSI0 on
`LOCAL0` bit 1, the SCC on `MAP_STATUS` bit 5, the keyboard/mouse controller on
bit 4.

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

## SCSI — WD33C93B × 2 + HPC3 DMA

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
of it is what resets the WD33C93B and pulses RST on the SCSI bus. It is also
the register's power-on value, and `ch_active` cannot be set while it stands.

SCSI may be absent — the PROM reports the failure and continues.

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
one. `docs/13-scsi-dma-plan.md` has the whole thing.

---

## Ethernet — SEEQ 8003

Device window in HPC3 space, DMA descriptors in the HPC3 Ethernet block
(`ENETR_CBP` at `0x1FB94000`, `ENETR_NBDP` at `0x1FB94004`, `ENET_BC` at
`0x1FB95000` per the sim's register decoder). Probed at boot by `FUN_bfc03eb0`.
MAC address comes from the RTC/NVRAM device. May be absent.

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
NVRAM offset 0 is device byte `0x40`. See [03-boot-prom.md](03-boot-prom.md)
for the checksum and validity rules.

The sandbox implemented **only two** registers here (`+0xF8`, `+0xFC`), hand-
picked as "kludges so it passes the self-test". `rtl/sgi/sgi_ds1386.sv` is the
whole 8 KB part with a BCD calendar over device bytes `0x00`–`0x0A` and TE
(bit 7 of the command register at `0x0B`) freezing it. Its contents are still
volatile, so the PROM prints *"NVRAM checksum is incorrect: reinitializing"*
and rebuilds the environment on every boot — the documented failure mode
rather than a hang. Wiring the array to MiSTer's SD save path is what fixes it.

The **RTC path test** in the device probe (`0xBFC03F48`) writes `0xA5`/`0x5A`
to device bytes `0x3E`/`0x3F` and reads them back; failing it prints but does
not hang.

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

HPC3 PBUS DMA descriptors for audio live at `0x1FBD84A0`–`0x1FBD8500`; the boot
path zeroes that block, then writes `0x1FBD8488 ← 0x83` and `0x1FBD848C ← 9`.

**Minimum viable:** return `HAL2_REV` with bit 15 set → audio skipped entirely.
To get the boot tune, implement the ISR busy bit and the PBUS DMA path.

---

## Graphics — Newport (GR2 / REX3), `0x1F0F0000`

Not modelled. `sgi_indy.sv` claims `0x1F000000`–`0x1F0FFFFF` and returns
**zero**, which is not cosmetic: `0x1F0F1338` is REX3's `STATUS` and the PROM
polls it for the engine to go idle up to 100000 times (`0xBFC17738`), so an
unclaimed cycle answering `0xFFFFFFFF` means "busy, forever" and every one of
those waits burns its full timeout. Zero drops each of them straight through to
the graphics-failed path, which is the right answer for a machine with no
graphics board. `0x1F0F1330` is `CONFIG`, pinned by a 5.0-PROM diagnostic
string.

The sandbox returned `0xFFFFFFFF` here (`NEWPORT_CS`). The
relevant specs are `rex3.pdf` (rasteriser), `vc2.pdf` (video controller),
`xmap9.pdf` (colour map / DAC), `rb2.pdf`, `ro1.pdf`, `dmux1.pdf`. This is the
largest single remaining piece of work for a core anyone would want to use, and
is *not* on the critical path for reaching the Command Monitor over serial.

---

## Keyboard / mouse / console

PC-style keyboard/mouse controller, diagnosed by the PROM
(`_init_mouse` at `0xBFC21E54`). Layout table at `0xBFC77EB8` selects among
`DE FR IT DK ES de_CH SE FI GB BE NO PT JP fr_CH US`, chosen by the `keybd`
environment variable.

The serial console is the Zilog 85C30 SCC above, two channels, control/data
pair each. Baud from the `dbaud` / `rbaud` NVRAM environment variables
(default 9600).
