# Resume prompt

Paste everything below the line as the opening message of a fresh session.

Keep this file honest. It is the only document a new session is guaranteed to
read, so when something here stops being true it is worse than useless — it
sends the session off to build what already exists. Update it at the end of any
session that changes the answer to "what works" or "what is next".

---

You are continuing work on an **SGI Indy (IP24)** core for MiSTer FPGA. The repo
is `~/repos/sgiindy_MiSTer`. **Work autonomously**: make the routine calls
yourself, keep going through obstacles, and only stop to ask when a decision
genuinely changes what gets built (or when you need something run on real
hardware — see below).

## Where this is

**The machine boots. You can type at it.**

Running the real IP24 PROM under Verilator gets all the way to the Command
Monitor, over serial, driven by keystrokes the harness sends into the SCC's
receive pin — and **POST now passes**:

```
                         Running power-on diagnostics...

Cannot open video() for output
Cannot open video() for output

System Maintenance Menu

1) Start System
2) Install System Software
3) Run Diagnostics
4) Recover System
5) Enter Command Monitor

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

`tests/run-prom.sh` reproduces all of that and checks each line, so a change
that moves the boot backwards fails a test rather than surprising you later.
**It passes, in about 50 seconds.** It used to print six SCSI errors, fail
diagnostics, and take over twenty-five minutes; `docs/12-chipset.md` has that
whole story and the correction to it.

That boot has **no disk on it**, deliberately - it is the machine's own ratchet
and must not depend on a block device. Add one with `--disk 1=PATH` and the
PROM finds it, names it `dks0d1s0` and reads its volume header off the image.
`tests/run-scsi.sh` is that boot.

**"16 Mhz" is a real measurement of this core, and it is not a clock rate.**
`FUN_bfc31594` derives it from CP0 `Count` across a fixed 512-iteration loop,
so what it reports is how many clocks that loop actually took. `Count` itself
is right - `cpu_cop0.vhd` increments a 33-bit counter every cycle and reads
back bits `[32:1]`, half the pipeline clock, as an R4400 does. The loop is slow
because it is **uncached and every instruction is a bus round trip**: about 9
cycles per bus transaction times two instructions is ~20 clocks an iteration,
against ~2 on a real R4400. That 9-10x gap against a real Indy's 100-150 MHz
is the 16.

**Turning the caches on did not move it, and that is correct.** The loop lives
at `0xBFC3159C`, and the whole PROM runs from `0xBFC…` - KSEG1, which the
architecture defines as uncached and which the core therefore refuses to cache.
An earlier version of this file predicted the instruction cache would change
this number; it does not, and it cannot. Two other suspects are ruled out by
measurement rather than argument: doubling `PIT_TICK_DIV` and doubling
`RTC_TICK_DIV` each leave the figure at 16, so it is neither the 8254 nor the
RTC. It is a measurement of uncached instruction throughput and nothing else.

Against `docs/07-mister-port-plan.md`'s milestones: **M0–M3 done, M6 — the "it
boots" milestone — reached, M4 and M5 partly done.**

**SCSI reads blocks off a disk image.** A WD33C93B and seven disk targets are
fitted (`rtl/scsi/`, `docs/12-chipset.md`), and the HPC3's SCSI DMA channel
behind them is real: `rtl/sgi/hpc3_scsi_dma.sv` is this core's first bus
master. With `--disk 1=tests/disks/blank8m.img` the PROM completes its INQUIRY,
names the disk `dks0d1s0` and reads its volume header through a descriptor
chain in main memory. `tests/run-scsi.sh` holds that, and `tests/run-dma.sh`
holds thirty-one properties of the channel that a boot cannot reach.

**The SCSI message phases are built too**, and with them the boot is free of
SCSI errors entirely. `scsi.v` has a real MESSAGE OUT phase, Select-and-Transfer
sends its own IDENTIFY, a plain SELECT raises the second, phase-reporting
interrupt a driver waits for, and the target answers MESSAGE REJECT to anything
it does not implement. The PROM's synchronous-transfer negotiation completes -
rejected, falling back to asynchronous - where it used to time out and reset the
bus on every boot.

**SCSI writes to a disk, and that test found four bugs.**
`tests/run-scsiwr.sh` sends a 512-byte block out through Select-and-Transfer
and the DMA channel, reads it back and compares. It passes, and it is the most
productive test in the repository, because **three of the four bugs it found
were in code every boot runs**:

- `sgi_scsi.sv` left the target's `sd_buff_din` unconnected and tied its own
  output to zero, so every byte written to a disk arrived as zero.
- The mux that replaced it selected on `sd_wr`, which drops on the first ack;
  the flush runs for the whole ack session. `sd_ack` is the line that holds.
- The initiator sent **one CDB byte too many, on every command** - the same
  REQ-as-a-level race that `sat_identify_sent` already fixed for MESSAGE OUT.
- **Every DATA IN byte after the first was the previous one.** `scsi.v` serves
  reads out of a RAM whose address advances on the falling edge of the previous
  ACK, and this initiator sampled on the cycle REQ rose.

That last one had been corrupting every disk read since SCSI was fitted, and
**no boot could see it**: the INQUIRY response is mostly zeroes, `blank8m.img`
is entirely zeroes, and a block of zeroes shifted by one byte is a block of
zeroes. `docs/13-scsi-dma-plan.md` has all four and the two bugs the test image
itself had.

**And the disk is in `hinv`.**

```
>> hinv
                   System: IP22
                Processor: 16 Mhz R4400, with FPU
     Primary I-cache size: 16 Kbytes
     Primary D-cache size: 16 Kbytes
              Memory size: 64 Mbytes
                SCSI Disk: scsi(0)disk(1)
```

**It always was.** Everything this file used to say about the disk being
missing from the ARCS device tree was wrong, and so were the three theories
built on top of it. `tests/run-scsi.sh` ended its run on `--stop-on 'Mbytes'`,
and the PROM prints the SCSI lines *after* `Memory size:`. The simulator was
being stopped a few thousand cycles before the only line anyone was looking for
was transmitted. `docs/13-scsi-dma-plan.md` has the whole diagnosis and the six
addresses that settled it.

`tests/run-scsi.sh` now stops on the disk line and asserts it, so this cannot
quietly come undone. It passes in about 55 seconds.

**A CD-ROM drive and an audio processor are in `hinv` too.**

```
>> hinv
                   System: IP22
                Processor: 16 Mhz R4400, with FPU
     Primary I-cache size: 16 Kbytes
     Primary D-cache size: 16 Kbytes
              Memory size: 64 Mbytes
                SCSI Disk: scsi(0)disk(1)
               SCSI CDROM: scsi(0)cdrom(6)
                    Audio: Iris Audio Processor: version A2 revision 4.1.0
