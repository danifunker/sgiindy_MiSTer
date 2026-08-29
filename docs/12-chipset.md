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
- **INT2 has three sources fitted of the twenty-odd a real Indy has**: SCSI0
  on `LOCAL0` bit 1, the SCC on `MAP_STAT` bit 5 and the keyboard/mouse
  controller on bit 4. Every other bit is a device this core does not have and
  reads as an interrupt that never fires. `ERR_STAT` is a real zero, so
  `Cause.IP6` never asserts: nothing here reports a bus error, because
  `sgi_indy.sv` answers an unclaimed cycle rather than faulting it.
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

### Keystroke delivery, end to end

This section used to say that keystroke delivery was **not** proven, "because
nothing in the machine reads the keyboard yet — the PROM's console is the
serial port, so injected scan codes sit in the queue unread. That stays true
until either graphics arrive or IRIX does." Graphics arrived, and it is proven
now.

Two 400-million-cycle boots with Newport fitted, identical except that one
presses keys at the graphics head:

| | keyboard-port accesses | final screen |
|---|---:|---|
| no keys | 597,166 | `Unable to boot; press any key to continue:` |
| seven `5`s | 388,421 | `Command Monitor.` and `>> 5555` |

Both halves of that are evidence. The **six hundred thousand polls** are the
PROM sitting in its input loop with nothing to read, which is what proves it
is reading the controller at all; the drop to 388,421 is it getting an answer
and moving on. And the second screen is the whole path: the first `5`
dismissed the prompt, the second chose *5) Enter Command Monitor* from the
menu, and the remaining five echoed at the `>>` prompt - `ps2_key` to the
i8042's queue to the PROM's read at IOC `+0x40` to ARCS's ConsoleIn to REX3
drawing the echo.

`--key-on` triggers on **console text**, which does not exist once the console
is a screen, so this needed `--key-at CYCLE STR` - a cycle number is crude,
but it is the only trigger available for typing at a graphics head.

The controller protocol was already covered: POST's own diagnostic writes
`0xAA` to the command port and reads `0x55` back, sets the controller command
byte through `0x60`/`0x20`, sends `0xF5` to the keyboard device and reads
`0xFA`, and prints no `PC keyboard/mouse controller diagnostic *FAILED*`.

**The mouse is still unproven.** Nothing on the PROM's path moves a pointer -
`Ng1CursorInit` is a stub in the PROM's own driver and VC2's cursor planes are
not built here either - so the mouse waits for IRIX the way the keyboard
waited for graphics.

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

### Solved: six phantom disconnects on the bus scan — the chip accepted a command it should have refused

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

**Nothing is wrong with the disconnect itself, and — this is the correction —
nothing was wrong with the interrupt line either.** An earlier version of this
section concluded that the ISR ran late because INT2's sources were tied to
zero, and that wiring `scsi_irq` to the CPU would fix it. INT2 is wired now,
and it did not: the boot was byte-for-byte identical. The reason is visible in
one line of the harness's `--irq` log:

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
rule of the part that this model did not implement.

**The real cause: a command must bounce off LCI while an interrupt is pending.**
On a selection timeout the handler frees the bus by issuing DISCONNECT
(`caseD_41` at `0xBFC1E5A8` calls `FUN_bfc1F64C` with command 4). That raises
an interrupt — status `0x85`, phase `0x00` — which the driver deliberately does
*not* service: it waits only for BSY to drop and moves on to the next ID. On
real hardware the next command then bounces, and the driver's own command-issue
routine cleans up after it. `FUN_bfc1f64c` is written around exactly that:

```
bfc1f688  lbu $t8,($v0); andi $t9,$t8,0x10; bnez $t9  ; wait for CIP to clear
bfc1f6e4  sb  0x18, (addr) ; sb cmd, (data)           ; issue
bfc1f710  lbu $t6,($v0); andi $t7,$t6,0x10; bnez $t7  ; wait for CIP again
bfc1f72c  andi $t9, $t8, 0x40 ; bnez -> bfc1f6a8      ; LCI? -> retry
bfc1f6b0  jal  0xbfc1f230                             ; "is INT pending?"
bfc1f6c8  sb   0x17, (addr) ; lbu $zero, (data)       ; read status: clear it
```

That is the whole answer. `LCI` was set here only for a command issued while
`CIP` was set, so the Select-and-Transfer for the next ID was **accepted**. The
stale `0x85` sat in the SCSI Status register while the chip ran the new
command, the poll saw the interrupt that was already pending, and the handler
read `COMMAND = 0x08` against a status of `0x85` — the one combination
`0xBFC1E304` complains about. With `LCI` also set on a pending interrupt, the
driver eats the stale interrupt itself inside `FUN_bfc1f64c` and the handler is
never dispatched for it.

