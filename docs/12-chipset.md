# The IP24 chipset, as this core implements it

Milestones M2, M3 and M6, and most of M4 and M5. Written after the session that
took the core from "the PROM wedges before any output" to this, over the serial
console:

```
System Maintenance Menu

1) Start System
2) Install System Software
3) Run Diagnostics
4) Recover System
5) Enter Command Monitor

Option?
```

and, one keystroke further, to the Command Monitor answering commands:

```
Option? 5
Command Monitor.  Type "exit" to return to the menu.
>> version
PROM Monitor SGI Version 5.3 Rev B10 R4X00/R5000 IP24 Feb 12, 1996 (BE)
>> hinv
                   System: IP22
                Processor: 16 Mhz R4400, with FPU
     Primary I-cache size: 16 Kbytes
     Primary D-cache size: 16 Kbytes
              Memory size: 64 Mbytes
```

Every keystroke there was a real UART frame shifted into the SCC's receive pin,
so serial works in both directions. `hinv` is worth reading closely — it is the
PROM's own report of what it found, and it agrees with the design on all three
counts: the R4400 identity `docs/10-r4300-integration.md` argues for, the 16 KB
cache geometry that file deliberately reports, and 64 MB of memory that the
MEMCFG decode had to be right for.

**"16 Mhz" is a measured figure, not a claim.** The PROM times itself against
the 8254, which simulation runs ten times fast, so the number moves with
`PIT_TICK_DIV`. It is not the core reporting a clock speed.

Everything here was built the same way: run the PROM under Verilator, look at
what it polls, read the chip specification and the PROM's own disassembly to
find out what that register is, implement it, run again. The harness's
**unclaimed-address summary** is what makes that loop fast — on exit it lists
every bus cycle no device answered, sorted by address, and the next thing to
build is nearly always the address at the top of a poll loop.

## Order of dependencies

Each of these blocked the next. That order is not obvious from the outside and
is the most useful thing in this document:

| # | What was missing | How it presented |
|---|---|---|
| 1 | `RPSS_CTR` counting | Wedged at `0xBFC00510` before a single character. `realstart` waits for the counter to advance by `0x271` |
| 2 | HPC3 descriptor registers | Endless diagnostic loop at `0xBFC03E90`: a walking-bit test on `0x1FB94000` that never reads back |
| 3 | The SCC's WR8-through-the-command-port path | POST ran and printed **nothing** — the whole console path was one missing datasheet case |
| 4 | IOC2 `SYS_ID` bit 5, and INT2 | "INT path test *FAILED*" then an endless loop at `0xBFC04070`. Bit 5 clear sends the PROM to the Indigo2's interrupt controller address |
| 5 | A 32-bit physical address in the CPU | "No usable memory found. Make sure you have a full bank (4 SIMMs)" — see below, this one was in the vendored CPU |
| 6 | A MEMCFG-driven memory decode | Same message. The banks are not at a fixed address; `szmem` moves them to size them |
| 7 | DS1386 RTC and NVRAM | "RTC path test *FAILED*", then a stall waiting for the seconds register to change |
| 8 | The 8254 timer in IOC2 | `calibrate_delay` restarting forever, because its measurement came back greater than its own sanity limit |
| 9 | Graphics answering 0 rather than being unclaimed | Not a hang, but every REX3 status poll burning its full 100000-iteration timeout |
| 10 | IOC2's keyboard/mouse status reading 0 rather than looping back | The PROM writes the 8042 self-test command `0xAA` to `+0x44` and then *polls the same address* — because it is the command port on a write and the STATUS port on a read. A loopback answers `0xAA`, whose bit 1 means "input buffer full", and the PROM waits for the controller to drain forever |
| 11 | The harness tracking the console's bit rate | Not a core bug, but it looked like one: the PROM announces "diagnostic baud rate set to 19200" before the menu, and a harness still typing at 9600 sends garbage that the PROM's own auto-baud then chases to 38400 |

## The modules

| File | What it is |
|---|---|
| `rtl/sgi/sgi_mc.sv` | MC register file: `CPUCTRL0/1`, `SYSID`, the RPSS counter and its divider, refresh, `MEMCFG0/1`, the error registers, semaphores, and the GIO DMA registers as a stub |
| `rtl/sgi/eeprom_93c56.sv` | The R4000 configuration EEPROM hanging off `MC + 0x30` |
| `rtl/sgi/sgi_memmap.sv` | Turns `MEMCFG0/1` into "is this address in a valid bank, and where in RAM is it" |
| `rtl/sgi/sgi_hpc3.sv` | HPC3's DMA descriptor, control and configuration registers, and HAL2 reporting itself absent |
| `rtl/sgi/sgi_ioc.sv` | IOC2: `SYS_ID`, panel, reset, the INT2 interrupt controller and the 8254 |
| `rtl/sgi/pit8254.sv` | That 8254 |
| `rtl/sgi/sgi_ds1386.sv` | The Dallas RTC and the NVRAM the PROM keeps its environment in |