```

**Neither of them does anything.** The audio line comes out of `HAL2_REV`
returning `0x4010` and nothing else — there is no audio path, and the honest
description is that this core reports an audio processor rather than has one.
The CD-ROM is a data-only target: `rtl/scsi/cd_audio.sv` is a stub, so READ TOC
answers zeroes and the audio commands are no-ops. `docs/FEATURES_EVALUATE.md`
has both decisions.

`sgi_scsi.sv`'s `CDROM_IDS` parameter picks which IDs elaborate as drives —
ID 6 by default. It has to be an elaboration-time choice: `CDROM` changes
INQUIRY, the logical block size, READ CAPACITY and the MODE SENSE pages, so a
drive is a different device from a disk rather than a disk with a different
file in it. Mount an ISO on it with `--disk 6=PATH`; `tests/run-cdrom.sh` is
that boot.

**Nothing has ever read a block off the CD.** The 2048-byte logical block path
— four consecutive 512-byte host blocks, scaled ×4 at latch time in `scsi.v` —
is completely untested, and `docs/13` is the argument for not leaving it that
way.

**Newport graphics are built, and the machine draws its own boot screen —
correctly, at 1280x1024, checked pixel by pixel.** `rtl/newport/` is REX3, VC2,
two XMAP9s, two CMAPs and a BT445 RAMDAC. The PROM finds the board, runs POST's
graphics diagnostic on it and passes, initialises all five chips, clears the
screen and draws the whole Indy splash: the gradient background, the hourglass,
"Starting up the system...", the "Stop for Maintenance" button, "WELCOME TO
INDY" and "Silicon Graphics Computer Systems", all in the PROM's own fonts.
`tests/run-newport.sh` writes it to `tests/out/newport-fb.ppm`. VC2's timing
generator walks the tables the PROM loads and drives real sync and display
enable; `--fbdump FILE` writes the frame buffer as a PPM and the harness prints
a video summary on every exit.

**Finding the board moves the console off the serial port**, and that is the
single most important thing to know about this. ARCS installs a
DisplayController with `ConsoleOut|Output` and the PROM stops printing to the
SCC entirely: the banner, POST, the menu and `hinv` are all drawn into the
frame buffer. **Every serial-console test in `tests/` therefore passes
`--no-gfx`**, which fits no graphics board — a real configuration, and the one
every boot log in this repository before now was showing. `run-prom.sh` still
passes, unchanged, in 56 seconds.

**The two defects this file used to describe are closed, and they were five
bugs, not two.** The frame was "a stable 1082 x 813 where the tables say
1304 x 1065, short by about a fifth in both directions", and the drawing
"smeared horizontally". Neither description survived contact with a
measurement:

- **1082 x 813 was a correct 1024x768 raster.** CMAP 1 reported monitor type 0,
  which `Ng1DacInit` reads as "unknown", and on a Guinness the unknown arm
  defaults to low resolution — so the PROM loaded `n1024_r3` and VC2 drew what
  it was given. CMAP 1 now reports 10, the 16-inch Mitsubishi, which is what
  IRIS reports and what selects n1280 at 60 Hz.
- **A duration field of D was being held for D+1 two-pixel units.** Decode all
  nineteen tables in `np_timing.h` and under the D rule each has a single line
  total; under D+1 each has four or five. Every line of a raster is the same
  length, so that settles it without reading a word of the specification.
- **REX3's logic op is at `DRAWMODE1[31:28]`, not [15:12].** The low position
  is COMPARE, which the PROM always sets to 7 to disable it, and 7 is OR — so
  every filled box was OR-ed onto what was underneath. That is the "smear": OR
  with the right colour is *mostly* the right colour, so the screen came out as
  bands of nearly-right grey drifting by a bit or two across a span.
- **REX3 had no graphics FIFO and no back-pressure.** `Ng1TpDrawbitmap` fires
  sixteen `rex3SetAndGo(zpattern, ...)` with one `REX3WAIT` before them and
  none between; without a queue the later ones landed on top of running spans
  and 1317 of a boot's 10,412 GOs were dropped outright.
- **`USER_STATUS` at 0x133C is an alias of `STATUS`**, and it was answering a
  writable register of zero. `REX3WAIT` polls 0x133C, so the PROM was told the
  engine was never busy and never waited for anything. This is the one that
  made the other two possible.
- **And a sixth, found by looking at the screen: the whole picture was
  yellow-green, because BLUE WAS IDENTICALLY ZERO.** The Display Control Bus
  shifts its datum out from the TOP of `DCBDATA0` and the CPU writes to the
  bottom, so it has to be re-aligned first - `dcb_align` does that from the
  write's byte enables, which is what IRIS does at its bus layer. Taking the
  low n bytes instead agrees for a byte, is rescued for a halfword by the
  SWAPENDIAN bit the PROM happens to set there, and drops the third byte of
  every three-byte colour write: `cmapSetRGB` sends `0xRRGGBB00` and the
  machine received `(r, g, 0)`. **A colour is not checkable from the frame
  buffer** - the store holds an 8-bit index, so `--fbdump`, the geometry and
  `run-rex3.sh`'s replay of all 1,310,720 pixels were every one of them
  perfect. `--viddump` shows the PINS instead, the harness prints per-channel
  pixel counts, and `run-newport.sh` fails if a channel is dead.

**`tests/run-rex3.sh` is the ratchet, and it is the strongest test in this
repository.** It boots with `np_rex3.sv`'s `REX3_DEBUG` trace on — one line per
accepted GO with every register the command depends on — and
`tests/rex3_replay.py` replays all 10,412 commands into a model frame buffer
and compares **every one of the 1,310,720 pixels**. Both of the rasteriser bugs
above fail it; the FIFO one fails it by 1102 pixels, which is a number no
eyeball finds on a 1280x1024 screen. `tests/run-newport.sh` now asserts the
frame size exactly rather than with a threshold, and `make -C verilator
vc2test` still drives the timing generator on its own in one second.
`docs/16-newport-plan.md` has the whole scope, the format of the timing tables,
and all of the above written out.

**THE CORE HAS A REAL MISTER TOP LEVEL AND IT SYNTHESISES.** `sgiindy.sv` was
the stock template with a noise generator in it; it is now the machine -
`sgi_indy`, `hps_io`, the PLL, a DDR3 mux, three SCSI virtual drives, the PROM
off the SD card, PS/2 keyboard and mouse, the SCC's tty1 on the board's UART,
and Newport's raster on `VGA_*`. `docs/18-mister-integration.md` is the whole
of it, including what will be wrong on the first hardware run.

**Quartus lives on another machine, and you can drive it.** See the memory
files, which name it: a Linux box over SSH, Quartus 17.0.2 Lite, the repo
checked out at the same path. **Do
not change files or git state there** - push to origin and let the user pull;
running a build is fine.

**THE MACHINE DRAWS ITS OWN BOOT SCREEN ON A DE10-NANO, AND THEN STOPS.**
`releases/SGIIndy_20260830.rbf` is the bitstream and
`releases/SGIIndy_20260830_bootscreen.png` is the screen: the gradient, the
hourglass, "Running power-on diagnostics...", "WELCOME TO INDY" and "Silicon
Graphics Computer Systems", in colour, stable. The frame buffer holds 171
distinct colour indices where it used to hold three.

**IT REACHES THE SYSTEM MAINTENANCE MENU**, and an earlier version of this
paragraph said it did not. It was measured once, sitting at "Running power-on
diagnostics...", and called stuck; the machine simply had not finished, and a
restart gets there. **Give it a minute or two before concluding anything**,
because REX3 now waits for every write to be acknowledged and a pixel costs a
DDR3 round trip - the boot screen is over a million of them. This is the third
time in this file's history that something was declared broken before it was
given time to finish, and it is why `scripts/hwcheck.sh` waits 180 seconds by
default.

**IT RUNS ON A DE10-NANO.** The machine boots on real hardware: the board
reports the video mode as **1318x1024, 29.21 kHz, 27.4 Hz**, and every one of
those numbers is this core's. VC2 emits nothing at all until software sets
`DC_CONTROL[2]` and `CONFIG[0]` and loads its timing SRAM, so a raster that
exact is proof the PROM ran, found Newport and programmed it. Two more things
are measured rather than reasoned now:

* **The PROM download's byte order is RIGHT.** docs/18 called it the one guess
  in the whole path; the image reads back out of DDR3 byte for byte.
* **Main memory works and the PROM sized it** - szmem's walking-bit patterns
  are in place across 48 MB and the region above is clean.

`scripts/deploy.sh` puts a build on a board and `docs/19-hardware-bringup.md`
is the whole procedure. **The FPGA and the HPS share one DDR3**, so
`tools/misterdeploy/ddr3_peek.py` reads the machine's memory from the ARM over
ssh - main memory, the frame buffer and the PROM - which makes hardware as
inspectable as Verilator and is what found every bug below. Busybox `devmem`
reads zeroes there and is not a substitute; it is silently wrong.

**THE WHOLE FLOW COMPLETES AND THE DESIGN MEETS TIMING.** 43 minutes, zero
errors through synthesis, fit, assembler and TimeQuest, `sgiindy.rbf` written.
On a `5CSEBA6U23I7`:

| | | |
|---|---|---|
| Logic | **30,485 / 41,910 ALMs** | 73% |
| Registers | 38,889 | |
| Block memory | 2,236,027 bits, 284 / 553 M10K | 39% / 51% |
| DSP | 51 / 112 | 46% |
| Core clock | constrained **50.0 MHz**, slack **+4.122 ns** | **Fmax 62.98 MHz** |

Every setup, hold, recovery, removal and minimum-pulse-width slack is positive
and **TNS is 0.000 on every clock in the design**. The tightest path anywhere
is the HDMI pixel clock at +0.491 ns, which is framework and not ours. Against
the CPU-only measurement in `syn/README.md` (19,137 ALMs, 63.77 MHz), Newport
plus the memory system plus the top level cost **+11,348 ALMs and about
0.8 MHz**, and 27% of the device is still free.

**There is no diet to go on, and one specific thing not to do.** `np_cmap`'s
`u_cmap1|palette` still reports uninferred, but the entire design spends 960
ALMs on memory, so it is costing nothing worth chasing. **Do not "fix" it by
wiring `cmap1_rgb` into the pixel path** - IRIS displays from `cmap0` alone
(`rex3.rs:4062`) and `cmap1` exists only to answer Display Control Bus reads
at address 3 (`rex3.rs:3168`); `cmap.rs` has no parity notion at all. Making
it look used would change the picture to make a report tidier.

**One clock is unconstrained, and you should know which one.** STA reports "1
Unconstrained Clock" and it is `emu:emu|sclk`. `sgiindy.sdc` leaves it out
deliberately. The comment there used to claim `sclk` was sampled as data and
clocked nothing, which was false - `rtl/sgi/z8530_scc.sv:339`, `:343` and
`:395` are `always @(posedge sclk_a ...)` - and it has been corrected. It is a
genuine second clock domain: an NCO-toggled register, crossed both ways by
Gray-coded FIFO pointers, given local routing rather than a global network.
At 3.6864 MHz through shift-register-depth logic there is ~270 ns of slack to
lose and it will almost certainly work; nothing has measured that. **The
honest fix is to stop using it as a clock** - an NCO output belongs on a clock
enable against `clk_sys`, which deletes the domain and the crossing together.
Constraining it would only quieten the report.

It took two fixes to get synthesis clean, and both are the kind that Verilator
can never find:

- **The root project had no `VHDL_INPUT_VERSION`.** `cpu.vhd` uses sized
  bit-string literals (`40x"0"`), which are VHDL-2008, and the first compile
  stopped in nineteen seconds with 59 syntax errors on perfectly good VHDL.
  `syn/sgiindy_syn.qsf` had carried the setting since the CPU first went
  through Quartus; the root `.qsf` had never been compiled at all.
- **Three arrays became flip-flops and the design would not fit.** 917,504
  bits of them, against a device with about 84,000 registers, and the error
  was `276003: Cannot convert all sets of registers into RAM megafunctions`.
  **This is the real-time clock's lesson again** - an array only becomes an
  M10K when its read goes straight into a register with nothing in the way,
  and a reset on that register is something in the way. `sgi_ds1386.sv` shows
  the shape that works: the read sits ABOVE the `if (reset)`, unconditional.
  `np_vc2`'s SRAM and `fb_linecache`'s two line buffers just needed hoisting;
  `np_cmap`'s palette had two genuinely asynchronous reads and now has two
  registered ones. `np_xmap9` and `np_bt445` were registered too, so that
  every chip on the Display Control Bus answers a read on the same schedule
  and `np_rex3.sv` needs one rule rather than two.

**The memory system is `rtl/mister/`, and both halves have unit tests** -
`make -C verilator ddr3test` and `linecachetest`, neither of which needs
Quartus. `ddr3_mux.sv` carves the 256 MB window MiSTer gives a core (main
memory at 0, the frame buffer at 64 MB, the PROM at 80) and its test found the
region bases truncating and fixed priority starving the rasteriser 62
transactions to 3707. `fb_linecache.sv` is a scanline ahead of the display,
because `newport.sv` does not wait for its frame buffer read - correctly, a
VRAM serial port cannot stall - and against DDR3 that would be a smear that
moves with memory load. Its test drives the display's real pattern and checks
4.0 million pixels.

**The refresh is low and a second clock domain is NOT the fix - that was
wrong.** A faster pixel clock makes the display ask for MORE memory per second
and memory is exactly what it ran out of. Fetching four bytes a pixel instead
of eight is the fix. The paragraph below is kept because its measurements are
right and its conclusion is not.

**The video is correct and the refresh is low, and that is the only thing left
wrong with it.** The raster is exactly the table's - 1318 x 1065, asserted -
but VC2 divides the core clock, so a table written for 107.5 MHz comes out at
50 and the frame rate is about 28 Hz. A faster core cannot fix it and does not
need to: on real hardware the pixel clock is not the CPU clock either. Sixty
hertz wants a second clock domain. Two changes got it from a sixth of 60 Hz to
a half: `PIX_DIV` is 1 now, and **pixel time stops while the generator
fetches** - walking the table costs clocks belonging to no state run, and
letting the pixel clock run through them put them in the picture, which is how
1318 briefly measured 1323.

**Do not move the video to MiSTer's framebuffer-in-DDRAM (`FB_*`).** It was
the obvious fix for the refresh rate and it is wrong twice over. N64 does NOT
use it as its primary output - `N64.sv` drives `VGA_*` and enables `FB_*` only
for the guest's own `VI_DIRECTFBMODE` - and in `sys_top.v` the analog VGA takes
the scaler's output whenever `vga_fb | vga_scaler`, so making it primary would
force every user onto the scaler and **break `direct_video` outright**.

**Interrupts are wired and tested.** INT2 is real — three status registers,
three masks, the two mappable summaries and the timer latches — and drives
`Cause.IP[6:2]`. The vendored CPU's two N64 interrupt lines were replaced with
one five-bit vector (`rtl/cpu/r4300/UPSTREAM.md`). `tests/run-int.sh` follows
an 8254 counter into an Interrupt exception two ways and checks that masking at
either end stops it, because **the PROM cannot test any of this**: it leaves
`L0_MASK` at zero and polls the SCSI chip instead.

The CPU passes the 240-test suite at **2161 checks passed, 3 failed**, against
2101/61 for IRIS's own R4400 on the same expectations. **One** test fails,
`fpu/vec_cvt_from_l`, diagnosed in `docs/10-r4300-integration.md`. The two
cache tests that used to fail now pass, because both primary caches are on.

What is *not* done, and is worth knowing before you plan anything:

- **The GIO DMA engine is a stub.** Its registers behave and a start reports
  instant completion, but no data moves, so the PROM's boot memory clear does
  not clear anything. The PROM believes it worked.
- **The NVRAM is volatile.** The PROM rebuilds its environment on every boot.
  `setenv` will not survive a reset until the array is wired to MiSTer's SD
  save path.
- **INT2 has three sources fitted** of the twenty-odd a real Indy has: SCSI0,
  the SCC and the keyboard controller. Everything else is a device that does
  not exist yet, and `ERR_STAT` is a real zero, so `Cause.IP6` never fires.
- **No Ethernet.** The SEEQ 8003 at `0x1FBD4000` is the last device still
  answering as an unclaimed cycle.
- **Newport is a console, not a graphics card.** The cursor, the DID table,
  24-bit RGB drawing, line and antialiased address modes, the colour DDAs,
  blending, dithering and the GIO64 pixel-DMA path are all absent. Nothing the
  PROM does needs any of them; everything IRIX does needs most of them. See
  `docs/16-newport-plan.md`, milestone N4.
- **The mouse has never been proven.** The keyboard has: two 400-million-cycle
  boots, identical but for the keys, gave 597,166 keyboard-port accesses and
  "Unable to boot; press any key" against 388,421 and "Command Monitor. >>
  5555". Both halves are evidence - the six hundred thousand polls are the
  PROM in its input loop with nothing to read. The mouse waits for IRIX the
  way the keyboard waited for graphics: nothing on the PROM's path moves a
  pointer, `Ng1CursorInit` is a stub in SGI's own driver, and VC2's cursor
  planes are not built. `--key-at CYCLE STR` types at the graphics head;
  `--key-on` triggers on console text, which does not exist once the console
  is a screen.
- **No audio path.** `HAL2_REV` reports a processor that is not there.
- **The SCSI data path is tested at width now, and it is correct.**
  `tests/run-scsiwr.sh` is six phases: one block, four blocks, WRITE(10),
  a three-descriptor scatter-gather chain, 16 KB over four descriptors each
  way, and four 2048-byte logical blocks off the CD-ROM over a chain. Every
  byte compares, first time. What is still untested is *sustained* traffic -
  the installer copies megabytes, and nothing here runs longer than 16 KB in
  one command.
- **The SCSI message phases are minimal.** MESSAGE OUT receives and rejects
  anything that is not an IDENTIFY, and MESSAGE IN carries only COMMAND
  COMPLETE and MESSAGE REJECT. Nothing negotiates, nothing disconnects and
  reselects, and the target's INQUIRY still reports ANSI version 0.
- **The screen is not right yet, and the reason is arithmetic.** The display
  reads a 64-bit word per pixel and uses one byte of it, which at one core
  clock per pixel is 0.80 words a clock against a DDR3 port whose absolute
  peak is 1.00. Hardware delivered 0.52 and missed the first 710 pixels of
  every line, for ever. `PIX_DIV` is 2 again - about 14 Hz - and the real fix
  is to split the frame buffer into two planes the way IRIS does. See
  `docs/18` section 0.
- **The serial console is silent on hardware and the machine is running.**
  With the graphics board unfitted the PROM demonstrably executes - szmem's
  patterns are in DDR3 - and `/proc/tty/driver/serial` on the HPS reports
  `rx:0` on ttyS1. Not garbage, not framing errors: no start bit has ever
  arrived. `sclk` is the suspect and the next build carries a probe that
  settles it - see "the UART probe" below.

## Read first

`docs/README.md` indexes everything. At minimum, in this order:

1. **`docs/12-chipset.md`** — the chipset as built, and the order in which each
   device blocked the next. Read this before touching `rtl/sgi/`.
2. **`docs/13-scsi-dma-plan.md`** — the SCSI DMA engine as built, and the one
   bus phase this core has never had. Read it before touching
   `rtl/scsi/` or `rtl/sgi/hpc3_scsi_dma.sv`, and read it in full if SCSI is
   what you are here for: it is the only place the descriptor format, the
   arbiter's rules and the failed sync negotiation are written down.
3. **`docs/16-newport-plan.md`** — the graphics board as built: the five
   chips, VC2's timing-table format, and every one of the five bugs finding
   the picture wrong turned out to be. Read it before touching
   `rtl/newport/`, and read the driver in `~/repos/irix-657m-src` before
   reading a register map.
4. **`docs/02-address-map.md`** — the register map, now corrected against the
   SGI chip specifications rather than the PROM's inventory.
5. **`docs/10-r4300-integration.md`** — the CPU as built. The byte-lane
   contract, the R4400 presentation, the bugs fixed in the vendored core.
6. `docs/09-cpu-validation.md` — the test suite and the oracle policy. This is
   the document that determines *how you work*.
7. `docs/06-simulation.md` — both harnesses, headless and interactive.
8. `docs/03-boot-prom.md` — the PROM's reset flow and the bring-up order.
9. `docs/07-mister-port-plan.md` — the milestones.
10. **`docs/18-mister-integration.md`** — the top level as wired, the DDR3
    map, and a list of what will be wrong on the first hardware run rather
    than a promise that nothing will be. Read it before touching `sgiindy.sv`
    or `rtl/mister/`.
11. `docs/17-nvram-persistence.md` — the plan for making a `setenv` survive a
    reset, and the M10K constraint that decides its shape.

## Build and run

Hardware, all configured from a gitignored `scripts/local.env`:

```sh
bash scripts/build.sh      # the whole Quartus flow, WITH A GATE: it runs
                           # synthesis, checks Total registers, and REFUSES to
                           # run the fitter if an array did not infer as memory.
                           # That has cost three compiles; the dangerous case
                           # prints no warning at all, only a register count.
