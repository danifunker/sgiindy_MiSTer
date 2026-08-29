# Newport graphics — the subsystems, and the order they unblock each other

`Graphics: Indy 24-bit` is one line of `hinv` and five chips. This is the scope,
written before the build so that the build can be checked against it.

Read `docs/08-resume-prompt.md` for the state of the machine and
`docs/02-address-map.md` for where Newport sits. This file is about what is
inside `0x1F0F0000`.

## The oracle that changes everything

`~/repos/irix-657m-src` is the IRIX 6.5.7m source, and it contains **the PROM's
own Newport driver**:

| Path | What it is |
|---|---|
| `stand/arcs/lib/libsk/graphics/NEWPORT/ng1_init.c` | probe, DAC/XMAP/CMAP/VC2 init, `rex3Clear`, cursor init |
| `stand/arcs/lib/libsk/graphics/NEWPORT/ng1_tp.c` | the text port — every drawing operation the console makes |
| `stand/arcs/lib/libsk/graphics/NEWPORT/np_timing.h` | the VC2 video timing tables, per monitor |
| `stand/arcs/ide/fforward/graphics/NEWPORT/` | the diagnostics: `rex3.c`, `vc2.c`, `xmap9.c`, `bt445.c`, `vram3.c` |

This is not a reimplementation to be guessed at. It is the code this PROM image
runs, so **the definition of "correct" is "this source is satisfied"**, and
every milestone below is phrased as a function in it returning what it wants.
The chip specifications in `reference/specs/` (`rex3.pdf`, `vc2.pdf`,
`xmap9.pdf`, `rb2.pdf`, `ro1.pdf`, `dmux1.pdf`) stay the top authority for the
parts the driver never exercises.

The headers it includes — `sys/ng1hw.h`, `sys/vc2.h`, `sys/xmap9.h` — are
**not** in the release. Field names come from the driver's use of them and from
`~/repos/iris`, which implements all five chips and boots IRIX 6.5 to a desktop.

## The five chips

```
        GIO64 (0x1F0F0000)
              |
           [ REX3 ]  rasteriser, register file, and the DCB master
              |  \
   framebuffer|   \  Display Control Bus (DCBMODE / DCBDATA0 / DCBDATA1)
              |    \
           [ VRAM ] +-- 0 --> [ VC2  ]  video timing, cursor, DID   + 32K x 16 SRAM
              |     +-- 1-3 -> [ CMAP ] x2  colour palette
              |     +-- 4-6 -> [ XMAP9] x2  pixel format / mode table
              |     +-- 7 ---> [ BT445 ]    RAMDAC: gamma, cursor colour, revision
              v
          pixel stream -> XMAP9 (format) -> CMAP (palette) -> BT445 -> monitor
```

**Everything except REX3 is reached only through REX3.** There is no second
address window: `DCBMODE` (`0x1F0F0238`) carries a 4-bit chip address in bits
`[10:7]`, a 3-bit register select in `[6:4]` and a data width in `[1:0]`, and a
write to `DCBDATA0` (`0x0240`) runs the transfer. That single fact decides the
module structure: `rex3.sv` owns the DCB and fans out to the other four, so
they are children of REX3 rather than peers on the bus.

### REX3 — the rasteriser

Registers at `0x1F0F0000`, 8 KB. Two pages: the drawing registers at
`0x0000`–`0x02FF` and the configuration registers at `0x1300`–`0x1340`.
**Bit 11 (`0x0800`) of the offset is the GO bit**: writing `reg | 0x800`
writes the register *and* starts the drawing command. That is the whole
command interface — there is no command register to kick.

The complete list of drawing operations the PROM console makes, from
`ng1_tp.c`:

