# The IP24 chipset, as this core implements it

Everything between the CPU and the devices of an Indy: the memory controller
and its DMA engine, HPC3 and what hangs off it, IOC2 with its interrupt
controller and timer, the keyboard controller, the serial ports, the clock and
its NVRAM, and the address decode that ties them together.
`rtl/sgi/sgi_indy.sv` is the machine; the rest of `rtl/sgi/` is one file per
chip.

It runs SGI's own firmware unmodified — PROM Monitor 5.3
(`releases/boot.rom`, see [boot-prom.md](boot-prom.md)) — through POST and
the Command Monitor, and IRIX 5.3 on top of it: multi-user, X and the Indigo
Magic desktop, the IRIS GL demos, and an install from the IRIX 5.3 CD on SCSI
ID 6 onto a blank disk on ID 1. On the board, IRIX's `hinv` reports a 50 MHz
R4600 with 16 KB instruction and data caches, the SCSI controller as
`Version WD33C93A`, a `Disk drive: unit 1`, a `CDROM: unit 6` and
`Graphics board: Indy 24-bit` — and one line that is wrong, a
`Presenter adapter board.` ([below](#what-is-simplified-and-what-is-missing)).

Everything here was built the same way: run the PROM under Verilator, look at
what it polls, read the chip specification and the PROM's own disassembly to
find out what that register is, implement it, run again. The harness's
**unclaimed-address summary** is what makes that loop fast — on exit it lists
every bus cycle no device answered, sorted by address, and the next thing to
build is nearly always the address at the top of a poll loop.

## The modules

| File | What it is |
|---|---|
| `rtl/sgi/sgi_indy.sv` | The machine: the CPU, the physical address decode, the response mux, INT2's source wiring, and main memory's port with the masters on it |
| `rtl/sgi/sgi_mc.sv` | MC register file: `CPUCTRL0/1`, `SYSID`, the RPSS counter and its divider, refresh, `MEMCFG0/1`, the error registers, semaphores, and the DMA engine's registers |
| `rtl/sgi/mc_gio_dma.sv` | The MC's GIO64 DMA engine: fill, memory-to-GIO and GIO-to-memory copies, and the four-entry DMA TLB. The PROM's boot memory clear and every pixel X draws through Newport's DMA run through it |
| `rtl/sgi/eeprom_93c56.sv` | The R4000 configuration EEPROM behind `MC + 0x30` |
| `rtl/sgi/sgi_memmap.sv` | Turns `MEMCFG0/1` into "is this address in a valid bank, and where in RAM is it" |
| `rtl/sgi/ram_arb.sv` | The one arbiter: the CPU and the DMA masters on main memory's single port |
| `rtl/sgi/sgi_hpc3.sv` | HPC3's register file and decode. Every channel but one is storage, held in two M10Ks |
| `rtl/sgi/hpc3_scsi_dma.sv` | HPC3's SCSI channel 0 — the one real DMA channel |
| `rtl/sgi/hal2.sv` | HAL2's register file, inside HPC3's window. It reports no audio present; see below |
| `rtl/sgi/sgi_ioc.sv` | IOC2: `SYS_ID`, panel, reset, and the INT2 interrupt controller |
| `rtl/sgi/pit8254.sv` | The 8254 inside IOC2 |
| `rtl/sgi/i8042.sv` | The PC keyboard/mouse controller at IOC2 `+0x40`/`+0x44`, and both devices behind it |
| `rtl/sgi/sgi_scc.sv`, `z8530_scc.sv` | The Z85C30 serial controller and its IOC2 glue; channel B is the console |
| `rtl/sgi/sgi_ds1386.sv` | The Dallas RTC and the NVRAM the PROM keeps its environment in |
| `rtl/scsi/` | The WD33C93 controller, the SCSI targets and the block cache — see [SCSI](#scsi) |
| `rtl/newport/` | The graphics board: REX3, VC2, two XMAP9s, two CMAPs and a BT445 |

Each file's header carries the reasoning; [address-map.md](address-map.md) has
the register-level detail and the citations.

## Order of dependencies

The order in which the PROM's power-on path needed each piece. Each of these
blocked the next. That order is not obvious from the outside and is the most
useful thing in this document for anyone bringing up a machine like this one:

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

## What is simplified, and what is missing

- **No Ethernet.** The SEEQ 8003's registers are unclaimed and HPC3's
  Ethernet DMA channels are plain storage, so nothing moves a packet. The PROM
  boots without it; IRIX attaches `ec0` and logs `ec0: no carrier`.
- **Audio is reported absent.** `hal2.sv` holds HAL2's direct and indirect
  registers, but `HAL2_REV` reads `0xC010` — bit 15 set, "no audio present" —
  so the PROM skips its HAL2 initialisation, `hinv` lists no audio device, and
  IRIX never loads its `kdsp_a2` audio driver. That is deliberate: with the
  bit clear, IRIX loaded the driver, which ran against a HAL2 with no DMA
  channel and no sample path behind it and froze the desktop the first time
  anything played a sound
  ([scsi-fit-and-framebuffer-layout.md](../design/scsi-fit-and-framebuffer-layout.md)).
  `sgiindy.sv` ties the MiSTer's audio outputs to zero.
- **One SCSI controller.** Controller 0 is real; controller 1's window at
  `0x1FBC8000` is unclaimed, and the PROM reports it absent and carries on, as
  it does for a machine with one SCSI bus.
- **Every HPC3 channel but SCSI 0 is storage.** The PBUS DMA channels, SCSI
  channel 1 and the Ethernet channels read back what was written and move no
  data — enough for the PROM's register tests, one of which walks a bit through
  `0x1FB94000`, and honest about the rest.
  [hpc3-register-file.md](../design/hpc3-register-file.md) is how those
  registers came to be two M10Ks rather than 3,637 ALMs of flip-flops.
- **The MC's DMA engine skips descending copies.** Fill and both ascending
  copy directions are real, translated through the DMA TLB; a descending copy
  (`MODE_DIR` clear) reports itself finished having moved nothing, which is
  what the engine used to do for every mode. Nothing in the PROM or IRIX issues
  one.
- **Nothing raises a bus error.** An unclaimed cycle is answered with all ones
  and a write to one is dropped; the MC's error registers are never set; INT2's
  `ERR_STAT` is a real zero, so `Cause.IP6` never asserts. A real machine
  would time the cycle out into a bus error.
- **The NVRAM lasts until the core is loaded again.** A reset keeps the
  environment; a reload starts from a blank part and the PROM rebuilds it.
  [nvram.md](nvram.md) has what survives what.
- **`hinv` lists a "Presenter adapter board." that is not there.** The kernel
  probes for the Presenter flat-panel adapter through the Display Control Bus.
  An access to an absent device should hold REX3's backend-busy bit until
  `DCBRESET`; here that bit is hardwired to 0, so the probe finds an adapter
  ([rex3-source-audit.md](../design/rex3-source-audit.md)).

## The one that was not a chipset problem at all

Between "the memory controller works" and "POST finds memory" there was a bug
in the **CPU**, which was then the vendored N64 R4300i. `cpu_cop0.vhd`
truncated every TLB translation to 29 bits:

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
`rtl/cpu/r4300/UPSTREAM.md` records the fix, which carried over when the CPU
moved to the Killer Instinct R4600 base it runs on now — that core is a fork of
the same N64 CPU.

## Simulated time

Three clocks in this core are deliberately not at their hardware rate in
simulation, all for the same reason and all parameterised so hardware keeps the
real value:

| Parameter | Hardware | `sim_top.sv` | Why |
|---|---|---|---|
| `sclk` | 3.6864 MHz, a numerically controlled oscillator off the 50 MHz clock (`sgiindy.sv`) | toggled every 4 clocks (`SCLK_DIV` in `sim_cputest.cpp`) | The console tap is bit-rate independent |
| `RTC_TICK_DIV` | 500000 clocks per centisecond | 5000 | The PROM waits for the seconds register to roll over during boot; at the real ratio that single wait is fifty million cycles of nothing |
| `PIT_TICK_DIV` | 50 clocks per count (1 MHz) | 5 | `DELAY()` is calibrated against this timer, so shortening it shortens every delay proportionally. The calibration stays self-consistent — it simply concludes the machine is ten times faster |

The `PIT_TICK_DIV` margin is worth knowing about: `calibrate_delay` restarts
forever if its 512-iteration loop measures more than 10000 counts. At 1 MHz it
measures about 200 and at this setting about 2000, so there is room, but a
much faster timer would break it.

`sim_top.sv` also ties the MiSTer's clock input to zero, so the RTC starts at
its fixed power-on date and an IRIX boot stays cycle-deterministic, and gives
the machine the fixed Ethernet address `08:00:69:12:34:56`.

**Where the 50 MHz comes from**, incidentally: the PROM writes `0x104` to
`RPSS_DIVIDER`, and the MC spec gives divide-by-five, increment-by-one as the
setting "for a 50 MHz processor". That register is the machine telling you its
own bus clock, and `clk_sys` on the board is 50 MHz.

## The keyboard and mouse controller

The Indy carries a PC-style keyboard controller, not an SGI serial keyboard on
the SCC. Two independent things say so, and they agree: the PROM's own
diagnostic calls it *"PC keyboard/mouse controller"*, and the PROM's MMIO
inventory (`hardware-011.txt`, see [prom/README.md](prom/README.md)) shows it
forming `0x1fbd9843` (10 references) and `0x1fbd9847` (9) — byte 3 of the
words at IOC2 `+0x40` and `+0x44`, which is where IRIS puts its 8042 too
(`src/ioc.rs`, `IOC_KBD_MOUSE_DATA`/`_CMD`). The Zilog SCC next door drives the
serial console and nothing else.

`i8042.sv` models the controller and both devices rather than the PS/2 wire
protocol, because MiSTer's `hps_io` has already decoded the wire into
`ps2_key` and `ps2_mouse`; re-serialising them only to decode them again would
be work for its own sake. Command handling follows IRIS's `src/ps2.rs`, which
drives this PROM and IRIX. Scan codes are set 2, which is what `ps2_key`
delivers; set 1 translation is accepted as a config write and ignored.

It is decoded out of the IOC window in `sgi_indy.sv` rather than handled
inside `sgi_ioc.sv`, for the same reason the SCC is: reading its data port
pops a byte, so the access has to be resolved down to one word instead of
sgi_ioc's read-both-halves-and-let-the-CPU-choose. Its interrupt reaches the
CPU through INT2's `MAP_STAT` bit 4.

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

On the board, `sgiindy.sv` passes `hps_io`'s `ps2_key` and `ps2_mouse`
straight to the core. In simulation, `verilator/sim_ps2.h` drives the two
ports the way `hps_io` does — set the payload, flip the top bit, leave both
alone until the next event — with a queue, because an event is only seen if the
core is being clocked when the toggle changes.

- headless: `--key TEXT`, `--key-on TRIG TEXT` and `--key-at CYCLE TEXT`,
  alongside `--type`/`--type-on`, which go to the serial console instead.
  `--key-on` triggers on console text, which does not exist once the console
  is a screen, so typing at a graphics head needs `--key-at` — a cycle number
  is crude, but it is the only trigger there is.
- GUI: **F12** hands the keyboard and mouse to the machine and takes them
  back. Without the toggle every F5 would also land in the guest.

`ps2_mouse` needed a correction on the way: it is **not** a decoded form.
`hps_io.sv:368-370` passes the three raw PS/2 packet bytes straight through —
`[7:0]` flags, `[15:8]` dx, `[23:16]` dy — so `i8042.sv` forwards them
unchanged rather than reassembling a packet the mouse already sent.

### Keystroke delivery, end to end

Proven in simulation by two 400-million-cycle boots with Newport fitted,
identical except that one presses keys at the graphics head:

| | keyboard-port accesses | final screen |
|---|---:|---|
| no keys | 597,166 | `Unable to boot; press any key to continue:` |
| seven `5`s | 388,421 | `Command Monitor.` and `>> 5555` |

Both halves of that are evidence. The **six hundred thousand polls** are the
PROM sitting in its input loop with nothing to read, which is what proves it
is reading the controller at all; the drop to 388,421 is it getting an answer
and moving on. And the second screen is the whole path: the first `5`
dismissed the prompt, the second chose *5) Enter Command Monitor* from the
menu, and the remaining five echoed at the `>>` prompt — `ps2_key` to the
i8042's queue to the PROM's read at IOC `+0x40` to ARCS's ConsoleIn to REX3
drawing the echo.

The controller protocol is covered by POST itself: its diagnostic writes
`0xAA` to the command port and reads `0x55` back, sets the controller command
byte through `0x60`/`0x20`, sends `0xF5` to the keyboard device and reads
`0xFA`, and prints no `PC keyboard/mouse controller diagnostic *FAILED*`.

The mouse is IRIX's: nothing on the PROM's path moves a pointer
(`Ng1CursorInit` is a stub in the PROM's own driver). Under IRIX it drives the
desktop pointer, which VC2's cursor (`rtl/newport/np_vc2.sv`) draws.

## SCSI

`rtl/scsi/` — the WD33C93 at `0x1FBC0000`, three `scsi.v` targets behind it,
and a block cache between the targets and the SD card.
[rtl/scsi/README.md](../../rtl/scsi/README.md) has what came from where.

- **The controller** (`wd33c93.sv`, decoded off the bus by `sgi_scsi.sv`) is
  written to the WD33C93B's register set and its transfer paths behave as a
  93A, which is what IRIX reports: `Version WD33C93A`. Select-and-Transfer
  runs in PIO or through HPC3's DMA channel, as the driver chooses; the PROM
  and IRIX move their data phases through DMA.
- **The targets** are the MiSTer MacLC core's `scsi.v`, with two marked local
  changes: disks on IDs 1 and 2 and a CD-ROM on ID 6 (`TARGET_EN` and
  `CDROM_IDS` in `sgi_scsi.sv`) — ID 6 is where SGI put the internal CD-ROM.
  No other ID is built.
- **The block cache** (`scsi_cache.sv`, ported from MacQuadra800_MiSTer)
  answers reads from block RAM, prefetches, and moves up to eight sectors per
  HPS transaction; the OSD's **SCSI cache: Off** bypasses it
  ([scsi-block-cache.md](../design/scsi-block-cache.md)).
- On MiSTer the OSD's three image slots are **SCSI ID1**, **SCSI ID2** and
  **SCSI ID6 CD**; in simulation `--disk ID=PATH` attaches an image.

POST's data path test and SCSI controller diagnostic both pass, the PROM boots
from the disk, IRIX runs from it and installs onto it from the CD. What the
driver's synchronous-transfer negotiation needed from the controller is its own
record: [scsi-sync-negotiation.md](../design/scsi-sync-negotiation.md).

### The rule the PROM's driver is written around: a command bounces off LCI while an interrupt is pending

For a while POST printed, for IDs 2 through 7:

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

Instrumenting the status register showed why it did not:

```
WD SSR 42 -> 85  state=0 cmdphase=43 cmd=04    the DISCONNECT command lands
WD SSR read = 85 cmdphase=00 cmd=08            the handler reads it much later
```

Between the two, the driver had already written `COMMAND_PHASE = 0`,
`DESTINATION_ID`, and `COMMAND = 0x08` for the **next** ID. By the time the
handler looked, the chip no longer said `0x04`.

**Nothing was wrong with the disconnect itself, and nothing was wrong with the
interrupt line either** — and the second half of that is the correction worth
keeping. The first diagnosis was that the handler ran late because INT2's
sources were tied to zero, and that wiring the SCSI interrupt to the CPU would
fix it. INT2 was wired, and the boot was byte-for-byte identical. The reason is
visible in one line of the harness's `--irq` log:

```
[7519129] IRQ IP[6:2]=.....  L0 02/00  L1 00/02  MAP 00
```

`L0 02/00` is the SCSI interrupt asserted against a **zero L0_MASK**. The PROM
never unmasks LOCAL0 at all; it leaves `L1_MASK = 0x02` (the front panel) and
nothing else. During POST this driver is not interrupt-driven. It *polls*, at
`FUN_bfc1c380`:

```
bfc1c3c4  lbu   $t1, ($t0)        ; the WD33C93's AUX STATUS, at 0x1FBC0003
bfc1c3cc  andi  $t2, $t1, 0x80    ; bit 7 - interrupt pending?
bfc1c3d0  beqz  $t2, ...          ; no -> return
bfc1c3e4  jal   0xbfc1e134        ; yes -> run the handler
```

So the handler does run promptly, on the poll. What actually went wrong is one
rule of the part that the model did not implement.

**A command must bounce off LCI while an interrupt is pending.** On a selection
timeout the handler frees the bus by issuing DISCONNECT (`caseD_41` at
`0xBFC1E5A8` calls `FUN_bfc1F64C` with command 4). That raises an interrupt —
status `0x85`, phase `0x00` — which the driver deliberately does *not* service:
it waits only for BSY to drop and moves on to the next ID. On real hardware the
next command then bounces, and the driver's own command-issue routine cleans up
after it. `FUN_bfc1f64c` is written around exactly that:

```
bfc1f688  lbu $t8,($v0); andi $t9,$t8,0x10; bnez $t9  ; wait for CIP to clear
bfc1f6e4  sb  0x18, (addr) ; sb cmd, (data)           ; issue
bfc1f710  lbu $t6,($v0); andi $t7,$t6,0x10; bnez $t7  ; wait for CIP again
bfc1f72c  andi $t9, $t8, 0x40 ; bnez -> bfc1f6a8      ; LCI? -> retry
bfc1f6b0  jal  0xbfc1f230                             ; "is INT pending?"
bfc1f6c8  sb   0x17, (addr) ; lbu $zero, (data)       ; read status: clear it
```

The model set `LCI` only for a command issued while `CIP` was set, so the
Select-and-Transfer for the next ID was **accepted**. The stale `0x85` sat in
the SCSI Status register while the chip ran the new command, the poll saw the
interrupt that was already pending, and the handler read `COMMAND = 0x08`
against a status of `0x85` — the one combination `0xBFC1E304` complains about.
`wd33c93.sv` now refuses a command with `LCI` while `CIP` is set **or an
interrupt is pending**, the driver eats the stale interrupt itself inside
`FUN_bfc1f64c`, and the handler is never dispatched for it.

RESET is the exception, on the part and here: it is the escape hatch out of any
state and clears the interrupt itself.

With that, POST passes: the six lines are gone, and so are
`Diagnostics failed` and the `[Press any key to continue.]` prompt behind it.
`tests/run-prom.sh` forbids all three.

The DISCONNECT command sets `COMMAND_PHASE` to `0x00`
(`command_phase::DISCONNECTED`), not `0x43`. `0x43` was a guess from the
handler's first comparison; IRIS uses `0x00` (`wd33c93a.rs:1778`) and the
handler accepts it through the second.

### How a mount reaches a target

`img_mounted` is one flag per image slot, but `img_blocks` is **a single 32-bit
bus shared by every slot** — that is what `hps_io` does on hardware, where a
mount is an event and the size on the bus belongs to whichever slot's flag is
up. `scsi.v` reads a mount with a zero size as "medium removed":

```verilog
if (img_mounted) begin
    if (|img_blocks) begin ... mounted <= 1; end
    else                       mounted <= 0;
```

So anything that raises several mount flags against one size — as the
simulator's `sim_scsi.h` once did, raising every flag against slot 0's size —
leaves every target but one unmounted, never answering a selection, and the
PROM's scan finds exactly what an empty bus looks like. The harness walks the
slots one at a time, holding each flag with its own size.

### INT2, as built

`rtl/sgi/sgi_ioc.sv` implements the whole block and drives five lines into
`Cause.IP[6:2]`:

| INT2 | CPU | Source |
|---|---|---|
| `L0_STAT & L0_MASK` | `IP2` | LOCAL0: SCSI, Ethernet, graphics, MC DMA, and `MAP_INT0` |
| `L1_STAT & L1_MASK` | `IP3` | LOCAL1: HPC DMA, vertical retrace, panel, and `MAP_INT1` |
| `MAP_STAT` bit 0 | `IP4` | 8254 counter 0 |
| `MAP_STAT` bit 1 | `IP5` | 8254 counter 1 |
| `ERR_STAT` | `IP6` | bus error — no source in this core |

The sources `sgi_indy.sv` wires:

| Status bit | Source |
|---|---|
| `L0_STAT` bit 1 | SCSI 0: the WD33C93's interrupt ORed with HPC3 channel 0's DMA interrupt, as IRIS does it |
| `L0_STAT` bit 4 | The MC's DMA-done level. IRIX's ng1 driver sleeps on it for every pixel DMA X issues |
| `L1_STAT` bit 7 | Vertical retrace: REX3's VRINT latch, set at each retrace and cleared by the CPU's read of REX3's `STATUS` — the read is what retires it. The raw vblank level, wired here once, could not be retired and starved the machine ([newport-vdma.md](../design/newport-vdma.md)) |
| `MAP_STAT` bit 4 | The keyboard/mouse controller |
| `MAP_STAT` bit 5 | The SCC |
| `MAP_STAT` bits 0, 1 | 8254 counters 0 and 1 |

Every other source is tied off and reads as an interrupt that never fires —
FIFO full, SCSI 1, Ethernet, parallel, the graphics interrupt, the
general-purpose and panel lines, HPC DMA, AC fail, video vsync, and the two GIO
expansion slots.

Two mappable summaries fold back into the levels: `MAP_STAT & MAP_MASK0` is
`L0_STAT` bit 7, `MAP_STAT & MAP_MASK1` is `L1_STAT` bit 3. Every status bit is
a level that follows its device except `MAP_STAT[1:0]`, the two counters, which
are set by an edge and cleared only by a write to `TMR_CLR` at `+0xA0` — a
counter output is a pulse, so something has to remember it.

`tests/run-int.sh` is the proof, and it exists because the PROM cannot provide
one: it arms counter 0 and follows it to an Interrupt exception twice, directly
on IP4 and through `MAP_MASK0` and the LOCAL0 summary on IP2, and checks both
negatives — masked at the CPU, and masked at INT2.

One thing that image found is worth repeating outside it. **A handler that
clears a level-sensitive source and returns can be re-entered**, because the
clearing store sits in the CPU's write FIFO and `eret` does not wait for it to
drain. It presented as a second entry whose `Cause` had `IP4` already clear.
A read back from the same device before returning orders behind the write and
is what makes the clear stick.

---

## HPC3 and the MC as bus masters

Everything above answers cycles the CPU starts. Two things in this core issue
cycles of their own: HPC3's SCSI channel 0, which moves every byte of a disk
transfer, and the MC's GIO64 DMA engine, which clears memory for the PROM and
copies pixels between memory and Newport for IRIX. The channel's register
semantics and descriptor format are in `hpc3_scsi_dma.sv`'s header, and the
history of building it is [note 13](../history.md#13); the engine's are in
`mc_gio_dma.sv` and [newport-vdma.md](../design/newport-vdma.md). What belongs
here is the chipset consequence.

Main memory has one port and one arbiter, `rtl/sgi/ram_arb.sv`. It is not a
bus arbiter — it covers the one main-memory port on `rtl/mister/ddr3_mux.sv`,
because that is where descriptors and DMA buffers live. The two DMA masters are
muxed in front of it in `sgi_indy.sv`, and SCSI wins every tie: its channel is
servicing a live bus phase with a target waiting on it, while the MC's transfer
can be held off for any number of cycles and only takes longer. Three things
the arrangement has to get right, and the first two are the ones a naive version
gets wrong:

* **A DMA request is held, not pulsed.** The CPU pulses `bus_req` for one
  cycle and then waits for `bus_ack`, because it used to be the only master
  and the port was always its to take. The loser of a tie cannot do that: a
  pulse on a cycle the CPU wanted memory is simply gone. The CPU's own pulse
  needs the same care from the other side — one that arrives while a DMA
  transaction is in flight is latched by `ram_arb.sv` and issued when the port
  is free.
* **An acknowledgement goes to the master whose request it answers.**
  `bus_ack` is an OR of every device's ack, so `ram_arb.sv` gives the CPU an
  ack of its own — otherwise a DMA read completes the CPU's outstanding cycle
  with the DMA's data on it — and `sgi_indy.sv` remembers which DMA master owns
  a transaction, so an MC fill's acks never land on the SCSI channel as
  completed descriptor cycles.
* **A second `sgi_memmap`** translates the DMA side's physical addresses,
  because the CPU's `mem_hit` feeds the grant and feeding the grant back into
  the address input closes a combinational loop. A DMA address outside every
  valid bank is answered with zeros one cycle later, so a descriptor chain
  pointing at nothing keeps walking rather than wedging three layers from its
  cause (`tests/run-dma.sh` points one at `0x40000000`).

`ram_arb.sv`'s header has the bug the first, inline version of this arbiter
had — invisible in simulation, because `sim_ram.v` answers in one cycle and
DDR3 in tens.

The MC engine has a second side, a GIO master: one 64-bit beat per
transaction, routed to Newport's DMA port. IRIX's ng1 driver always aims it at
REX3's `HOSTRW` register; `sgi_indy.sv` answers a beat aimed outside the
graphics window with zeros, for the same reason as the memory side.

Two smaller things the SCSI channel forced:

**`sgi_hpc3` takes `bus_aoff`.** The doubleword at `0x1FB91000` is the byte
count and the control register at once, byte enables say nothing on a read, and
the control register clears its interrupt when read. Without knowing which word
the CPU actually addressed, a driver reading the byte count acknowledges an
interrupt it never saw. This is the same trap the SCC and the 8042 already had,
in a device that had not needed it.

**The SCSI bus can be reset.** `wd33c93.sv`'s `scsi_rst` was once hardwired to
zero. A target that had been selected and abandoned held BSY for the rest of
the boot, the ASR read `0x20` forever, and every command after it failed — and
the driver's recovery path, which prints "resetting SCSI bus", did nothing at
all. HPC3's `ch_reset` falling edge resets the controller and pulses RST, which
is what the spec's "resets both external controller and this DMA channel" means
on the wire. Until it existed the boot did not get past the first failed
command.