bash scripts/deploy.sh     # games dir + PROM + bitstream + launch
bash scripts/setopt.sh gfx=none viddbg=raw   # OSD options without the OSD
bash scripts/console.sh    # the machine's serial console off /dev/ttyS1
bash scripts/grab.sh out.png                 # a checked-fresh screenshot
```

```sh
brew install verilator ghdl sdl2
brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu

tests/uart/run.sh         # the harness's serial decoder, no simulator, ~1 s
tests/run-scc.sh          # the Z8530, ~4 s
tests/run-int.sh          # INT2 to an Interrupt exception, end to end, ~6 s
tests/run-dma.sh          # the HPC3 SCSI DMA channel, no SCSI in it, ~12 s
tests/run-scsiwr.sh       # the SCSI data path, six phases wide, ~40 s
tests/run-cdrom.sh        # a CD-ROM drive on ID 6, listed by hinv
tests/run-cputest.sh      # 240-test MIPS suite on the core, ~7 s
tests/run-prom.sh         # boot the PROM to the Command Monitor, ~56 s
tests/run-newport.sh      # boot with graphics fitted, and check the picture
tests/run-rex3.sh         # every pixel REX3 drew against every command it got
make -C verilator ddr3test      && verilator/obj_dir_ddr3/Vddr3_mux
make -C verilator linecachetest && verilator/obj_dir_lcache/Vfb_linecache
make -C verilator vc2test && verilator/obj_dir_vc2/Vnp_vc2   # VC2's VTG, ~1 s
tests/run-scsi.sh         # the same boot with a disk, and a block read off it