| Function | `drawmode0` | What it is |
|---|---|---|
| `Ng1TpSboxfi` | `DRAW BLOCK DOSETUP STOPONX STOPONY` | filled rectangle in `colori` |
| `Ng1TpPnt2i` | `DRAW BLOCK` | one pixel |
| `Ng1TpDrawbitmap` | `DRAW BLOCK STOPONX ENZPATTERN LENGTH32` | one span, stippled from `zpattern` — this is a glyph, one scanline per `GO` |
| `Ng1TpBmove` | `SCR2SCR BLOCK DOSETUP STOPONX STOPONY` + `xymove` | block copy — this is the scroll |
| `getfbdepth` | `DRAW BLOCK COLORHOST DOSETUP`, then `READ BLOCK COLORHOST` | host-to-framebuffer and back, through `hostrw0` |

Five operations. That is the entire engine a booting Indy needs, and four of
them are the same block walker with a different source of colour.

### VC2 — video timing, cursor, DID

32 registers of 16 bits and **an external 32K x 16 SRAM** it interprets. The
SRAM holds three tables; the video timing one is the one that matters first.

**The video timing table is a program, and VC2 is its interpreter.** From
`vc2.pdf` §3.4.1, confirmed against `np_timing.h`:

* A **frame table** is a list of `(line-sequence pointer, line count)` pairs,
  terminated by a count of zero, which restarts the frame.
* A **line** is a list of **state runs**, followed by a pointer to the next
  line in the sequence. A line that points to itself repeats — which is what
  every table in `np_timing.h` actually does.
* A **state run** is one or two 16-bit words:
  * word 1: bit 15 = end of line, bits 14:8 = **duration** in 2-pixel clocks
    (max 127), bit 7 = *state B/C absent*, bits 6:0 = state A
  * word 2 (present when bit 7 of word 1 is clear): bit 15 = end of line,
    bits 14:8 = state B, bit 7 = 1, bits 6:0 = state C
* A state is 21 timing channels in three groups of seven. State C carries
  `VSYNC_ARC_N` (bit 1) and `HSYNC_ARC_N` (bit 2); state A carries
  `DSPLY_EN_RO_N` (bit 2), the display enable.

Decoding `n1280_ltab`'s first line with that rule gives durations
`12+3+57+3+84+127*5+47 = 841` two-pixel units = **1682 pixels**, which is
exactly `107.5 MHz / (60 Hz * 1065 lines)`. The 57-count run is the one with
`HSYNC_ARC_N` low and it is 114 pixels wide, against 112 in the VESA timing for
this mode. **That arithmetic is the check that the field split is right**, and
it is worth redoing rather than trusting, because the obvious reading — state
in the high field, duration in the low — also parses and gives 1258.

So the VC2 in RTL does not know about 1280x1024. It walks the SRAM the PROM
loaded and emits whatever that says, which is the same reason a real one works
on every monitor in `np_timing.h`.

The **DID table** run-length encodes a 5-bit window ID per pixel, which selects
one of XMAP9's 32 mode-table entries. The PROM loads a table that says "entry 0
for the whole scanline" (`did2_linetable[] = { 0x0000, 0x7ff << 5 }`), so DID
can be a constant zero until something wants per-window pixel formats.

### XMAP9 x2 — pixel format

Eight registers and a 32-entry mode table of 24 bits. The mode table entry
selected by the DID says how to read a pixel: `pix_mode` (CI or one of three
RGB packings), `pix_size` (4/8/12/24 bpp), and the colour map MSB that picks
which 256-entry page of CMAP an 8-bit index lands in. The PROM sets all 32
entries to 8-bit CI (`Ng1XmapInit`).

Two chips because Newport runs a two-pixel-wide pipeline (even and odd). They
are written together through DCB address 4 and separately through 5 and 6.

**`XMAP9_REG_REVISION` returning 3 is what makes this board "Indy 24-bit"**
rather than XL8, which returns 1.

### CMAP x2 — the colour map

