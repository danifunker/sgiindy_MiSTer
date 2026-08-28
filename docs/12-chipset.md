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
| 10 | IOC2's keyboard/mouse status reading 0 rather than looping back | The PROM writes the 8042 self-test command `0xAA` to `+0x44` and then *polls the same address* — because it is the command port on a write and the STATUS port on a read. A loopback answers `0xAA`, whose bit 1 means "input buffer full", and the PROM waits for the controller to drain forever. **Since superseded by a real controller — see below** |
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
| `rtl/sgi/i8042.sv` | The PC keyboard/mouse controller at IOC2 `+0x40`/`+0x44`, and both devices behind it |
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
| `PIT_TICK_DIV` | 50 clocks per count (1 MHz) | 5 | `DELAY()` is calibrated against this timer, so shortening it shortens every delay proportionally. The calibration stays self-consistent — it simply concludes the machine is ten times faster. Note that this does **not** set `hinv`'s "16 Mhz": doubling this knob leaves that figure alone, because it comes from a CP0 `Count` loop instead. See `docs/10-r4300-integration.md` |

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

## The keyboard and mouse controller

The Indy carries a PC-style keyboard controller, not an SGI serial keyboard on
the SCC. Two independent things say so, and they agree: the PROM's own
diagnostic calls it *"PC keyboard/mouse controller"*, and
`reference/prom/hardware-011.txt` shows the PROM forming `0x1fbd9843` (10
references) and `0x1fbd9847` (9) — byte 3 of the words at IOC2 `+0x40` and
`+0x44`, which is where IRIS puts its 8042 too (`src/ioc.rs`,
`IOC_KBD_MOUSE_DATA`/`_CMD`). The Zilog SCC next door drives the serial
console and nothing else.

`i8042.sv` models the controller and both devices rather than the PS/2 wire
protocol, because MiSTer's `hps_io` has already decoded the wire into
`ps2_key` and `ps2_mouse`; re-serialising them only to decode them again would
be work for its own sake. Command handling follows IRIS's `src/ps2.rs`, which
drives this PROM and IRIX. Scan codes are set 2, which is what `ps2_key`
delivers; set 1 translation is accepted as a config write and ignored.

It is decoded out of the IOC window in `sgi_indy.sv` rather than handled
inside `sgi_ioc.sv`, for the same reason the SCC is: reading its data port
pops a byte, so the access has to be resolved down to one word instead of
sgi_ioc's read-both-halves-and-let-the-CPU-choose.

### The bug worth remembering

The first version answered every command correctly and the diagnostic still
failed. The trace said why:

```
RD 1fbd9840 be 0f   data ...04     status: SYS, no byte waiting
WR 1fbd9840 be 10   data ...ed     write 0xED to the data port - "set LEDs"
RD 1fbd9840 be 01   data ...05     status: SYS | OBF - a byte is waiting
RD 1fbd9840 be 10   data ...00     read the data port -> 0x00, not 0xFA
```

The queue held the ACK and the status register said so, but the read returned
zero. The pop fires on the access cycle while the bus samples read data on the
*ack* cycle, one later — by which time `q_front` had advanced past the byte
being asked for, to an empty queue. The read data has to be **registered at
access time**, not read combinationally a cycle later.

A status read survived the same mistake, because the queue state it reports
happened not to change between the two cycles. That is what made it look like
a device-model problem rather than a bus-timing one.

### Driving it

`verilator/sim_ps2.h` drives the two ports the way `hps_io` does — set the
payload, flip the top bit, leave both alone until the next event — with a
queue, because an event is only seen if the core is being clocked when the
toggle changes.

- headless: `--key TEXT` and `--key-on TRIG TEXT`, alongside the existing
  `--type`/`--type-on` which go to the serial console instead
- GUI: **F12** hands the keyboard and mouse to the machine and takes them
  back. Without the toggle every F5 would also land in the guest, and there is
  no framebuffer yet to show which has focus.

`ps2_mouse` needed a correction on the way: it is **not** a decoded form.
`hps_io.sv:368-370` passes the three raw PS/2 packet bytes straight through —
`[7:0]` flags, `[15:8]` dx, `[23:16]` dy — so `i8042.sv` forwards them
unchanged rather than reassembling a packet the mouse already sent.