make -C verilator cputest # headless simulator
make -C verilator gui     # interactive simulator (SDL2 + ImGui)

verilator/obj_dir/Vsim_top --prom roms/IP24_Indy/ip24prom.070-9101-011.bin \
    --max-cycles 200000000 --stuck 20000000 --hot
verilator/obj_dir/Vsim_gui --prom roms/IP24_Indy/ip24prom.070-9101-011.bin --run
```

Two toolchain facts worth not rediscovering:

- **GHDL lowers the CPU's VHDL to Verilog for Verilator.** Quartus compiles the
  VHDL directly; Verilator cannot, so `tools/gen_r4300_verilog.sh` runs GHDL's
  synthesis backend over the same sources. No Yosys, nothing checked in — the
  output is gitignored and the Makefile regenerates it. Never reintroduce a
  checked-in netlist. **Delete `rtl/cpu/generated/r4300_wrap.v` after editing
  the VHDL**; the Makefile rule only regenerates it if it is missing.
- **macOS has no `mips-linux-gnu-gcc`**, but the `mipsel` cross GCC is
  bi-endian: `-EB -mabi=n32` produces exactly the ELF32 MSB image the tests
  want.

## Validate everything through Verilator

Every claim about the core's behaviour must be backed by a simulation run, not
by reading the RTL. This has already caught: a CDC race in the SCC's debug tap,
an inverted NaN polarity in the FPU, and — this is the one to remember — a
memory controller that looked completely broken because the *CPU* could not
form a physical address above `0x1FFFFFFF`.

The headless harness (`verilator/sim_cputest.cpp`) gives you:

| Flag | What it does |
|---|---|
| `--elf FILE` | load a bare-metal ELF and boot from its entry point, no PROM |
| `--prom FILE` | load a PROM image at `0x1FC00000` |
| `--trace`, `--trace-from`, `--trace-count` | timestamped bus trace with decoded register names |
| `--stuck N` | no-forward-progress detector — names the address being hammered |
| `--hot` | the most-accessed addresses on exit |
| `--watch HEX` | every bus access to HEX, repeatable. PROM text is uncached, so this is a PC watch: zero hits means a routine was never reached |
| `make -C verilator cputest-dma-debug` | the same harness with the SCSI DMA engine's per-cycle state trace, in its own `obj_dir_dmadbg` |
| `make -C verilator cputest-rex3-debug` | the same harness with one line per REX3 drawing command, in its own `obj_dir_rex3dbg`. `tests/rex3_replay.py` turns that into a frame buffer and compares |
| `--uart` | decode the SCC's `txdb` line and compare it with the byte tap |
| `--testdev` | fit the IRIS test device in GIO64 slot 0 |
| `--no-icache`, `--no-dcache` | run with one or both primary caches off |
| `--console FILE` | also write the console output to a file, flushed per line |
| `--type STR` | type STR at the console once it goes quiet |
| `--type-on TRIG STR` | the same, but only after TRIG has appeared in the output |
| `--irq` | one line per change of INT2's five lines, with the status and mask that decided them |
| `--no-gfx` | leave Newport unfitted, which keeps the PROM's console on the serial port. Every serial ratchet needs this |
| `--fbdump FILE` | write Newport's frame buffer as a PPM on exit |
| `--fbindex` | dump the colour index as grey rather than the colour |

**The unclaimed-address summary is printed on every exit and is the tool that
built the chipset.** It lists every bus cycle no device answered, grouped by
address with counts and first/last cycle; the next thing to build is nearly
always the address at the top of a poll loop.

The interactive harness (`make -C verilator gui`) drives the *same* `sim_top`
and shows the same information live, plus a console you can type into — the
input is a real UART on `rxdb`, so a keystroke only arrives if the SCC's
receiver actually works.

## The oracles, in order

### 1. The bare-metal test suite — `~/repos/iris/cpu-tests/`

240 tests, ~2200 checks, MIPS III/IV, runs on the CPU with no OS. Read
`cpu-tests/docs/oracle.md` and honour that policy. It is **not** forked into
this repo, deliberately: it is a general MIPS suite that also runs on real SGI
hardware.

The standing rule, which has already been load-bearing: **never edit an
expectation to make a test pass.** If the core is wrong, fix the core.

### 2. The chip specifications, then IRIS

`reference/specs/` holds the SGI **MC**, **HPC3**, **GIO64**, **VDMA**, **IOC**
and **Z8530** specifications as PDFs. They are gitignored and they are the top
authority — every conflict resolved in their favour during M2 turned out right,
including against the PROM's own annotated inventory, whose *names* are shifted
by a register slot in several places even though its addresses are correct.

The PDFs have no text layer that `pdftotext` will read (it is not installed
anyway), but the streams are plain Flate — a dozen lines of Python pulls the
whole register map out. Do that rather than guessing; it is how `RPSS_CTR` was
found at MC + `0x1000` after the project had spent a while looking at `0x80`.

`~/repos/iris` is a working Rust Indy emulator that boots IRIX 6.5 to a
desktop, with readable implementations of every device this core still needs:
`mc.rs`, `hpc3.rs`, `ioc.rs`, `hal2.rs`, `ds1x86.rs`, `eeprom_93c56.rs`,
`pit8254.rs`, `rex3.rs`, `vc2.rs`, `xmap9.rs`. Where the spec is silent about
what software actually expects, IRIS is the tiebreaker — it is validated by the
most demanding test there is.

`reference/prom/ip24prom-011-5.3-B10.asm` is a full annotated disassembly of
the PROM with 147 hand-written symbol names. When the PROM stalls, find the
address in there; the answer is usually three instructions away.

Keep MAME (`reference/mame/`) as a third opinion. `roms/` carries one real
serial capture, `IP22_Indigo2/ip22prom.070-8127-002.capture.txt.gz` — there is
**no IP24 capture**, so nothing this core prints has been diffed against
hardware yet. See "Things to ask the user for" below.

### 3. Real hardware

The user has physical SGI hardware and can run test binaries on it —
`docs/11-running-on-hardware.md` covers which machines and how. **Batch your
requests**: accumulate a set of questions and ask for one run, not ten. Commit
any hardware-confirmed result under `tests/hardware/`.

## Where to pick up

### The three things that are done, so you do not redo them

**The caches are on.** Both primary caches, filled over the ordinary SGI bus,
and the two cache tests that used to fail now pass. The suite went from 2155/9
to **2161/3** and from 17.1M clocks to 3.5M. `docs/10-r4300-integration.md`'s
"Caches" section has the whole thing.

| | cycles | bus transactions | checks |
|---|---:|---:|---|
| both off | 17,138,359 | 1,977,165 | 2155 / 9 |
| **both on** | **3,497,582** | **224,774** | **2161 / 3** |

What the caches did *not* fix, and would be the next honest performance work,
is that a PROM boot is dominated by **timed waits**, not by throughput: caches
on, the boot to `hinv` is 37.1M clocks against 37.3M with the data cache off.
The 8254 and the RTC are already run fast in simulation
(`docs/12-chipset.md`); pushing that further is bounded by `calibrate_delay`
restarting forever if the timer is made too fast.

**Interrupts are wired.** INT2 drives `Cause.IP[6:2]`; the vendored CPU takes a
five-bit `irq_lines` in place of upstream's two N64 lines. `tests/run-int.sh`
proves the path. Nothing about this is speculative any more.

**The HPC3 SCSI DMA engine is built, and the core has an arbiter.**
`rtl/sgi/hpc3_scsi_dma.sv` is channel 8 — descriptor fetch, byte-at-a-time
transfer, chaining, XIE, FLUSH — and `sgi_indy.sv` carries the two-master
arbiter that lets it reach main memory. `wd33c93.sv` hands DATA IN and DATA OUT
bytes to it when `Control[7:5]` is non-zero; the polled DBR path is untouched
and still what the chip's own diagnostics use. `tests/run-dma.sh` is 31 checks
on the channel with no SCSI in the image at all.

Do not rebuild any of that, and in particular **do not add a general bus
crossbar**. The arbiter covers one port on purpose; the Ethernet channels will
want the same port and the same arbiter will serve. `docs/13-scsi-dma-plan.md`
has the register map, the three-word descriptor, and the four things the plan
for it got wrong.

### A warning about what this file used to say

**This file has now been confidently wrong twice, both times about SCSI, and
the second one was worse.** The first is below: it named the missing interrupt
line as the cause of six phantom disconnects, and the real cause was the `LCI`
rule. The second was three successive theories about why the disk was missing
from the ARCS device tree, when the disk had never been missing from it - the
harness was stopping the run one line early. Nobody checked whether the PROM
was printing the line before working out why it was not.

**So: before explaining an absent line, prove the line is absent.** One
`--watch` on the address of the `printf` that would emit it costs one run and
settles it. That is cheaper than any theory about why it did not happen, and it
is the check that both of these failures skipped.


The previous version of this section said the SCSI scan's six phantom
disconnects were caused by the missing interrupt line, and that wiring INT2 to
the CPU would fix them. **That was wrong, and it was written with enough
confidence to send a session straight into building the right thing for the
wrong reason.** The interrupt line was wired; the boot came out byte for byte
identical. The PROM leaves `L0_MASK` at zero and polls the WD33C93's AUX STATUS
register during POST, so INT2 was never in that path at all.

The actual cause was one rule of the part: a command written while an interrupt
is still pending must bounce off `LCI`, and this model only checked `CIP`. The
PROM's own command-issue routine at `0xBFC1F64C` is built around that rule —
issue, wait for `CIP`, test `LCI`, and on `LCI` read the status register to
clear the stale interrupt and retry. `docs/12-chipset.md` has the full
diagnosis and the disassembly.

Two things generalise from it. **Read the driver, not just the device**: three
routines of PROM disassembly settled in minutes what a boot log had made look
like an interrupt-timing problem. And **the `--irq` flag exists now**; one line
of its output (`L0 02/00` — source asserted, mask zero) is what retired the
wrong theory.

### THE FIRST REAL FAILURE: the IRIX 5.3 installer panics after the copy

**This is the most valuable bug this project has, and it should be the next
thing worked on.** The machine got further than it ever has: the PROM's
"Install System Software" ran, offered `a) Local SCSI CD-ROM drive 6`, read
the installer off the CD, and copied it to the disk:

```
Copying installation program to disk.
......... 10% ......... 20% ......... 30% ......... 40% .........
......... 60% ......... 70% ......... 80% ......... 90% .........