Each file's header carries the reasoning; `docs/02-address-map.md` has the
register-level detail and the citations.

## The one that was not a chipset problem at all

Between "the memory controller works" and "POST finds memory" there was a bug
in the **vendored CPU**. `cpu_cop0.vhd` truncated every TLB translation to 29
bits:

```vhdl
TLB_fetchAddrOutMasked <= "000" & TLB_fetchAddrOut(28 downto 0);
    -- only for 32bit mode, 64bit needs addr &= 0x7FFFFFFF;
```

On an N64 that is invisible: the whole physical address space is 512 MB. An
Indy puts high local memory at physical `0x20000000`, and `szmem` sizes every
bank through TLB pages mapped there — so every probe access came out at
`0x00000000` and POST concluded there was no memory. The same strip appeared
again in the write FIFO, where it was correct only because every fetch reaching
it had been unmapped.

It is worth naming the shape of this, because there will be more: **upstream
assumptions that are true of an N64 and false of an SGI are not marked as
assumptions.** They look like ordinary code. The symptom was a memory
controller that appeared not to work, three layers away from the cause.
`rtl/cpu/r4300/UPSTREAM.md` records the fix; the 240-test suite is unchanged by
it, which is the only reason to believe it.

## Deliberate simplifications, and what they cost

- **No GIO DMA engine.** The MC's DMA registers store what is written and a
  start reports an instantly-finished transfer, but nothing is copied. The
  alternative stub — never asserting `DMA_RUN` — wedges the PROM in a poll,
  whereas this lets it run on. The boot memory clear therefore does not
  actually clear anything.
- **No SCSI and no Ethernet.** Both are absent rather than stubbed, and the
  PROM reports both and continues, which is what it does for a machine with
  neither fitted. Making the WD33C93 *appear* present without implementing its
  interrupt behaviour would trade a fast, honest failure for a slow one.
- **No graphics.** The window answers zero so the absence is discovered
  quickly. Newport is the largest single remaining piece of work and is not on
  the path to the Command Monitor over serial.
- **Interrupt status registers read zero.** Nothing raises an interrupt yet.
  They are inputs to `sgi_ioc.sv` rather than storage, so wiring real sources in
  changes nothing else. The DE1 sandbox made them read-write, which passes the
  same tests and then lies.
- **The NVRAM is volatile**, so the PROM prints "NVRAM checksum is incorrect:
  reinitializing" and rebuilds the environment on every boot. That is the
  documented failure mode rather than a hang. Wiring the array to MiSTer's SD
  save path is the fix, and it is the difference between a machine that
  remembers a `setenv` and one that does not.

## Simulated time

Three clocks in this core are deliberately not at their hardware rate in
simulation, all for the same reason and all parameterised so hardware keeps the
real value:

| Parameter | Hardware | `sim_top.sv` | Why |
|---|---|---|---|
| `sclk` | 3.6864 MHz | fast | The console tap is bit-rate independent |
| `RTC_TICK_DIV` | 500000 clocks per centisecond | 5000 | The PROM waits for the seconds register to roll over during boot; at the real ratio that single wait is fifty million cycles of nothing |
| `PIT_TICK_DIV` | 50 clocks per count (1 MHz) | 5 | `DELAY()` is calibrated against this timer, so shortening it shortens every delay proportionally. The calibration stays self-consistent — it simply concludes the machine is ten times faster, which for a core running with both caches off and a bus round trip per instruction is arguably nearer the truth than 50 MHz |

The `PIT_TICK_DIV` margin is worth knowing about: `calibrate_delay` restarts
forever if its 512-iteration loop measures more than 10000 counts. At 1 MHz it
measures about 200 and at this setting about 2000, so there is room, but a
much faster timer would break it.

**Where the 50 MHz comes from**, incidentally: the PROM writes `0x104` to
`RPSS_DIVIDER`, and the MC spec gives divide-by-five, increment-by-one as the
setting "for a 50 MHz processor". That register is the machine telling you its
own bus clock.

## What to do next

1. **The instruction cache.** Every fetch is currently a bus round trip, which
   is both the simulation's speed limit and, on hardware, a performance floor.
   `cpu_instrcache.vhd` fills from the N64's RDRAM port, tied off in
   `r4300_wrap.vhd`; pointing it at this bus is the single biggest change
   available.
2. **NVRAM persistence**, so the environment survives a reboot.
3. **The GIO DMA engine**, for the boot memory clear.
4. **Interrupts** — INT2 has masks and no sources.
5. **Newport**, which is the rest of the machine.