### What is not proven

The controller protocol is: the PROM's `0xED` / LED-argument / `0xF4` sequence
now reads back `0xFA` for each, and the diagnostic passes. **Keystroke
delivery end to end is not**, because nothing in the machine reads the
keyboard yet — the PROM's console is the serial port, so injected scan codes
sit in the queue unread. That stays true until either graphics arrive or IRIX
does; it is not a reason to distrust the controller, but it is not evidence
for it either.

`sgiindy.sv` is still the stock template and does not instantiate the core, so
there is no `hps_io` connection on hardware.

## SCSI

`rtl/scsi/` — the WD33C93B at `0x1FBC0000`, and seven `scsi.v` disk targets
behind it. See `rtl/scsi/README.md` for what came from where.

Working:

- The PROM's **data path test and SCSI controller diagnostic both pass**. They
  used to be the first two `*FAILED*` lines of POST and now print nothing.
- Selection, the full Select-and-Transfer sequence (COMMAND → data → STATUS →
  MESSAGE IN), the `COMMAND_PHASE` progression, and the status byte landing in
  `TARGET_LUN`.
- A disk image attaches with `--disk ID=PATH`, and the block device moves
  512-byte blocks through the shared sector buffer.

### Solved: six phantom disconnects on the bus scan — it is the missing interrupt line

POST printed, for IDs 2 through 7:

```
sc0,2,0: cmd=0x12 illegal disconnection interrupt: phase 0.  Resetting SCSI bus
```

IRIS, on the same PROM and the same blank image, printed none. So the fault was
ours, and the PROM's own code says exactly what it wants. `FUN_bfc1e134` is the
SCSI interrupt handler; the message is at `0xBFC1E358`, and the only two ways
past it are:

```
bfc1e248  beq   $v1, 0x85, bfc1e304    ; status == DISCONNECT?
bfc1e30c  bne   $a3, 0x43, bfc1e34c    ; COMMAND_PHASE == 0x43 -> fine
bfc1e34c  bne   $a0, 4,    bfc1e358    ; COMMAND != 0x04 -> print
bfc1e354  beqz  $a3,       bfc1e6e8    ; COMMAND == 4 and phase == 0 -> silent
```

`$a0` and `$a3` are the **COMMAND** and **COMMAND_PHASE** registers, read out of
the chip at the top of the handler. So a disconnect is only accepted quietly
when the chip still says "the last command I was given was DISCONNECT".

Instrumenting the status register settled it:

```
WD SSR 42 -> 85  state=0 cmdphase=43 cmd=04    the DISCONNECT command lands
WD SSR read = 85 cmdphase=00 cmd=08            the handler reads it much later
```

Between the two, the driver had already written `COMMAND_PHASE = 0`,
`DESTINATION_ID`, and `COMMAND = 0x08` for the **next** ID. By the time the
handler looked, the chip no longer said `0x04`.

**Nothing is wrong with the disconnect itself.** What is wrong is that
`sgi_indy.sv` ties INT2's sources to zero, so `sgi_scsi.sv`'s `irq` output goes
nowhere and the CPU takes no interrupt. The driver polls instead, and polls
*after* it has reprogrammed the chip. On real hardware the ISR runs on the
interrupt line, before the next command is set up, and reads a chip that still
says `0x04`.

Two smaller defects were found and fixed along the way, neither of them this:
ATN left asserted after a selection timeout, and selection latching the *level*
of a shared BSY rather than its rising edge.

Also corrected: the DISCONNECT command sets `COMMAND_PHASE` to `0x00`
(`command_phase::DISCONNECTED`), not `0x43`. `0x43` was a guess from the
handler's first comparison; IRIS uses `0x00` (`wd33c93a.rs:1778`) and the
handler accepts it through the second.

**Next:** wire `scsi_irq` into INT2 `LOCAL0` bit 1 and INT2 into the CPU. That
is the "interrupt-era" work `sgi_indy.sv` defers, and this is the first thing
that actually needs it.