RESET is the exception, on the part and here: it is the escape hatch out of any
state and clears the interrupt itself.

The result is that POST now passes. The six lines are gone, so are
`Diagnostics failed` and the `[Press any key to continue.]` prompt behind it,
and `tests/run-prom.sh` went from over twenty-five minutes back to about four.

Two smaller defects were found and fixed along the way, neither of them this:
ATN left asserted after a selection timeout, and selection latching the *level*
of a shared BSY rather than its rising edge.

Also corrected: the DISCONNECT command sets `COMMAND_PHASE` to `0x00`
(`command_phase::DISCONNECTED`), not `0x43`. `0x43` was a guess from the
handler's first comparison; IRIS uses `0x00` (`wd33c93a.rs:1778`) and the
handler accepts it through the second.

### Solved: `--disk 1=` mounted an image the target then ignored

A harness bug, not an RTL one, and worth recording because it was invisible:
attaching a disk to any ID but 0 produced a boot identical to attaching none.

`img_blocks` is a **single 32-bit bus shared by all seven targets** — that is
what hps_io does on hardware, where a mount is an event and the size on the bus
belongs to whichever slot's flag is up. `sim_scsi.h` raised every mounted flag
at once against slot 0's size, so a disk on ID 1 saw its flag high with
`img_blocks` = 0, and `scsi.v` reads that as "medium removed":

```verilog
if (img_mounted) begin
    if (|img_blocks) begin ... mounted <= 1; end
    else                       mounted <= 0;
```

The target never mounted, never answered a selection, and the PROM's scan found
nothing — exactly what an empty bus looks like. The harness now walks the slots
one at a time, holding each flag with its own size, and `Image mounted on
target 1, size: 16384` appears for the first time.

### INT2, as built

Wired anyway, because IRIX needs it and because it is what proved the paragraph
above wrong. `rtl/sgi/sgi_ioc.sv` implements the whole block and drives five
lines into `Cause.IP[6:2]`:

| INT2 | CPU | Source |
|---|---|---|
| `L0_STAT & L0_MASK` | `IP2` | LOCAL0: SCSI, Ethernet, graphics, MC DMA, and `MAP_INT0` |
| `L1_STAT & L1_MASK` | `IP3` | LOCAL1: HPC DMA, vertical retrace, panel, and `MAP_INT1` |
| `MAP_STAT` bit 0 | `IP4` | 8254 counter 0 |
| `MAP_STAT` bit 1 | `IP5` | 8254 counter 1 |
| `ERR_STAT` | `IP6` | bus error — no source in this core |

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

## HPC3 becomes a bus master

Everything above answers cycles the CPU starts. The HPC3's SCSI channel 0 does
not: it is the first thing in this core that issues a bus cycle of its own, and
that changed the shape of `sgi_indy.sv`. The engine, the register semantics and
the descriptor format are in [13-scsi-dma-plan.md](13-scsi-dma-plan.md); what
belongs here is the chipset consequence.

Main memory now has an arbiter on it. It is not a bus arbiter — it covers one
port, because that is where descriptors and DMA buffers live and nothing else
in this design masters anything. Three things it has to get right, and the
first two are the ones a naive version gets wrong:

* **The DMA request is held, not pulsed.** The CPU pulses `bus_req` for one
  cycle and then waits for `bus_ack`, because it has always been the only
  master and the port is always its to take. The loser of a tie cannot do that:
  a pulse on a cycle the CPU wanted memory is simply gone.
* **`ram_ack` is tagged with whose request it answers.** `bus_ack` is an OR of
  every device's ack, so without `ram_owner_dma` a DMA read completes the CPU's
  outstanding cycle with the DMA's data on it.
* **A second `sgi_memmap`**, because the CPU's `mem_hit` feeds the grant and
  feeding the grant back into the address input closes a combinational loop.

Two smaller things the same work forced:

**`sgi_hpc3` now takes `bus_aoff`.** The doubleword at `0x1FB91000` is the byte
count and the control register at once, byte enables say nothing on a read, and
the control register clears its interrupt when read. Without knowing which word
the CPU actually addressed, a driver reading the byte count acknowledges an
interrupt it never saw. This is the same trap the SCC and the 8042 already had,
in a device that had not needed it.

**The SCSI bus can be reset now, and could not before.** `wd33c93.sv`'s
`scsi_rst` was hardwired to zero. A target that had been selected and abandoned
held BSY for the rest of the boot, the ASR read `0x20` forever, and every
command after it failed — and the driver's recovery path, which prints
"resetting SCSI bus", did nothing at all. HPC3's `ch_reset` falling edge now
resets the controller and pulses RST, which is what the spec's "resets both
external controller and this DMA channel" means on the wire. Until it existed
the boot did not get past the first failed command.