An 8192-entry palette of 24-bit colour, addressed by an 8-bit index from the
framebuffer plus a 5-bit MSB from the XMAP9 mode table. Also two chips for the
two-pixel pipeline; `cmap1` carries the **monitor ID in the upper nibble of its
revision register**, which is how the PROM decides which timing table to load.

### BT445 — the RAMDAC

Gamma table, cursor colours, pixel read mask, revision. `Ng1DacInit` programs
the pixel clock PLL through it, which in RTL is where the "what clock does the
video output actually run at" question lands.

## The framebuffer

1280 x 1024 pixels of 32 bits — 24 bits of RGB (or an 8-bit colour index in the
low byte) plus 8 auxiliary bits for the overlay, popup and CID planes that the
drawmode1 `planes` field selects between. **5 MB.**

That does not fit on a Cyclone V. A DE10-Nano's on-chip M10K totals about
688 KB and the CPU's two caches are already in it, so the framebuffer is
external memory on hardware whatever else changes.

**So Newport gets its own memory ports**, with the same `req`/`we`/`addr`/
`be`/`rdata`/`ack` contract every other port in this core uses, backed by a
`sim_ram` instance in the harness. That is also what the real machine does:
Newport is a GIO card with private VRAM, not a UMA, and giving it the CPU's
port would put every drawn pixel through the arbiter in `sgi_indy.sv`.

**Two ports, not one, and that is not a shortcut.** The frame buffer is VRAM:
a random port the rasteriser writes and a serial port the display clocks out,
at the same time. Modelling it as one port with an arbiter would be less like
the hardware, not more.

### On hardware that is DDR3

The DE10-Nano's on-chip M10K totals about 688 KB and the two CPU caches are
already in it, so 10 MB of frame buffer is external memory whichever way this
goes. MiSTer's `DDRAM_*` port is **64 bits wide with eight byte enables**, an
`ADDR[28:0]` in 64-bit words, a burst count, and `BUSY`/`DOUT_READY` - which is
the shape the two ports above already have, so nothing in `rtl/newport/` has to
change to land on it.

**`N64_MiSTer/rtl/DDR3Mux.vhd` is the precedent to copy**, and it is a close
one: same board, same CPU, and it already feeds nine masters - including its
video interface, `DDR3MUX_VI` - into the one physical DDRAM port, carving the
address space into regions (RDRAM, a frame buffer area, ROM, savestates) the
way this core will have to for main memory and the frame buffer together.

Two things that follow from DDR3 rather than from VRAM:

* **The display side must burst a scanline into a line buffer**, not fetch a
  64-bit word per pixel. DDR3 latency through the HPS bridge is variable and a
  per-pixel round trip would both miss its deadline and starve the rasteriser.
  A 1304-pixel line buffer is one M10K block; the N64's VI does the same thing
  for the same reason.
* **Main memory wants the same port.** 64 MB of Indy DRAM cannot be on-chip
  either, so the mux has at least three masters from the start: the CPU, the
  rasteriser and the display.

## POST has a graphics test, and it is the ratchet

**Finding the board changes what POST does.** With no Newport the PROM skips
graphics entirely; with one, POST runs `ng1_pon` -> `test_rex3`, and a failure
prints

```
Graphics diagnostic                        *FAILED*

        Check or replace:  Graphics board
```

and then gates the System Maintenance Menu behind a keypress, which looks
exactly like a hang to a harness driving the console with `--type-on`.

`test_rex3` in `stand/arcs/ide/fforward/graphics/NEWPORT/rex3.c` is a register
read/write test: for each of `0xFFFFFFFF`, `0xAAAAAAAA`, `0x55555555` and `0`
it writes a register, issues a `NOP` GO, reads it back and expects the value
masked to **that register's real width**. So the widths are not cosmetic:

| register | width | register | width |
|---|---|---|---|
| `lsmode` | 28 | `bress2` | 26 |
| `alpharef` | 8 | `colorred` | 24 |
| `xstart`/`ystart`/`xend`/`yend` | 20 bits `<< 7` | `coloralpha`/`grn`/`blue` | 20 |
| `xsave` | 16 | `wrmask` | 24 |
| `bresd` | 27 | `topscan` | 10 |
| `bress1` | 17 | `clipmode` | 13 |
| `bresoctinc1` | 27 less `[23:20]` | `brese1` | 16 |
| `bresrndinc2` | 32 less `[23:21]` | | |

and **the four slope registers are sign-magnitude, not two's complement** -
`test_rex3_slopecolor` checks the conversion explicitly. That is a real
property of the part that no amount of reading the register map would have
told you.

The same file's `TIW` cases are the other half of Ng1Probe's identity test:
writing the integer form of a coordinate must show up in the fixed-point one
shifted left by 11.

## The milestones, in dependency order

**N0 — the board is found.** `Ng1Probe` in `ng1_init.c` is the entire
specification, and it is short: configure `GIO64_ARB`, survive `badaddr`, write
`CONFIG`, poll `STATUS` for `GFXBUSY` to clear within 100000 tries, write
`0x12348765` to `xstarti` (`0x0148`) and read `0x43B28000` back from `xstart`
(`0x0100`) — the 16-bit integer field re-presented as fixed point, `<< 11`.
Nothing draws. Done when `hinv` prints `Graphics: Indy 24-bit`, which needs N1
as well because `ng1_install` runs the whole init before it registers the node.

**N1 — the DCB works.** VC2's registers and SRAM, XMAP9 x2, CMAP x2, BT445,
all behind `DCBMODE`. Done when `Ng1RegisterInit` completes: VC2 out of reset,
timing tables loaded, XMAP mode table set to 8-bit CI, gamma set to identity.

**N2 — pixels exist.** The framebuffer port and the five drawing operations
above. Done when the PROM stops printing `Cannot open video() for output` and
the boot banner is in the framebuffer — checked by dumping it, not by looking
at it.

**N3 — video comes out.** VC2's timing generator driving real sync and blank,
the readout path through XMAP9 and CMAP, and the pixel stream out of
`newport.sv`. Done when the GUI shows the banner and `sgiindy.sv` has something
to hand to `VGA_*`.

**N4 — the cursor, the DID table, 24-bit RGB, and the GIO DMA path.** Anything
IRIX needs that the PROM does not.

## What building it found that no reading would have shown

**Finding the board moves the console off the serial port.** ARCS installs the
DisplayController with `ConsoleOut|Output` and the PROM stops printing to the
SCC entirely - the boot banner, POST, the menu and `hinv` are all drawn into
the frame buffer instead. Every serial-console ratchet in `tests/` therefore
passes `--no-gfx`, which is a real machine configuration and not a fiction: it
is the machine every boot log in this repository before now was showing.

**The Display Control Bus is right-aligned, and getting that wrong is almost
invisible.** A byte-wide DCB transfer carries its datum in the LOW byte of
`DCBDATA0` - the driver stores it through `rex->set.dcbdata0.bybyte.b3`, and a
halfword through `.byword` at the same end. Taking the byte from the top
instead sends whatever was left in the register, and the first thing that
breaks is VC2's index register: every indexed access lands on register 0.

The symptom was not a blank screen. It was `Ng1RegisterInit` reading
`DC_CONTROL` back as zero, ORing its bits into that, and writing the video
timing enable straight back **off** a few thousand clocks after turning it on -
so the machine produced about eighty scan lines per boot instead of tens of
thousands, and the picture that did come out looked like a timing bug.

`verilator/tb_vc2.cpp` exists because of that: it drives np_vc2's DCB port
directly with a table of a known geometry, so the timing generator can be
ruled in or out in one second instead of ninety.

