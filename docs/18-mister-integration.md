# MiSTer integration — the top level, and what it cannot do yet

`sgiindy.sv` was the stock MiSTer template with a noise generator in it until
now, and every claim this project makes about the machine comes from Verilator.
This is the wiring that makes a hardware build possible, and — more usefully —
the list of things that will be wrong on the first one.

**None of this has been through Quartus.** There is no Quartus on the machine
it was written on. What is checked is what Verilator can check: `ddr3_mux.sv`
has a unit test with a deliberately unhelpful bridge model, and the top level's
instantiations were linted against the real port lists, which catches a wrong
name or a wrong width and nothing else. Treat the first build as bring-up.

## The map

```
   CLK_50M ──► pll ──► clk_sys (50 MHz) ──┬─► sgi_indy  ──► VGA_*
                                          ├─► ddr3_mux  ──► DDRAM_*
                                          ├─► hps_io    ──► SD, OSD, PS/2
                                          └─► NCO ──► sclk (3.6864 MHz)
```

### Memory: all of it is DDR3

64 MB of Indy memory and 16 MB of Newport frame buffer, against about 688 KB of
M10K on a Cyclone V, most of which the CPU's two primary caches already have.
There was never a choice. MiSTer gives a core a 256 MB window of the HPS's DDR3
through `DDRAM_*`, selected by `ADDR[28:25] = 4'b0011`, and
`rtl/mister/ddr3_mux.sv` carves it:

| region | byte offset | size |
|---|---|---|
| main memory | `0x0000_0000` | 64 MB |
| Newport frame buffer | `0x0400_0000` | 16 MB |
| PROM image | `0x0500_0000` | 512 KB |

**`DDRAM_ADDR` counts 64-bit words, not bytes.** Getting that wrong is an
eight-times address error, which does not present as an address error: it
presents as memory that reads back something written somewhere else.

Three things the unit tests found, all of which would have been miserable to
find on hardware:

* **The region bases truncated.** They were declared as `logic [24:0]` and
  written as byte offsets, so `25'h400_0000` did not fit, became zero, and the
  frame buffer aliased the whole of main memory. They are 32-bit byte offsets
  now with the shift in one place.
* **Fixed priority starved the rasteriser.** With four masters asking, REX3 —
  last in the list — got 62 transactions against the display's 3707 and waited
  5370 cycles for one of them. The display keeps absolute priority because it
  is the only master with a deadline; everything else rotates.
* **The line cache filled the buffer it was reading.** The buffer-select was
  inverted and invalidated the *other* buffer as well, so a fill could land on
  top of the line being displayed. It showed up two ways at once — runs of
  pixels from the wrong line, and a tenth of every frame missing — which is
  what a cache that is simultaneously reading and overwriting one buffer looks
  like.

A third mistake was in the *test* rather than the design, twice, and it is
worth naming because it looks like a passing test: both bridge models first
decided whether a request had been accepted **after** the clock edge, by which
time the module had already seen the signal and moved on. Everything a model
presents has to be settled before the edge. The first time it made a working
mux look completely broken; the second it made a working cache report zero
pixels checked and zero misses, which reads like success.

## What will be wrong on the first build

### 1. The refresh is about 28 Hz, and that is the only thing left wrong

**Fixed since this was first written: the raster is now exact, and the pixel
rate has doubled.** What is left is a refresh rate.

VC2 walks its timing table in units of two pixel clocks and derives those by
dividing `clk_sys`. The table the PROM loads was written for a **107.5 MHz**
pixel clock; at 50 MHz with `PIX_DIV = 1` the frame comes out at about 28 Hz
rather than 60. That is judder through the scaler on a machine whose screen is
mostly static text — a limitation, not a defect.

**A faster core does not fix it.** `syn/README.md` has the CPU on its own
closing at 64.04 MHz and the whole core will be lower; 107.5 MHz is not
reachable and does not need to be, because on real hardware the pixel clock is
not the CPU clock either — the BT445 has its own PLL and `Ng1DacInit` programs
it. Sixty hertz wants a **second clock domain**: a PLL output near the rate the
loaded table implies, `np_vc2`'s generator on it, and crossings for the Display
Control Bus writes going in and the pixel stream coming out. That is the single
most valuable thing left in this file's scope, and it is now the *only* thing.

Two changes got it from a sixth of 60 Hz to a half of it:

* **`PIX_DIV` is 1, not 2.** It was 2 only so the frame buffer read port was
  not asked for a word every clock, which stopped being a constraint the moment
  a scanline of block RAM went in front of it.
* **Pixel time stops while the generator is fetching.** Walking the table costs
  clocks that belong to no state run — a word per run, two for a run carrying
  state B and C, and the next-line pointer at the end of every line — and
  letting the pixel clock run through them puts them in the picture. At
  `PIX_DIV = 2` that was about two pixels a line and the display enable still
  measured the table's 1318 exactly; at `PIX_DIV = 1` it became five and
  measured **1323**, which is how the change was caught. Holding the divider
  through a fetch costs a fraction of a percent of frame time and buys a raster
  that is the table's at any divider. A real VC2 hides the same clocks in a
  sixteen-deep state FIFO.

`tests/run-newport.sh` asserts the exact number, so this cannot quietly come
undone.

### 2. The display port has a scanline cache now

