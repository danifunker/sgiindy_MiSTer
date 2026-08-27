# IP22 / IP24 address map and registers

All addresses are **physical**. The PROM reaches them through kseg1
(`phys | 0xA0000000`, uncached); kseg0 (`phys | 0x80000000`) is the cached
alias. MIPS is **big-endian** on these machines.

Two independent sources agree on this map: the PROM's own MMIO access
inventory (`indy-prom/out/hardware-011.txt`) and the decode tree in
`DE1_TOP.v` lines ~770–790, which is reproduced below verbatim in the
"decoded in RTL" column.

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
| `0x1FB90000`–`0x1FB9FFFF` | HPC3 SCSI / Ethernet DMA | `HD_ENET_CS` | 4-register stub |
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
| `0x20000000`–`0x2FFFFFFF` | Extra 128 MB of RAM (reachable via TLB only) | `MAINRAM2_CS` | works |

---

## MC — Memory Controller, `0x1FA00000`

**Registers are architecturally 64-bit and the PROM always accesses the low
half, i.e. at `reg + 4`.** A decoder that matches only `reg + 0` sees nothing.
`sgi_mc.v` handles this by decoding inclusive ranges (`0x0000`–`0x0007` etc.).

| Offset | Name | PROM refs | Notes |
|---|---|---|---|
| `0x00` | `CPUCTRL0` | **59** | Hottest MMIO address in the image. Refresh, endian, parity, GIO/EISA enables, watchdog |
| `0x08` | `CPUCTRL1` | 2 | Written `0x16` early in `realstart` |
| `0x10` | `WATCHDOG` | — | |
| `0x18` | `SYSID` | 3 | Read by `setup_regs`. Sandbox returns `0x21` (Indy, MC rev 1); `0x20` = rev 0, `0x11` = Indigo |
| `0x28` | `RPSS_DIV` | 2 | 100 ns counter divider |
| `0x30` | `EEPROM` | **20** | Serial EEPROM bit-bang. Bits: `[1]`=CS, `[2]`=SCK, `[3]`=SO(out), `[4]`=SI(in). `sgi_mc.v` currently *reads back* `0xFFFFFFFF` — the real SI path is commented out |
| `0x40`/`0x48` | `REFCNT_PRELOAD` / `REFCNT` | | |
| `0x80` | `RPSS_CTR` (at `0x1FA01000` in `sgi_mc.v`) | 3 | **Free-running 100 ns counter.** `DELAY()` and `calibrate_delay()` busy-wait on it — if it doesn't advance the PROM hangs before any output |
| `0x80`/`0x88`/`0x98` | GIO64 arb param / CPU time slice / burst | 16 | |
| `0xC0` / `0xC8` | `MEMCFG0` / `MEMCFG1` | 7 / 2 | SIMM bank descriptors — driven by `szmem`, `init_memconfig`. Encoding below |
| `0xD0` | `CPU_MEMACC` | 7 | |
| `0xD8` | `GIO_MEMACC` | 3 | Printed as `GIO_MEMACC:` in the DMA failure dump |
| `0xE0` / `0xE8` | `CPU_ERROR_ADDR` / `CPU_ERROR_STAT` | 5 / 11 | Cleared at reset |
| `0xF0` / `0xF8` | `GIO_ERROR_ADDR` / `CLR_ERROR_STAT` | 5 / 3 | Printed in the DMA failure dump |
| `0x100`/`0x108`/`0x110` | `SysSemaphore` / `GIOLock` / `EISALock` | | |
| `0x150`/`0x158`/`0x160`/`0x168` | GIO64 trans mask / subst / DMA cause / DMA control | 16 | |
| `0x180`–`0x1BF` | DMA TLB entries 0–3 (hi/lo) | | |
| `0x2000`–`0x2048` | **GIO DMA engine** | **43** | `DMA_MEMADR`, `DMA_LINECNT_WIDTH`, `DMA_LINEZOOM_STRIDE`, `DMA_GIO64ADDR`, `DMA_MODE`, `DMA_ZOOM_BYTECNT`, `DMA_RUN`, `DMA_CAUSE`. See `vdma.pdf` |

The `VDMA Clear failed` path prints, in order: `DMA_RUN:`, `DMA_CAUSE:`,
`DMA_MEMADR:`, `GIO_MEMACC:`, `GIO_ERR_ADDR:`, `GIO_ERR_STAT:` — a ready-made
checklist of what the DMA engine must actually do for the boot memory clear
to succeed.

### MEMCFG encoding (from the SGI MC spec)

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
| `0x1FBD9830` | SCC channel A (Port 1) **command** | real Z8530 |
| `0x1FBD9834` | SCC channel A (Port 1) **data** | real Z8530 |
| `0x1FBD9838` | SCC channel B (Port 2) command | real Z8530 |
| `0x1FBD983C` | SCC channel B (Port 2) data | real Z8530 |
| `0x1FBD984C` | `GENCON` general control | loopback reg |
| `0x1FBD9850` | `PANEL_REGISTER` ✔ | absent |
| `0x1FBD9858` | `SYS_ID` ✔ | returns `0x21` |
| `0x1FBD9870` | `RESET_REG` (6 bits, mirrored to LEDs) | loopback reg, resets to `0b001111` |

### INT2 interrupt controller — `0x1FBD9880`

Byte-wide registers on a 32-bit bus: **stride 4, data in the low 8 bits.** The
PROM reads them with `lbu` at `base + 3`, confirming big-endian low-byte
placement.

| Offset | Register | Sandbox |
|---|---|---|
| `+0x00` | `LOCAL0_STATUS` (read-only) — 24 referencing instructions | loopback reg |
| `+0x04` | `LOCAL0_MASK` | loopback reg |
| `+0x08` / `+0x0C` | `LOCAL1_STATUS` / `LOCAL1_MASK` | loopback regs |
| `+0x10`…`+0x1C` | interrupt map 0/1 status and mask | loopback regs |
| `+0x30` | timer interrupt clear | absent |
| `+0x34` | error status | absent |
| `+0x38`…`+0x3C` | 8254-style timer counters | absent |

Note the RTL's loopback-register approach means `LOCAL0_STATUS` returns
whatever was last written to it — fine for getting past the init writes,
useless once interrupts matter.

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
register, `DELAY(0x19)`, write `0`.

SCSI may be absent — the PROM reports the failure and continues.

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

The sandbox implements **only two** registers here (`+0xF8`, `+0xFC`), hand-
picked as "kludges so it passes the self-test". A real core needs the full
stride-4 aliasing, the 256-byte checksummed window, and the validity tag, or
the PROM wipes and reinitialises the environment on every boot.

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

Not modelled at all in the sandbox (`NEWPORT_CS` returns `0xFFFFFFFF`). The
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