Copy complete

Exception: <vector=UTLB Miss>
Status register: 0x2<IPL=8,MODE=KERNEL,EXL>
Cause register: 0x8008<CE=0,IP8,EXC=RMISS>
Exception PC: 0x880075b4, Exception RA: 0x880076f4
exception, bad address: 0x0
HPC3 bus error status register: 0x0
  Saved user regs (&gpda 0xa8740e48, &_regs 0xa8741048):
    t8 a8740000 t9 0 at 0 v0 0 v1 0 k1 0
    gp a8740000 fp 0 sp 0 ra 0
PANIC: Unexpected exception
```

**Read what the exception actually says before theorising.** `EXC=RMISS` is a
TLB refill on a load and the bad address is `0x0`, so software loaded from
virtual address zero. Zero is unmapped in KUSEG, so **the CPU is behaving
correctly** - a TLB refill there is the architecturally right answer, and the
exception frame is well formed. This is a null pointer in the guest, not a
CPU fault. `HPC3 bus error status register: 0x0` says the chipset did not
report a bus error either.

**THE LEADING HYPOTHESIS HAS BEEN TESTED AND IT IS WRONG.** This file used to
say the crash was probably corrupted data - the copy being the first
substantial write this core had ever done, against a write path covered by
exactly one WRITE(6) of one block, and the CD read path covered by nothing at
all. That was a reasonable place to look and it was the first thing to widen.
`tests/run-scsiwr.sh` is now six phases:

| phase | what it does |
|---|---|
| 1 | one block, WRITE(6)/READ(6), one descriptor |
| 2 | four blocks in one WRITE(6), so the target advances its own LBA |
| 3 | four blocks through WRITE(10)/READ(10) - a ten-byte CDB |
| 4 | four blocks out over three data descriptors, back over two |
| 5 | **16 KB** over four descriptors each way, WRITE(10) |
| 6 | four 2048-byte logical blocks off the **CD-ROM**, over a chain |

**Every byte of all six compares, first time.** The patterns are per-phase
seeded and byte-asymmetric, the CD read is at a non-zero LBA so a missing x4
scale would show, and the descriptor splits differ between the write and the
read so a chaining bug cannot cancel itself. So the data path is not where the
installer's null pointer comes from, at least at that scale.

**What that leaves.** In rough order of how much they are worth:

1. **Sustained traffic.** The installer copies megabytes; the widest thing
   tested is one 16 KB command. Something that only fails after thousands of
   commands - a descriptor pool that wraps, an interrupt that is missed under
   load, the message phases under repetition - is still open.
2. **The GIO DMA engine in the MC is a stub that reports success.** The PROM's
   boot memory clear "works" and clears nothing. A null pointer is what an
   uninitialised *pointer* looks like, and a machine whose memory clear is a
   lie is a machine where anything that expected zeroed memory got whatever
   was there. This is now the most suspicious thing in the core that the
   installer touches and nothing tests.
3. **The message phases are minimal.** Nothing disconnects and reselects. A
   target that never disconnects is legal, and IRIX's driver may or may not
   care - but the installer is the first software here that would notice.

Do not start from the CPU. It passes 2161/3 including the TLB tests, and the
exception it produced is correct for the address that was loaded.

The image and the exact steps are reproducible: `IRIX 5.3 XFS.iso` on ID 6 as a
CD-ROM, a writable disk on ID 1, maintenance menu option 2.

### 3. Everything after that

**Finish the hardware bring-up first, and it is now a picture rather than a
question of whether it runs.** In order:

1. **Split the frame buffer into two planes.** `docs/18` section 0 has the
   whole thing, validated against IRIS's `rex3.rs`. It is what gives
   `PIX_DIV = 1` and the 27 Hz back, and it is the largest single
   improvement left anywhere in this core.
2. **Answer the serial console.** The next build carries an OSD entry, "UART
   debug", that puts two 8N1 transmitters sending 0x55 at 9600 baud on
   `UART_TXD` - one clocked from `clk_sys`, one from `sclk`. If the first
   arrives and the second does not, `sclk` is dead and the SCC was never at
   fault; if neither does, the fault is between the pin and `/dev/ttyS1` and
   nothing inside the machine is worth looking at. **IRIS cannot help here**
   and it is worth knowing before you try: `z85c30.rs` has `get_clock()`
   returning zero and hands bytes to telnet, so it has no bit-level
   serialiser and no equivalent of this clock domain at all.
3. **REX3's DR_FILL has no back-pressure.** It asserts a write every cycle
   and counts them in a 4-bit `wr_outstanding`, which is correct against a
   memory that accepts one per cycle and wrong against `ddr3_mux`, which
   takes one transaction at a time. Most fill writes are dropped. Nothing
   tests it.

**Three bugs in a row here have been the same bug**: RTL written against the
simulator's one-cycle memory, meeting real DDR3. `ddr3_mux` took a held
request twice; `fb_linecache` was tested at half the pixel rate the hardware
runs; `DR_FILL` fires writes nothing accepts. **Before trusting any unit test
in `rtl/mister/`, check that its memory model is not kinder than the bridge**,
and check that the parameters it hard-codes still match the RTL.

The design synthesises; what it has
never done is run. The first build is a bring-up exercise and
`docs/18-mister-integration.md` lists what to expect, but two are worth
repeating here because they are the ones that will waste a day:

* **The PROM loads itself; you do not need the OSD.** `boot.rom` in the repo
  root is PROM Monitor 5.3 under the name MiSTer's framework uploads
  automatically out of the core's directory at startup - index 0, the same
  index the `FS0` menu entry produces, so one decode in `sgiindy.sv` serves
  both and this needed no RTL. It goes at
  `/media/fat/games/SGIIndy/boot.rom`. The framework releases reset *before*
  it sends the file, so the CPU fetches garbage for a moment and
  `prom_download` re-asserts reset; that is designed for rather than a
  symptom, and the PROM region is read-only to the core so nothing in that
  window can damage the image about to run.
* **If it executes garbage from the very first fetch, invert the PROM
  download's byte swap in `sgiindy.sv`.** That is the one thing in the whole
  path that is reasoned rather than measured - `hps_io`'s WIDE mode byte order
  within `ioctl_dout`.
* **Bring it up with "Graphics board: None".** The console goes to the UART
  pins and you get the familiar serial boot to the Command Monitor, which is
  far easier to diagnose than a screen.

Then, in order:

1. **NVRAM persistence**, which now has a plan: `docs/17-nvram-persistence.md`.
   The environment is in the DS1386's NVRAM and nowhere else - settled by
   measurement, because IRIS's two save files point at the other one - and the
   constraint that decides the design is that its two banks have exactly one
   reader and one writer each. Do not add a third port. The harness half
   (`--nvram FILE`) is testable today and is the whole feature minus hardware.

2. **A second clock domain for the video**, which is the only thing left wrong
   with the picture. See the refresh-rate paragraph above; the line cache is
   already the natural crossing for the pixel side, and **do not reach for
   `FB_*` instead** - the reasons are written down.

3. **The GIO DMA engine** in the MC, for the boot memory clear. Registers exist
   and a start reports instant completion; no data moves - so the PROM clears
   nothing and believes it did. This is the most suspicious untested thing the
   IRIX installer touches, now that the SCSI path has been widened and cleared.

4. **Ethernet**, the last device still answering as an unclaimed cycle
   (`0x1FBD4000`, SEEQ 8003). It will want the MAC address out of the HPC3-side
   93CS56 at `0x1FBB0008`, which is plain storage today - `docs/17` says where
   that fits.

5. **The rest of Newport** - the cursor, the DID table, 24-bit RGB drawing, the
   line address modes, the colour DDAs, blending and the GIO64 pixel-DMA path.
   Nothing the PROM does needs any of them; most of what IRIX does does. See
   `docs/16-newport-plan.md`, milestone N4.

**Not on the list, and deliberately: SDRAM.** Everything is in DDR3, which is
what N64 does with its own main memory, and the core needs no SDRAM module at
all. Moving main memory onto one would be a real win - `hinv`'s "16 Mhz" is a
measurement of uncached bus round trips and DDR3 through the f2h bridge is both
slower and more variable than SDRAM - but it needs a controller, and the user
has chosen a single RAM configuration. `docs/18` has the analysis, including
what a dual board would have been worth.

### Things to ask the user for

Three things, batched.

**A serial capture of a real Indy booting `070-9101-011`.** `roms/` has a
capture for the IP22 but not the IP24, so the console output above has never
been diffed against hardware — the milestone plan's definition of M3 asks for
exactly that and it cannot currently be met.

**And the `cache/` group of cpu-tests on real iron.** The caches are on now and
the only oracle they have is the suite running under Verilator against
expectations written from the R4000 manual. `docs/11-running-on-hardware.md`
covers how to run the suite on the user's machines, and the eight `cache/`
tests are the ones worth the trip: they are the only part of this core whose
correctness argument has never been checked against the part it claims to be.
`identity/config_k0_writable` is worth watching too - it writes `Config.K0 = 2`
with dirty lines live, which is a coherence hazard on real hardware and passes
here.

**And what `hinv` actually prints on a real IP24 with a disk attached.** The
SCSI work is now aimed at a target nobody here has seen: this PROM's `hinv`
lists no SCSI at all - not the disk, and not the controller either - and `-v`
adds nothing. Two readings fit that and they lead different places. Either the
inventory is built during the bus scan and the failed sync negotiation is
keeping the disk out of it, or this PROM's `hinv` simply does not report SCSI
and the whole "definition of done" in `docs/13` is aimed at the wrong string.
One paste of a real machine's `hinv` output settles it before any more work
goes into the target model. The strings the PROM carries for it are
`"SCSI Disk"`, `"%*s: scsi(%u)disk(%u)\n"` and
`"%*s: Controller %u, ID %u, removable media\n"`, all reached from
`FUN_bfc4119c`.

## Ground rules

- **No identifying information in this repo.** No personal names, emails,
  usernames, absolute home paths, machine names, or links to personal accounts
  in any committed file or commit message. Upstream project attribution
  (MiSTer-devel, IRIS, the MiSTer N64 project, OzOnE, MAME) is correct and
  should stay.
- **The licence is GPL-3.0** because the vendored CPU is. See `NOTICE.md`.
- **Vendor VHDL, not netlists**, and keep `rtl/cpu/r4300/` diffable against
  upstream. Every local change is marked `-- SGI:`, listed in
  `rtl/cpu/r4300/UPSTREAM.md`, and provable with `tools/diff_upstream.sh`. If
  you change the vendored CPU, update that file in the same commit **and rerun
  `tests/run-cputest.sh`** — that suite is the only reason to believe a change
  to the CPU is safe.
- **PROM images are committed** in `roms/`, at the repository owner's decision.
  They are SGI-copyrighted firmware not covered by this repository's licence.
  `reference/` stays gitignored.
- Comment the *why*, not the *what*. The best asset this codebase inherited is
  its comments explaining bugs found the hard way.

## Traps already paid for

Do not rediscover these:

- **Upstream assumptions that are true of an N64 and false of an SGI are not
  marked as assumptions.** `cpu_cop0.vhd` truncated every TLB translation to 29
  bits, which is invisible on a machine with 512 MB of address space and fatal
  on one that puts high local memory at `0x20000000`. It presented as "the
  memory controller does not work", three layers from the cause. There will be
  more of these; suspect the CPU when a device looks impossible.
- **The CPU's `mem_*` byte lanes are not symmetric.** Reads want the aligned
  doubleword shifted right by the address offset; writes swap the halves when
  the access is 64-bit or lands in the upper word; **byte enables are
  meaningless on a read** — use `bus_aoff` to tell which word a device register
  access actually addressed. `rtl/cpu/r4300_bus.sv` has the derivation.
- **MC registers answer at `reg + 4`, not `reg + 0`**, and that is wiring, not
  convention: the chip is on the low 32 bits of SysAD and the *odd* word
  address is the big-endian one. HPC3, IOC2 and the RTC are the opposite —
  ordinary 32-bit registers on a stride of four, both words live.
- **IOC2 and the RTC put their 8-bit registers in the LOW byte** of the word,
  the byte at `word + 3`. The PROM reads them with `lbu` at `base + 3` and
  drives the whole power-on console through byte accesses at `0xBFBD9833`.
- **`cpu.vhd`'s `error_*` outputs are N64 debugging aids, not faults.** They
  flag traps this suite raises on purpose. Only a wedged pipeline and a FIFO
  overflow abort a run.
- **The SCC's channel naming is inverted between sources.** IRIS calls the pair
  at IOC `+0x30`/`+0x34` channel B / tty1 — that is the SGI console. The DE1
  sandbox called the same window channel A / Port 1. `rtl/sgi/sgi_scc.sv`
  follows IRIS.
- **The PROM prints through WR8 on the *command* port**, not the data port:
  `pon_putc` (`0xBFC03C34`) points WR0 at register 8 and writes the character to
  `0xBFBD9833`. The datasheet allows both; a model that only pushes the TX FIFO
  on data-port writes accepts the entire boot banner and prints nothing.
- **A bare-metal image that never programs WR5 gets nothing out of the SCC**,
  on this core and on real hardware alike, because the transmitter is disabled.
- **GHDL 6.0.0 crashes** (`netlists-utils.adb:166`) on a `numeric_std`
  comparison whose operands differ in width. The generator works around the one
  instance in `cpu.vhd`; if a new one appears, that is the symptom.
- **Do not change what the CPU reports itself as.** An Indy shipped with an
  R4000PC, R4400SC, R4600 or R5000, and it is tempting to read that list as a
  menu. It is not: the identity is load-bearing, because nothing reports the
  TLB entry count architecturally and software infers it from `PRId`. IRIX
  writes TLB indices up to 47, and a part claiming 32 entries aliases those
  onto 0-15 and corrupts its own page tables. `docs/10-r4300-integration.md`
  has the argument. Changing the identity would also do nothing for speed -
  it is the same RTL with different identity registers.
- **`hinv`'s clock figure is a throughput measurement, not a clock.** See
  "Where this is" above before concluding the core is too slow.
- **A cache fill must not signal `mem_done` in the same clock as its last data
  beat.** The data cache answers the access out of the line in the cycle it
  sees `ram_done`, reading port B of a RAM whose port A is writing that beat on
  the same edge - and a store merges in on port B on that same edge.
  Read-during-write across ports is undefined, so it becomes a race on process
  order. The symptom was not "the cache is slightly wrong": it was the test
  suite loading a stale jump-table entry, jumping through it, and taking 82,000
  exceptions. `rtl/cpu/r4300_bus.sv` spends a state on the gap.
- **The CPU must stay in reset until the cache tags are clear.** Each cache
  answers `SS_reset` by walking 512 tag entries one per clock and neither looks
  at `reset_93`. The four-clock settle that was enough to latch the boot PC let
  the first cached access land inside that walk, where the data cache does not
  latch it, and `error_stall` fired 4096 clocks later. `SETTLE_CLOCKS` in
  `r4300_wrap.vhd` is 1024.
- **A cache can be completely broken and still return correct data.** The
  instruction cache tagged lines with a physical address while comparing a
  virtual one, so every fetch missed - and every fetch was still answered
  correctly, out of a freshly filled line, at 3.5x the bus traffic of no cache
  at all. Nothing failed; it was only visible as a transaction count. Measure
  hit rates by counting bus cycles, not by watching tests pass.
- **A bus master that is not the CPU must HOLD its request, not pulse it.** The
  CPU pulses `bus_req` for one cycle because it is the only master and the port
  is always its to take. The HPC3 DMA engine copied that shape, and on any
  cycle the CPU wanted memory the request was dropped and the engine waited
  forever for an answer nobody had heard. It did not present as an arbitration
  bug: it presented as a transfer that moved exactly eight bytes and stopped,
  which sent the first guess straight at byte lanes. Eight was a coincidence.
- **`ram_ack` belongs to whoever asked for it.** `bus_ack` is an OR of every
  device's ack, so a DMA cycle's answer completes the CPU's outstanding cycle
  with the DMA's data on it unless something remembers who the outstanding
  request belonged to. `ram_owner_dma` in `sgi_indy.sv` is that something.
- **Reading HPC3's SCSI control register acknowledges its interrupt**, and the
  byte count sits in the same doubleword. A driver polling `ch_active` there
  loses its own interrupt, and a device model that does not take `bus_aoff`
  cannot tell the two reads apart. `tests/dma/dmatest.c` covers both.
- **Nothing could free a wedged SCSI target until this session.**
  `wd33c93.sv`'s `scsi_rst` was hardwired to zero, so a target left holding BSY
  held it for the rest of the boot and the ASR read `0x20` forever. HPC3's
  `ch_reset` falling edge now resets the controller and pulses RST on the bus,
  which is what the driver's "resetting SCSI bus" message always claimed.
- **The PROM's SCSI buffers and descriptors are all in KSEG1**, so the DMA
  engine has no cache-coherence problem with them. That is a property of this
  software, not of the machine: an OS that used KSEG0 would break and nothing
  here would detect it. Everything in `tests/dma/dmatest.c` is uncached for the
  same reason.
- **`--type-on` triggers fire in order, so one that stops being printed blocks
  every keystroke behind it.** POST passing removed `[Press any key to
  continue.]`, and the run then sat at the menu forever with a `5` queued
  behind a trigger that would never match. It looks exactly like a hang.
- **A handler that clears a level-sensitive interrupt can be re-entered.** The
  clearing store sits in the CPU's write FIFO and `eret` does not wait for it
  to drain, so the line is still up when the pipeline restarts. Read the device
  back before returning. `tests/int/inttest.c` found this, and the symptom was
  not a hang: it was a second entry whose `Cause` had already lost the bit that
  caused the first.
- **The PROM does not use interrupts during POST.** It masks `LOCAL0` off
  entirely and polls the WD33C93's AUX STATUS bit 7. A boot to the Command
  Monitor therefore proves nothing whatever about INT2, and reasoning about
  device timing from the console will mislead you - it already did once, and
  the wrong conclusion was written into this file. `--irq` and
  `tests/run-int.sh` are the tools that answer interrupt questions.
- **AN ARRAY ONLY BECOMES A MEMORY IF ITS READ GOES STRAIGHT INTO A REGISTER,
  AND A RESET ON THAT REGISTER IS SOMETHING IN THE WAY.** This has now cost
  two separate compiles. `sgi_ds1386.sv` shows the shape that works: the read
  sits ABOVE the `if (reset)`, unconditional. Nothing in simulation will ever
  tell you - Verilator does not care - and Quartus's own diagnosis is one line
  of Info per array plus one fatal error at the end,
  `276003: Cannot convert all sets of registers into RAM megafunctions`.
  **Grep the map log for `Info (276014)` before believing an array became a
  memory**, and check `Total registers` in the map summary: 37,773 is right
  for this design and anything in the hundreds of thousands is an array that
  did not infer.
- **A test that has never failed is not a test, and a stale binary passes
  beautifully.** `ddr3test` reported PASS in two suite runs after its port had
  changed shape, because the runner invoked the binary directly and nothing
  rebuilt it. Rebuild before believing a unit test, and put a deliberate
  regression back in to watch it fail at least once.
- **Sample a model's outputs on the same side of the clock edge the hardware
  does.** Three testbenches in this repository got this wrong in one session
  and all three read as something else: a bridge that decided acceptance after
  the edge made a working mux look completely dead; the same mistake with a
  handshake made a working cache report zero pixels checked and zero misses,
  which reads like a pass; and reading a combinational data-valid after the
  edge lost the last word of every burst so no burst ever completed.
- **Two unit tests, one on each side of an interface, can both pass while the
  sides disagree.** The DDR3 mux asserted its burst handshake at burst END and
  the line cache waited for it to mean burst START. Each test modelled its own
  side's assumption. If an interface has two implementations, one test has to
  see both.
- **A picture is not a test, and three Newport bugs proved it.** The logic op
  read from the wrong bits, a missing graphics FIFO and a status register that
  never reported busy all produced a screen that a human looked at and called
  "smeared" — a description that fits about forty different causes and none of
  them precisely. What settled it in minutes was `+define+REX3_DEBUG`: one line
  per drawing command, compared against `ng1_tp.c`, then replayed in Python and
  diffed against the frame buffer. **Before theorising about a wrong picture,
  print what the engine was asked to draw.** `tests/run-rex3.sh` is that, kept.
- **A device model that reports "not busy" is worse than one that hangs.**
  REX3's `USER_STATUS` answered zero, so `REX3WAIT` returned immediately, so
  the PROM wrote registers into running commands for as long as this core has
  had graphics. Nothing failed; the machine just drew slightly wrong things
  slightly too often. When a driver polls a status bit, check that the bit can
  actually be set — an alias register decoded as its own storage will read a
  perfectly plausible zero forever.
- **Where a driver batches writes, the hardware has a queue.** Sixteen
  `rex3SetAndGo`s in a row with one wait in front of them is not sloppy driver
  code, it is a driver written against a 60-deep FIFO. A model without the
  queue must stall the bus instead, which is what the part does when the FIFO
  fills — silently dropping the commands it cannot hold loses 13% of a boot's
  drawing and looks like nothing at all.
- **The Display Control Bus shifts from the TOP of `DCBDATA0`, and the CPU
  writes to the bottom.** A byte store lands in the lane it addressed - the
  driver uses `.bybyte.b3` - so the datum has to be re-aligned to the top
  before the bus sends it, which is what IRIS does at its bus layer and what
  `dcb_align` in `np_rex3.sv` does here with the write's byte enables. Taking
  the low n bytes instead agrees for a byte, is rescued for a halfword by
  SWAPENDIAN, and drops the third byte of every three-byte colour write:
  every colour in the machine lost its blue channel and the boot screen came
  out yellow-green, with a perfect frame buffer dump and perfect geometry.
  **A colour is not checkable from the frame buffer** - the store holds an
  index. `--viddump` shows the pins; `--fbdump` shows the store.
- **The old note, kept because it is the same bus and the first way it was
  wrong:** a byte-wide DCB transfer carries its datum in the LOW byte of
  `DCBDATA0` — the driver stores it
  through `rex->set.dcbdata0.bybyte.b3`, and a halfword through `.byword` at
  the same end. Taking the byte from the top instead sends whatever was left in
  the register, and the first casualty is VC2's index register: every indexed
  access lands on register 0. The symptom was not a blank screen but
  `Ng1RegisterInit` reading `DC_CONTROL` back as zero, ORing its bits into
  that, and writing the video timing enable straight back **off** a few
  thousand clocks after turning it on — eighty scan lines a boot instead of
  tens of thousands, looking exactly like a timing bug.
- **`~/repos/irix-657m-src` is the IRIX 6.5.7m source and it contains the
  PROM's own drivers.** `stand/arcs/lib/libsk/graphics/NEWPORT/` is the code
  this PROM image runs for graphics, and
  `stand/arcs/ide/fforward/graphics/NEWPORT/` is the diagnostic POST runs on
  it. Read those before reading a register map: `test_rex3` in `rex3.c` is
  where every REX3 register's real width is written down, and it is the reason
  POST's graphics test passes.
- **A UNIT TEST WHOSE MEMORY MODEL IS KINDER THAN THE BRIDGE IS NOT A TEST.**
  This has now been the whole bug three times running. `tb_ddr3` drove every
  master as a one-cycle pulse and never reproduced a master that HOLDS its
  request through the acknowledgement, which is what REX3 does - the mux took
  the same transaction twice and the rasteriser painted the CPU's instruction
  fetches onto the screen. `tb_linecache` hard-coded `PIX_DIV = 2` long after
  `newport.sv` moved to 1, handing the fill engine exactly twice the time it
  had - it reported zero misses while hardware missed 710 pixels of every
  line. And a testbench that reacts to an acknowledgement within the cycle
  that carries it is quicker than any state machine can be, so it never
  presents the stale request at all: model the one-cycle reaction delay or the
  test passes against broken RTL.
- **The dangerous RAM-inference failure prints nothing.** `Info (276014)` is
  the arrays Quartus COULD see. Four line buffers declared inside a `generate`
  loop produced no message of any kind, 127,000 extra flip-flops and a fit
  that failed at 291% after twenty-five minutes. `scripts/build.sh` now gates
  on `Total registers` between synthesis and the fitter for exactly this
  reason. ~38,000 is right.
- **Do not touch `sgiindy.qsf` while Quartus is running**, `git checkout`
  included. It stops with `Error (125085)` and then rewrites the file,
  inlining the 266 lines `sys/sys.tcl` sources - which is what the warning at
  the top of that file means by "It will mess this file!".
- **Busybox `devmem` reads zeroes from the core's DDR3 window** and is
  silently wrong. Use `tools/misterdeploy/ddr3_peek.py`, which mmaps
  `/dev/mem`. Note the byte order: the core numbers bytes big-endian within
  each 64-bit word and the ARM reads little-endian, so **each eight-byte group
  comes back reversed** - the PROM's `0b f0 00 f0` reads as `00 00 00 00 f0 00
  f0 0b`, and a pixel's colour index is the FIRST ARM byte of its group.
- **IRIS is the oracle for what a device holds and not for how it is clocked.**
  It settled the frame buffer layout in minutes; it has nothing to say about
  `sclk`, because `z85c30.rs` has no serialiser at all. On this machine it is
  at `../iris`, not the `~/repos/iris` this file names.
- **Three clocks run fast in simulation** and are parameterised so hardware
  keeps the real value: `sclk`, `RTC_TICK_DIV` and `PIT_TICK_DIV`. See
  `docs/12-chipset.md` — `calibrate_delay` restarts forever if the 8254 is made
  *too* fast, so there is a limit to that trick.

Report progress as you complete each milestone, with the simulation output that
demonstrates it.