**A duration field of D lasts exactly D two-pixel units, and the tables prove
it.** The obvious alternative - D+1, the way a hardware down-counter usually
reads - also produces a picture, three per cent too wide. What settles it is
that every line of a raster has to be the same length: decode all nineteen
tables in `np_timing.h` and under the D rule each one has a *single* line
total (n1280's is 841 two-pixel units = 1682 pixels = 107.5 MHz / (60 Hz *
1065 lines), exactly), while under D+1 each table's lines come out at four or
five different lengths. Nineteen independent confirmations, and no table
anywhere has a duration of zero, so nothing needs a zero-length state.

**The monitor type is the resolution, and reporting zero is not a neutral
default.** CMAP 1's revision register carries the monitor type in its upper
nibble and `Ng1DacInit` switches on it to pick a timing table. Zero means
"unknown", and on a Guinness the unknown arm reads the `monitor` environment
variable and, finding nothing in a blank NVRAM, "defaults to low-res" -
1024x768. This model reported zero, so the PROM loaded `n1024_r3` and the core
faithfully produced a 1024x768 raster. Combined with the D+1 error above that
came out as 1082 x 813 against an expected 1304 x 1065, which reads as "the
timing generator is about a fifth short in both directions" - a plausible and
completely wrong diagnosis that two sessions worked from. CMAP 1 now reports
10, the 16-inch Mitsubishi, which is what `~/repos/iris` reports and what maps
to n1280 at 60 Hz.

**Neither of those was visible in a boot log, and neither was the rasteriser's
three bugs.** `DRAWMODE1`'s logic op is at bits **[31:28]**, not [15:12] -
reading it from the low position picks up COMPARE, which every drawmode1 the
PROM writes sets to 7 to disable it, and 7 is OR. Every filled box was OR-ed
onto whatever was underneath, so the screen came out as bands of nearly the
right grey that drifted by a bit or two across a span: it read as a smearing
rasteriser rather than as a wrong raster op, because OR with the right colour
is mostly the right colour. `RGBMODE` moved with it, to bit 15.

**REX3 has a graphics FIFO and this one does not**, and `Ng1TpDrawbitmap`
depends on it: sixteen `rex3SetAndGo(zpattern, ...)` in a row with one
`REX3WAIT` before them and none in between. Without a queue the second one
overwrote ZPATTERN in the middle of the first one's span, and `go_pending` -
one bit - dropped the commands it could not hold. Thirteen hundred of ten
thousand GOs a boot were being lost. `np_rex3.sv` now holds the
acknowledgement of a register write while a command is running, which is what
the part does when its FIFO fills.

**`USER_STATUS` at 0x133C is an alias of `STATUS`, not a register**, and this
is the one that made the other two possible. `REX3WAIT` - which every drawing
routine in `ng1_tp.c` calls before it touches a register - polls 0x133C.
Answering it from a writable register that read back zero told the PROM the
engine was never busy, so it never waited: register writes landed in the
middle of running commands and a full-screen clear was overwritten while it
was still walking. IRIS answers both offsets from the same word and clears
VRINT only on 0x1338.

`tests/run-rex3.sh` exists because of those three. It boots with
`np_rex3.sv`'s `REX3_DEBUG` trace on - one line per accepted GO, with every
register the command depends on - and `tests/rex3_replay.py` replays the ten
thousand commands into a model frame buffer and compares it with the one the
run dumped. All 1,310,720 pixels, no exceptions. Both bugs above fail it, and
the second one fails it by 1102 pixels, which is the kind of number no
eyeball finds on a 1280x1024 screen.

## What this does not cover

The PROM's graphics **diagnostics** (`stand/arcs/ide/fforward/graphics/NEWPORT/`)
test VRAM patterns, the palette, and the SRAM directly. They are not on the boot
path — POST does not run them — but they are the best test suite that exists for
this hardware and `vram3.c` in particular is a ready-made memory test. Worth
returning to once N2 is real.

Nothing here touches the GIO64 DMA engine Newport uses for `NG1_PIXELDMA`. The
PROM never uses it; IRIX's `gfx` driver does.
