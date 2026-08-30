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

The main memory region is sized for the largest the OSD offers rather than for
the selection. A map that moved with the menu would put the frame buffer at a
different address for every entry, which the guest never sees and every
debugging session would.

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

### 0. The frame buffer stores eight bytes a pixel to display one of them

**This is now the single most valuable change left in this file's scope, and
hardware is what promoted it.** The store is one 64-bit word per pixel - 24
bits of drawing planes, 24 of auxiliary, on a 2048-pixel stride - so a visible
line is 1344 words. At one core clock per pixel that is **0.80 words a clock
against a DDR3 port whose absolute peak is 1.00**, before the CPU or the
rasteriser ask for anything. A DE10-Nano delivered 0.52 and missed the first
710 pixels of every line, for ever; `PIX_DIV` is 2 again because of it, at
about 14 Hz.

**The display never reads seven of those eight bytes.** `newport.sv` takes
`pix_word[7:0]` in index mode and `[23:0]` in packed RGB, and it never touches
the auxiliary planes at all - this core builds no overlay, no popup planes and
no cursor.

**IRIS stores them as two separate arrays, which is the shape to copy.**
`rex3.rs` has `fb_rgb: Box<[u32]>` and `fb_aux: Box<[u32]>`, both
2048x1024 and both indexed `y * 2048 + x`, and `compositor.rs` reads `fb_aux`
only for the popup bits (`raw_aux >> 2`) and the overlay byte. Two regions of
four bytes a pixel is therefore not a compression trick, it is what the
reference implementation does.

The consequences are all good:

| | bytes fetched per pixel | words/clock at `PIX_DIV = 1` |
|---|---|---|
| now | 8 | 0.80 |
| split planes, display reads RGB only | 4 | **0.39** |

That is `PIX_DIV = 1` and the 27 Hz back, with room to spare for the other two
masters. One 64-bit read then carries **two adjacent pixels**, so REX3's
per-pixel write picks a half with the byte enables `ddr3_mux.sv` already
honours, and `fb_linecache.sv` fetches 660 words a line instead of 1344.

What it costs: `np_rex3.sv`'s `fb_byte_addr` becomes a per-plane address,
`ddr3_mux.sv` grows a region, and every test that knows the frame buffer's
shape - `tests/rex3_replay.py`, `--fbdump` - has to follow. It is a real
change and it is the right one.

### 1. The refresh is about 14 Hz, and the fix is above, not a faster clock

**Corrected by hardware: the pixel rate is halved again, and the refresh with
it.** The raster is exact. `PIX_DIV` went to 1 for a free doubling of the frame
rate and the doubling was not free - see section 0 - so it is 2, and the frame
comes out at about 14 Hz. **A faster core clock does not fix this and neither
does a second clock domain**: both make the display ask for MORE memory per
second, and memory is what it has run out of. Fetching half as much per pixel
is the fix.

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

## Memory size

**This is a single RAM configuration.** The OSD offers 32, 48 and 64 MB,
default 64, and 64 is both the default and the ceiling because that is what one
MiSTer SDRAM module holds.

Every one of those is a size the MC can actually express, which is not the same
as any number of megabytes. A bank is four SIMMs, and the parts that do not
need the BNK bit give banks of 64, 16 and 4 MB, so an installable size is a sum
of those across at most four banks: 32 is 16+16, 48 is 16+16+16, 64 is one
bank. `rtl/sgi/sgi_memmap.sv` has the derivation. Asking for 32 as one 32 MB
bank is what made `--ram-mb 32` fail once — the PROM probed a bank that could
not answer and its own diagnostic said so. All three boot in simulation and the
PROM reports each one back:

```
  32 MB -> Memory size: 32 Mbytes
  48 MB -> Memory size: 48 Mbytes
  64 MB -> Memory size: 64 Mbytes
```

`sgi_memmap.sv` will build 96 (64+16+16) and 128 (64+64) as well, and they were
booted and verified before being taken back out. **They are not offered**,
because a size the board cannot be is not a choice — it is a way to get "No
usable memory found" out of a machine that looked fine in the menu. They come
back if main memory ever moves onto two SDRAM chips.

Changing the size resets the machine, because the PROM sizes memory exactly
once: `szmem` probes the banks at boot and writes the result into the MC's
config registers, and nothing re-reads it.

## Dual SDRAM: not supported, and what it would have been worth

Recorded because the question was asked and answered rather than skipped.

Today `SDRAM_*` is tri-stated: main memory, the frame buffer and the PROM are
all in DDR3, so a dual-SDRAM daughterboard gives exactly what a bare DE10-Nano
gives. Two things specific to this machine would have made it worth something.

**The CPU is latency-bound in the most literal way.** `hinv` reports "16 Mhz",
and that is not a clock - it is a measurement of how long a fixed loop of
uncached instructions takes, about nine cycles per bus round trip. DDR3 through
the f2h bridge is worse than SDRAM and, more to the point, variable.

**The display and the CPU are the two masters least suited to sharing a bus.**
One is a long sequential stream of 10.8 MB a frame; the other is random and
latency-critical. They are behind the same arbiter.

Of the three ways to use two chips - interleaving them as one 32-bit memory,
splitting by address, or splitting by master - the last is the one that fits
this core's shape: main memory on one chip and the frame buffer on the other,
so those two masters stop contending at all. At 64 MB and below each fits one
chip, which is exactly why the size list stops there.

It needs an SDRAM controller before it needs a second chip, and main memory on
a *single* SDRAM is the larger win and is independent of the dual question.
`N64_MiSTer/rtl/sdram.sv` is the precedent, on the same board with the same CPU
behind it. Neither is built.

## Using it

### Installing it

```
/media/fat/_Computer/SGIIndy_<date>.rbf     the core
/media/fat/games/SGIIndy/boot.rom           the PROM, loaded automatically
```

**`boot.rom` is a framework feature, not a core one.** MiSTer's Main scans the
core's home directory at startup and, finding a file with that exact name,
uploads it over `ioctl` with **index 0** — no CONF_STR entry needed, the name
and the `.rom` extension both hardcoded on the HPS side. The core's decode is
`ioctl_index[5:0] == 0`, which is also what the `FS0` menu entry produces, so
one path serves both and the automatic load needed no RTL at all. (The
numbered form `boot0.rom` … `boot3.rom` exists too and passes `i << 6`; only
`boot0`/`boot.rom` lands on index 0, which is the one this core answers.)

`boot.rom` in the repository root is `ip24prom.070-9101-011.bin` — PROM Monitor
5.3 Rev B10, the image every test here boots — copied under the name the
framework looks for. `roms/IP24_Indy/` keeps both that and the 5.0 image under
their real names.

**The framework releases reset *before* it sends `boot.rom`.** It clears
`status[0]` and only then starts the transfer, so there is a window in which
the CPU fetches from a PROM region holding whatever DDR3 powered up with. The
core rescues itself: `prom_download` re-asserts reset the moment the transfer
begins and holds it for 65,535 clocks past the end. Nothing done in that window
survives, and it cannot have corrupted the image, because the PROM region is
read-only to everything except the download master.

### The OSD

* **Load PROM** — an SGI firmware image, for loading one by hand or replacing
  the automatic one. It is not in the bitstream and it is not going to be; the
  core holds itself in reset until the download finishes.
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
* **Memory: 64 / 32 / 48 MB** — see above. Changing it resets the machine.

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