`newport.sv` issues one frame buffer read per pixel and latches whatever comes
back, without waiting — there is no handshake on that path and there should not
be, because on a real board the display reads a VRAM *serial* port, which
cannot stall. Against the simulator's one-cycle memory that is exactly right.
Against DDR3 the pixel would be stale by however many cycles the read took, and
the number moves with memory load: a horizontal smear.

`rtl/mister/fb_linecache.sv` fixes it, and it is in `rtl/mister/` rather than
`rtl/newport/` on purpose — nothing about the graphics board changes, so every
test that checks the picture still checks the same core. Two line buffers, one
being read while the next is filled by burst from the mux; the display's
pattern is fully determined, so the line wanted next is always the current one
plus one, and `vs` restarts the prefetcher at line zero where a frame wraps.

A miss serves black rather than stalling, because stalling is not on the menu.
`verilator/tb_linecache.cpp` drives it with the real pattern — 1318 of 1680
pixels, 1024 of 1065 lines, blanking included — against a memory that accepts a
burst late and returns it in gaps: **4.0 million pixels, all correct, and zero
misses after the first frame.**

It also needed the mux's display port to become a **burst** port, and that is
not an optimisation. A line is 1318 words with one line time to arrive;
single-word transactions are latency-bound at roughly one word per round trip,
which is an order of magnitude short. Without bursts the display cannot be fed
at all, whatever its priority.

### 3. Nothing persists

The NVRAM is volatile, so the PROM rebuilds its environment on every boot and
prints `NVRAM checksum is incorrect: reinitializing.` every time.
`docs/17-nvram-persistence.md` is the plan, including the constraint that
decides its shape: the NVRAM's two banks have exactly one reader and one writer
each and that is what makes them M10Ks rather than 65,536 flip-flops.

### 4. The PROM's byte order is the one guess in the download path

The image arrives through `ioctl` two bytes at a time and is assembled into
DDR3 doublewords. This core's convention is that `data[63-8*i -: 8]` is the
byte at `addr + i`, so the *first* byte of the file belongs in the *most*
significant lane; `hps_io`'s WIDE mode presents the earlier byte in the low
half of `ioctl_dout`, so each halfword is swapped on the way in.

That is reasoned, not measured. **If the machine executes garbage from the
first fetch, invert that swap before looking anywhere else.**

### 5. No audio, no Ethernet, no cursor

`AUDIO_*` is tied off: HAL2 answers its revision register and nothing else, so
this core reports an audio processor rather than having one. The SEEQ 8003 is
still an unclaimed address. VC2's cursor planes are not built, and neither is
the mouse pointer that would use them — see `docs/12-chipset.md`.

## Using it

The OSD carries:

* **Load PROM** — an SGI firmware image. It is not in the bitstream, and it is
  not going to be; the core holds itself in reset until the download finishes.
* **SCSI ID1 / ID2 / ID6 CD** — three virtual drives, because `sgi_scsi.sv`'s
  `TARGET_EN` builds exactly those three. ID 6 elaborates as a CD-ROM, which is
  an elaboration-time choice and not a mount-time one: `CDROM` changes INQUIRY,
  the logical block size, READ CAPACITY and the MODE SENSE pages, so a drive is
  a different device from a disk rather than a disk with a different file in it.
* **Graphics board: Fitted / None.** Not a quality setting. **Fitting the board
  moves the console off the serial port** — ARCS installs a DisplayController
  with `ConsoleOut|Output` and the PROM stops printing to the SCC entirely — so
  "None" is how you get a terminal, and it is a real machine configuration.
* **Primary caches: On / Off**, for bisecting a hardware fault onto one of them
  without rebuilding.

The SCC's channel B is tty1, the SGI console, and it goes to the board's UART
pins. The keyboard and mouse come from `hps_io` as `ps2_key` and `ps2_mouse`
and go to the 8042 in IOC2, which POST tests and passes and which the PROM
reads for console input once graphics are fitted.

## The clocks

One PLL output, 50 MHz, and that number is a measurement rather than a guess:
`syn/README.md` has the CPU alone closing at 64.04 MHz on a `5CSEBA6U23I7`, the
whole core is the CPU plus the chipset plus Newport, and 50 is the round number
below it. Raising it means running the fit and reading
`output_files/sgiindy_syn.sta.rpt`, not editing `rtl/pll.v` hopefully.

`rtl/pll/` was already a MegaWizard-generated PLL from the template, at
20 MHz, and the change to it is one line: `output_clock_frequency0`.
`altera_pll` takes its output frequencies as strings and Quartus computes the
counters at elaboration, so that is the whole of it — but the generated files
carry IP metadata that the catalogue and a future regeneration both want, so
edit the frequency rather than replacing them. The wizard's own
`gui_output_clock_frequency0` retrieval-info comment in `rtl/pll.v` is kept in
step for the same reason.

`sys/pll_q17.qip` expects `rtl/pll.qip` to exist and pulls it in itself, so
`files.qip` must **not** name it again.

`sclk`, the SCC's 3.6864 MHz serial clock, is a numerically controlled
oscillator on `clk_sys` — 50 over 3.6864 is 13.56, so there is no integer
divide, and a UART does not care about the fraction of a percent an NCO leaves.

## A trap paid for while writing this

**A line comment that begins with the word "Verilator" is a pragma.** The
first version of the top level had `// Verilator harness; ...` as the second
line of a comment, and every lint of the file failed with
`Unknown verilator comment: 'harness; on hardware nothing reads them.'`. It
costs a confusing five minutes the first time and nothing after that.
