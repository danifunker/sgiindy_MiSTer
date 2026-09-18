# MiSTer integration

`sgiindy.sv` is the MiSTer top level — the framework's `emu` module. It puts
the machine (`rtl/sgi/sgi_indy.sv`) on a DE10-Nano: one PLL, the HPS's DDR3
for every byte the machine stores, `hps_io` for the OSD, the PROM download,
the SCSI images, the keyboard, the mouse and the clock, the SCC on the board's
UART, and VC2's raster to the scaler. This is how each of those is wired, and
why.

The current release is `releases/SGIIndy_20260918.rbf` (build 44) with
`releases/boot.rom`. It was built with Quartus Prime Lite 17.0.2 at fitter
seed 2, the seed `sgiindy.qsf` keeps: 35,886 of 41,910 ALMs (86 %), 485 of 553
M10K blocks, 59 of 112 DSP blocks, and timing met in every check — worst setup
slack +0.979 ns on the 50 MHz core clock and +0.714 ns on the HDMI pixel
clock. `scripts/build.sh` writes that report into `reports/` after every
compile; [deploy-and-debug.md](deploy-and-debug.md#building) has the flow.

## The map

```
 CLK_50M ─► pll ─► clk_sys, 50 MHz — every clock in the core but one
                     │
 hps_io ◄───────────►├─ OSD status, ioctl downloads (PROM, MAC), SCSI slots,
                     │  PS/2 keyboard and mouse, the MiSTer's RTC
                     │
 sgi_indy ◄─────────►├─ the machine: CPU, MC, HPC3, IOC2, SCSI, Newport
   │ ram, prom, fbw ───────────────────────────────────┐
   │ fbr, fba ─► fb_linecache ×2 ─► fb_fetch_arb ──────┤
   │                                                   ▼
   │                                    ddr3_mux ─► DDRAM_* (the HPS's DDR3)
   │ vid_* ─► CLK_VIDEO, CE_PIXEL, VGA_* (the MiSTer scaler)
   │ txdb, rxdb ─► UART_TXD, UART_RXD (the HPS UART)
   │
 NCO on clk_sys ─► sclk, 3.6864 MHz ─► the SCC's baud clock
```

## Memory: everything is in DDR3

The machine has up to 64 MB of main memory and Newport 16 MB of frame buffer,
against about 690 KB of block RAM on the Cyclone V (5,662,720 bits), two
thirds of which build 44 already uses for caches, line buffers and register
files. There is no choice about where memory lives.
MiSTer gives a core a 256 MB window of the HPS's DDR3 through `DDRAM_*`,
selected by `DDRAM_ADDR[28:25] = 4'b0011` — ARM physical `0x30000000` up — and
`rtl/mister/ddr3_mux.sv` carves it:

| region | window offset | ARM physical | size |
|---|---|---|---|
| main memory (guest physical `0x08000000` up) | `0x0000_0000` | `0x30000000` | 64 MB |
| frame buffer, drawing planes | `0x0400_0000` | `0x34000000` | 8 MB |
| frame buffer, auxiliary planes | `0x0480_0000` | `0x34800000` | 8 MB |
| PROM image (guest physical `0x1FC00000`) | `0x0500_0000` | `0x35000000` | 512 KB |
| debug beacon (see below) | `0x0580_0000` | `0x35800000` | 43 × 8 bytes |

The main memory region is sized for the largest size the OSD offers rather
than for the selection. A map that moved with the menu would put the frame
buffer at a different address for every entry, which the guest never sees and
every debugging session would.

**`DDRAM_ADDR` counts 64-bit words, not bytes.** Getting that wrong is an
eight-times address error, which does not present as an address error: it
presents as memory that reads back something written somewhere else. The
region bases are 32-bit byte offsets for the same reason, with the shift in
one function (`wordaddr`); the first version declared them 25 bits wide,
`25'h400_0000` truncated to zero, and the frame buffer aliased the whole of
main memory.

**The byte order.** The core's convention is that `data[63-8*i -: 8]` is the
byte at `addr + i` — big-endian within the doubleword, because the machine is.
The ARM reads the same doubleword little-endian, so a hex dump of guest memory
from the HPS comes back reversed in groups of eight. `guestmem.py` flips it
back; `ddr3_peek.py` shows it as the ARM sees it.

**No SDRAM.** The `SDRAM_*` pins are tri-stated, so no SDRAM module is needed
and a dual-SDRAM board gives exactly what a bare DE10-Nano gives. The one use a
second memory would have here — the frame buffer on one chip and main memory
on another, so that the display and the CPU stop contending for one port —
needs an SDRAM controller this core does not have.

### `ddr3_mux`: six masters, one port

| master | port | shape | priority |
|---|---|---|---|
| the display | `fbr_*` | burst reads of up to 255 words, served to the bridge as sub-bursts | second |
| the PROM download | `dl_*` | single-word writes, only while the core is held in reset | rotates |
| main memory | `ram_*` | the CPU and the DMA engines through `ram_arb`: reads of 1–4 words, single-word writes, four-word line writes | first |
| the PROM | `prom_*` | single-word reads | rotates |
| the rasteriser | `fbw_*` | single-word reads and writes with byte enables | rotates |
| the debug beacon | `bcn_*` | write-only pulses, never acknowledged | only when nobody else is asking |

**Pipelined, so priority decides order and not who waits for whom.** Every
master has at most one transaction outstanding — the display at most
`FBR_AHEAD` sub-bursts — but the bridge takes a new command while earlier reads
are still being answered, the way the scaler's own Avalon master uses it. The
bridge answers reads in the order it took them, and an eight-deep queue of
{master, words} for every read taken keeps that order, so each `DOUT_READY`
word goes to the master it belongs to. Main memory goes first because the CPU
stalls its whole pipeline on each of its transactions and never has more than
one; the display is second because it is the only master with a deadline; the
download, the PROM and the rasteriser rotate; the beacon is taken only when
nothing else is pending, so observing the machine cannot cost it a clock.
Because no master can have two transactions out, a fixed order cannot starve
anybody here — which it did when the mux held one transaction at a time: 62
rasteriser transactions against the display's 3,707 in `tb_ddr3` under fixed
priority, before the rotation.

**The display's bursts go to the bridge four words at a time, two
outstanding** (`FBR_SUB = 4`, `FBR_AHEAD = 2`). A CPU fill taken while the
display has sub-bursts outstanding waits for all of their words first; at 16
words a sub-burst that was up to 32 of them, and a build that used 16 spent 24
clocks per line fill on the bus against 8 in the simulator. At 4 it waits for
at most 8 words, and the display's stream stays continuous because the next
sub-burst's latency runs while the previous one's words arrive.
[r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md) §11 has
the measurement.

**The CPU's traffic is shaped for the bridge.** A cache line fill is one
read of up to four words, acknowledged word by word with `ram_last` on the
final one — a DDR3 round trip is paid once per line, not once per word. A
dirty data line is written as one transaction of four single-word writes
presented back to back, so no other master's command falls between them. And a
main-memory request goes in front of the bridge in the clock it arrives rather
than a clock later out of the latch.
[cache-fill-latency.md](../design/cache-fill-latency.md) accounts for a fill's
clocks.

**A held request is not a new request, and telling them apart is the whole
difficulty of this file.** Two shapes of master share it. The CPU *pulses*:
one cycle, gone, catch it or lose it. REX3 *holds*: `fb_req` is combinational
from its state machine, so in the cycle it is acknowledged it is still
presenting the request that acknowledgement belongs to, and it goes from a
destination read straight into the write without the line ever dropping. Read
as a new request, that held line takes the transaction twice; REX3 counts
acknowledgements to tell its reads from its writes, so it ends up permanently
one behind and latches the shared read register while it holds another
master's data. On hardware that was a frame buffer written entirely with the
CPU's instruction fetches. So a request is new when its line has just risen,
or when what it presents has changed since the transaction taken from it —
and the second test applies only in the master's own acknowledgement cycle,
because a screen-to-screen copy presents two reads of the same address with
the line held between them.

`make -C verilator ddr3test` runs `verilator/tb_ddr3.cpp` against a bridge
model that is deliberately unhelpful — random `BUSY`, random read latency,
garbage on `DOUT` except on the ready cycle — and checks that every read
returns the last value written, every request is acknowledged exactly once,
the regions do not overlap, the display is not starved, and REX3's held shape
is taken once. `ddr3test_sub` is the same bench with 3-word sub-bursts, the
odd size.

### `ram_arb`: the CPU and the DMA engines on main memory's port

Main memory has one port on the mux and two masters behind it: the CPU, and
the DMA engines — the HPC3's SCSI channel and the MC's GIO64 engine, muxed
into one first. `rtl/sgi/ram_arb.sv` is that arbiter, and it is the only one
in the core. The CPU pulses: `rtl/cpu/r4300_bus.sv` raises `bus_req` for one
cycle and then waits, holding its address, data, byte enables and burst length
but not its request. The DMA engines hold theirs until they are acknowledged.

The arbiter gates both on the same thing — one transaction on the port at a
time — and remembers a CPU pulse that arrives during a DMA transaction in
`cpu_wait`, issuing it when the port is free, because stalling a pulse drops
it. `dma_granted` tells `sgi_indy.sv` which DMA engine a transaction belongs
to, so that one engine's acknowledgements cannot land on the other.

It is its own file because the version that lived inside `sgi_indy.sv` could
not be tested, and it was wrong: it gated the DMA on a transaction in flight
but not the CPU, so a CPU access during a DMA round trip rewrote the owner of
the transaction in flight. On the board that was three faults at once — the
CPU taking the DMA's data as its own (the PROM panicking on pointers that
appear nowhere in its image), the DMA never acknowledged (POST failing the
disk while the CD-ROM beside it passed), and the CPU's own access silently
dropped. **None of it was visible in simulation, and the reason is worth
keeping:** the window is exactly as wide as memory is slow, and
`verilator/sim_ram.v` answers in one cycle. `make -C verilator ramarbtest`
drives both masters in their real shapes against a port modelled the way the
mux behaves, with the latency set by `RAMARB_LAT`; against the old logic it
misrouted acknowledgements at every latency above zero, and at DDR3-like
latencies the DMA engine completed nothing at all.

## The display path

**Newport's display side does not wait.** `newport.sv` has two serial ports —
`fbr_*` for the drawing planes, `fba_*` for the auxiliary planes — and reads
each once per pixel inside the display window, taking the answer the clock
after the request without a handshake. On a real board this is a VRAM serial
port, which cannot stall; against DDR3's long and variable latency the pixel
would belong to a read issued some unknown number of cycles earlier. So each
port is answered out of block RAM by an `rtl/mister/fb_linecache.sv`, which
lives in `rtl/mister/` rather than `rtl/newport/` on purpose: nothing about the
graphics board changes, so every test of the picture still tests the same
Newport.

**`fb_linecache`: a ring of four line buffers.** The display's access pattern
is fully determined — VC2 walks each visible line left to right and the lines
in order — so the fill fetches line after line into a ring of four M10K
buffers of 672 words each, in bursts of 128 words, throttled to stay fewer
than four lines ahead of the line being displayed (which is what stops it
overwriting a buffer still in use). The rising edge of VC2's vertical sync
restarts the ring at line 0, with the whole vertical blanking interval to get
ahead in. A miss serves black, because nothing can stall; with **Video debug:
Raw index** it serves index `0x80` instead, so a starved display shows as
grey rather than as a frame buffer that really is black. Four buffers are
margin against the other masters, not a cure for a rate deficit: when the
display was asking for more than the bridge could deliver, going from two
buffers to eight moved the miss rate from 98.8 % to 97 %.

**The auxiliary instance skips empty lines** (`TRACK_ZERO`). It keeps one flag
per frame buffer line meaning "may hold something the display can see" — the
overlay byte and the popup bits, `ZERO_MASK`. Flags reset clear. The
rasteriser sets a line's flag whenever it writes such a value into it
(`aux_mark`); the fill clears it when a whole fetched line comes back with
nothing under the mask and no mark landed while the fetch was in flight. A line
whose flag is clear is published as zeros without a fetch, so on a desktop the
auxiliary stream costs almost nothing: measured on the board, 1,024 of 1,024
lines skipped a frame at the login chooser and 706 with the toolchest's System
menu posted ([scsi-fit-and-framebuffer-layout.md](../design/scsi-fit-and-framebuffer-layout.md)
§5).

**`fb_fetch_arb` puts the two caches on the mux's one burst port**, one burst
in flight, the drawing planes first when both ask. It latches its choice the
cycle it presents a request and keeps it until the mux takes it, because the
mux latches the address and burst count when it first sees the request and
issues them later; an arbiter that re-chose in between handed the burst to the
wrong cache and stalled both.

**Four bytes a pixel is what makes the display fit on the port.** The
frame buffer is two plane sets of a 32-bit slot per pixel on a 2048-pixel
stride, two pixels to a 64-bit word with the even pixel in the low half, and
the byte enables pick the half on a write:

| region | slot |
|---|---|
| drawing planes, `0x34000000` | `{4'b0, cid[3:0], rgb[23:0]}` — the spare nibble is a copy of the window ID, so a window-ID-clipped draw costs one read and one write per pixel |
| auxiliary planes, `0x34800000` | `{8'b0, aux[23:0]}` — overlay `[23:8]`, popup `[7:6]`/`[3:2]`, window ID `[5:4]`/`[1:0]`, two buffers of each |

As the ARM sees it, the colour index of pixel (x, y) is the byte at
`0x34000000 + (y × 2048 + x) × 4`. The drawing stream is then 672 words a
line — about 0.4 words a clock at one pixel per clock — against a port whose
absolute peak is one 64-bit word per clock at 50 MHz. The layout before it
stored eight bytes a pixel and needed 0.80; the board delivered 0.52 and missed
the first 710 pixels of every line, and no number of buffers could have fixed
that. IRIS keeps its frame buffer as the same two arrays.

`make -C verilator linecachetest` drives the auxiliary-flag build of the cache
with the display's real pattern against a memory that accepts bursts late and
returns them with gaps; `make -C verilator fetcharbtest` runs both caches and
the arbiter against a bridge that latches first and issues later, like the
mux. The whole-machine simulator never runs any of this — `verilator/sim_top.sv`
serves both display ports from one-cycle `sim_ram` models — so these two
benches and the board are the only places the fetch path is exercised.

## Video out

`CLK_VIDEO` is `clk_sys`, `CE_PIXEL` is Newport's pixel enable, and
`VGA_DE/HS/VS/R/G/B` come straight from `newport.sv`. There is no scandoubler:
the raster is already progressive and larger than the scaler needs, and the
MiSTer scaler converts it to the HDMI mode.

**VC2 runs the PROM's own timing table.** CMAP 1's revision register reports
monitor type 10, so the PROM loads `np_timing.h`'s 1280×1024 table for a
revision-3 board, and `np_vc2.sv` interprets it: 1,682 pixels by 1,065 lines,
1,024 of them visible, durations counted in two-pixel units. The table was
written for a 107.5 MHz pixel clock and 60 Hz; here a pixel is one `clk_sys`
clock (`PIX_DIV = 1`), so the frame comes out at 50 MHz / (1,682 × 1,065) =
27.9 Hz, which is also what the beacon measured on the board. The timing
generator holds its pixel enable while it fetches table words, the clocks a
real VC2 hides in a sixteen-deep state FIFO, so the raster is exactly the
table's; it costs a fraction of a percent of frame time.

**The display enable is VC2's visible window cropped to 1,280 columns.** The
window (`VIS_LN`) on IRIX's table is 1,296 pixels wide, because IRIX biases the
whole screen 8 pixels right (`bt445_bug_xbias`); the desktop occupies frame
buffer columns 8..1287. `np_vc2.sv` hands the scaler exactly those 1,280
columns, so the scaler copies rather than resamples. It measures the width
from the previous visible line, crops only when a line wider than 1,280 has
been seen (so another table still shows whole), and shows nothing until the
first line after reset has been measured. Until build 44 the display enable
was `DSPLY_EN`, RO1's pipeline enable, 1,318 pixels wide — and the scaler
squeezed 1,318 columns into 1,280 by dropping one every ~34, which looked like
damaged glyphs ([rex3-source-audit.md](../design/rex3-source-audit.md) §3.6).
`tests/colcheck.py` checks the board's picture column for column;
`tests/run-newport.sh` checks the raster is exactly 1280 × 1065 in simulation.

**The pixel is three clocks behind its address, and the delays are clocks.**
VC2 emits a column's frame buffer address in clock *t*; the line cache
answers in *t*+1; `slot_rgb` registers the answer, so the pixel is there in
*t*+2; CMAP's lookup is a registered read (it has to be, to infer as M10K), so
the colour is there in *t*+3. The syncs, the display enable and VC2's own pixel
enable travel together down a three-clock delay line, and the display ID and
the cursor down a two-clock one. They are delayed in clocks, not in pixel
enables, because VC2's enable pauses at its table-fetch stalls and those fall
inside the visible window (columns 251/252, 759/760, 1013/1014 and 1267/1268
on IRIX's table): delays counted in enables slipped against the data at every
stall. The frame buffer fetch runs on VC2's undelayed enable.
`verilator/tb_newport.cpp` test 9 samples the pins on the pixel enable the way
the scaler does.

**Aspect ratio.** *Original* is 5:4, because the Indy's own monitor was
1280×1024 and the PROM's boot screen is drawn for it; *Full Screen* and the
two custom ratios are the framework's.

**The refresh is 27.9 Hz because a pixel is one core clock.** Sixty hertz would
need the table's own 107.5 MHz pixel clock — VC2's generator in a clock domain
of its own, with crossings for the Display Control Bus writes going in and the
pixel stream coming out — and the drawing-plane stream alone would then ask
for 0.83 of the DDR3 port's peak (672 words × 1,024 lines × 60 a second,
against 50 million words). It is not built. On a mostly static desktop the
scaler hides the difference.

## `hps_io`: the OSD, the downloads, the disks, input and the clock

### The OSD

| entry | `CONF_STR` | what it does |
|---|---|---|
| Load PROM | `FS0,BIN` | loads an SGI PROM image by hand at ioctl index 0, the same index the automatic `boot.rom` uses; the core is held in reset until the download finishes |
| SCSI ID1, SCSI ID2 | `SC1`, `SC2` | disk images on SCSI IDs 1 and 2 |
| SCSI ID6 CD | `SC3` | a CD-ROM image on ID 6 |
| Graphics board: Fitted / None | `O[10]` | whether Newport answers on the bus. **Fitting it moves the console off the serial port**: ARCS installs a DisplayController with `ConsoleOut\|Output` and the PROM stops printing to the SCC, so *None* is a real machine configuration, not a degraded mode |
| Primary caches: On / Off | `O[11]` | both primary caches, for bisecting a fault onto them without a rebuild |
| Memory: 48MB / 32MB / 64MB | `O[13:12]` | main memory size; 48 MB is the default. Changing it resets the machine |
| Video debug: Off / Raw index | `O[14]` | shows the frame buffer's colour index as grey with CMAP taken out of the path (the cursor as white), and a line-cache miss as index `0x80` |
| UART debug: Off / 0x55 from clk_sys / 0x55 from sclk | `O[16:15]` | replaces the SCC on `UART_TXD` with an endless 9600-baud `0x55` from either clock domain, to separate the SCC from the path to the HPS |
| SCSI cache: On / Off | `O[17]` | the SCSI block cache (`rtl/scsi/scsi_cache.sv`, [scsi-block-cache.md](../design/scsi-block-cache.md)); Off makes every block request a single-sector HPS transaction |
| Aspect ratio | `O[122:121]` | Original (5:4), Full Screen, and the two custom ratios |
| Reset / Reset and close OSD | `T[0]` / `R[0]` | resets the machine |

`scripts/setopt.sh` writes the same bits into `/media/fat/config/SGIINDY.CFG`
without touching the OSD, because the screenshot API does not capture the OSD
and a blind keystroke walk through it cannot be checked.

### Downloads: the PROM and the Ethernet address

**Index 0 is the PROM, both ways in.** The OSD entry is `FS0`, and MiSTer's
Main uploads a file named `boot.rom` from the core's games directory at every
core start, at index 0, with no CONF_STR entry needed. One decode serves both.
The decode compares the **whole low byte** of `ioctl_index`, not just the slot
number in `[5:0]`: the framework also uploads `boot0.rom` .. `boot3.rom` at
index `i << 6`, and a decode on the slot alone would take `boot1.rom` as the
PROM.

**Index `0x40` is the machine's Ethernet address**, from
`games/SGIIndy/boot1.rom` — six bytes, most significant first.
`scripts/deploy.sh` writes that file on the device with
`tools/misterdeploy/mkmac.py`: `08:00:69:12:34` (SGI's OUI) and the MiSTer's
own last octet, so two boards on one network differ. Without the file the
address is `08:00:69:12:34:56`. It cannot be compiled in, and it cannot be
absent: with no `eaddr` the IRIX 5.3 installer dereferences the null it gets
back. The framework sends `boot1.rom` before `boot.rom`, whose download holds
the machine in reset, so the address is latched long before the guest can read
it; `sgi_ds1386.sv` and `eeprom_93c56.sv` seed it into the NVRAM and the
configuration EEPROM when reset releases.

**Reset.** The machine is held in reset while the PLL is unlocked, by
`RESET`, the OSD's reset, the user button, a change of memory size, and during
a PROM download — and for 65,535 clocks after the last of them. The framework
releases reset *before* it sends `boot.rom`, so for a moment the CPU fetches
from a PROM region holding whatever DDR3 powered up with; the download
re-asserts reset the instant it begins, and nothing done in that window
survives. The PROM region is written only by the download master, so the image
cannot have been damaged.

**Byte order.** `hps_io` runs in WIDE mode and hands over two bytes at a time
with the earlier byte in the low half of `ioctl_dout`. Each halfword is swapped
on the way in and four of them are assembled into one doubleword write, so the
first byte of the file lands in the most significant lane — the core's
convention above. The user LED is lit while the PROM downloads.

### SCSI images

`VDNUM` is 4: slot 0 is unused by the block interface (the PROM comes through
`ioctl`), and slots 1, 2 and 3 are SCSI IDs 1, 2 and 6 — exactly the targets
`sgi_scsi.sv`'s `TARGET_EN` builds, with ID 6 elaborated as a CD-ROM
(`CDROM_IDS`). A CD-ROM is a different device from a disk, not a disk with a
different file in it: `CDROM` changes INQUIRY, the logical block size, READ
CAPACITY and the MODE SENSE pages, so which ID is a CD-ROM is decided at
elaboration, not at mount time. Each slot carries its own target's LBA and
read-back word, so a disk request and a CD request that overlap cannot serve
each other's addresses; the block count per transaction comes from the block
cache, up to eight sectors. The disk LED follows the block interface, the only
thing in the machine that touches the SD card while it runs.

The slots are `SC`, not `S`, and the C is the point: the framework saves a
chosen image's path to `/media/fat/config/SGIIndy.s<n>` and mounts it again at
every core start, so a reload, a reset or a power cycle comes up with the same
disks. `scripts/mount.sh` writes those files directly. The file selector
offers `.img`, `.iso` and `.chd`; the images this project uses are raw disk
images and ISO files — `tests/run-irix.sh` converts a MAME CHD with
`chdman extractraw` before using it — and a CHD mounted directly is untested.

### Keyboard, mouse and clock

`ps2_key` and `ps2_mouse` go to the 8042 in IOC2 (`rtl/sgi/i8042.sv`), which
POST tests and the PROM reads for console input once graphics are fitted; see
[chipset.md](chipset.md#the-keyboard-and-mouse-controller).

The DS1386 real-time clock (`rtl/sgi/sgi_ds1386.sv`) takes its time from
`hps_io`'s RTC, which Main sends once when the core starts. The time registers
load from it, and a reset leaves them running, the way a battery-backed part
ignores the machine's reset. Main sends local time; IRIX keeps its clock in
GMT and applies `/etc/TIMEZONE`, so IRIX shows the MiSTer's time with
`TZ=GMT0`. Without the RTC the part comes up at a fixed 1996 date
([r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md) §5).

## Memory size

**The OSD offers 48, 32 and 64 MB, and 48 is the default.** Every one of them
is a size the MC can actually express, which is not the same as any number of
megabytes. A bank is four SIMMs, and the parts that do not need the BNK bit
give banks of 64, 16 and 4 MB, so an installable size is a sum of those across
at most four banks: 32 is 16+16, 48 is 16+16+16, 64 is one bank.
`rtl/sgi/sgi_memmap.sv` has the derivation. Asking for 32 as one 32 MB bank is
what made `--ram-mb 32` fail once — the PROM probed a bank that could not
answer and its own diagnostic said so. All three boot in simulation and the
PROM reports each one back as `Memory size: NN Mbytes`.

`sgi_memmap.sv` will build 96 (64+16+16) and 128 (64+64) as well, and they
were booted before being taken back out. **They are not offered**, because a
size the board cannot hold is not a choice — it is a way to get "No usable
memory found" out of a machine that looked fine in the menu — and main
memory's region is 64 MB.

Changing the size resets the machine, because the PROM sizes memory exactly
once: `szmem` probes the banks at boot and writes the result into the MC's
configuration registers, and nothing re-reads it.

## Clocks

**One PLL output, 50 MHz**, and everything runs on it: the CPU, the chipset,
Newport, `DDRAM_CLK` and `CLK_VIDEO`. Build 44 meets it with +0.979 ns of setup
slack. Raising it means a fit and the timing report, not an edit made
hopefully — and see *Video out* on why it would not buy 60 Hz. The PLL is the
template's MegaWizard `altera_pll`; its frequency is `output_clock_frequency0`
in `rtl/pll/pll_0002.v` (Quartus computes the counters at elaboration), with
the wizard's `gui_output_clock_frequency0` retrieval comment in `rtl/pll.v`
kept in step so a regeneration agrees. `sys/pll_q17.qip` pulls in
`rtl/pll.qip` itself, so `files.qip` must **not** name it again: that is a
duplicate-entity error, not a no-op.

**`sclk`, the SCC's 3.6864 MHz serial clock, is a numerically controlled
oscillator on `clk_sys`.** 50 MHz over 3.6864 MHz is 13.56, so no integer
divide gives it; a 32-bit accumulator adds `SCLK_INC` = 2 × 3.6864 / 50 × 2³²
= 633,187,924 every clock and toggles `sclk` on the carry, which lands within a
fraction of a percent — and a UART does not care about a fraction of a
percent. `z8530_scc.sv` genuinely clocks on it, so it is a second clock domain,
crossed with Gray-coded FIFO pointers and two-flop synchronisers. `sgiindy.sdc`
leaves it unconstrained on purpose — the timing report's one "Unconstrained
Clock" — rather than hiding it behind a false path; at 3.6864 MHz through
shift-register-depth logic there is about 270 ns of slack to lose.

## The serial port

SCC channel B — `tty1`, the SGI console — goes to `UART_TXD`/`UART_RXD`, which
`sys/sys_top.v` connects to the HPS's own UART, so on the ARM it is
`/dev/ttyS1`. Channel A has nothing plugged into it and its receive line idles
at mark. With **Graphics board: None** the PROM's console is on this port.

**On the boards this project has used, nothing from it has ever arrived at
`/dev/ttyS1`.** The **UART debug** option exists to split that question — a
`0x55` pattern timed from `clk_sys` or from `sclk`, in place of the SCC — and
the board-side test loops read their results out of memory instead
([deploy-and-debug.md](deploy-and-debug.md#the-serial-console--scriptsconsolesh)). The console
works in simulation, where every serial regression in `tests/` reads it.

## The debug beacon

`sgiindy.sv` streams 43 64-bit status words into the otherwise unused DDR3
window at ARM physical `0x35800000`, one word every 64 clocks — the whole set
every 2,752 clocks, 55 µs. It is the mux's lowest-priority master and is taken
only when nothing else is pending, so it cannot change what it observes, and
it runs on `pll_locked` alone, so a guest reset does not stop it. Word 0 is
`{0xBEC0, version, 0x00, heartbeat}`; the version is 14 (`0x0E`).

| words | contents | from |
|---|---|---|
| 0 | magic, version, a heartbeat that moves while the writer runs | `sgiindy.sv` |
| 1–7 | the SCSI bus and the HPS side, the WD33C93, targets 1 and 6, target 1's first-stall snapshot | `sgi_scsi.sv` |
| 8 | the HPC3 SCSI DMA channel's state | `hpc3_scsi_dma.sv` |
| 9 | interrupt delivery: the SCSI and SCSI DMA sources, the five interrupt lines into the CPU, INT2's status and mask registers | `sgi_indy.sv` |
| 10 | the PC entering decode and the CP0 debug bits, the pipeline's stall vector among them — what `prof.py` samples | `sgi_indy.sv` |
| 11–14 | the MC's VDMA engine and its descriptors, REX3's beat counters, the display ID and mode entry being shown | `sgi_indy.sv`, `newport.sv` |
| 15 | the line caches: drawing-plane misses, auxiliary misses, auxiliary lines skipped | `sgiindy.sv` |
| 16–20 | SCSI disk-time counters: HPS transactions, busy and wait time, block cache hits and misses, DATA-phase bytes and time | `sgi_scsi.sv` |
| 21–28 | CPU performance counters: instructions, stalls by stage, TLB walks, cache fills and their bus clocks | `sgi_indy.sv` |
| 29–34 | the DDR3 port: clocks each master held it, clocks the CPU and the rasteriser waited, transactions, read latency | `sgiindy.sv`, `ddr3_mux.sv` |
| 35 | instruction fills after an instruction TLB walk, and fills answered from a line already held | `sgi_indy.sv` |
| 36–39 | a main-memory read's latency split between the bridge and the queue; CPU waits behind DMA | `ddr3_mux.sv`, `sgi_indy.sv` |
| 40 | register 31 at retirement and the PC last retired | `sgi_indy.sv` |
| 41–42 | SCSI DATA-phase clocks split by whose turn it was | `sgi_scsi.sv` |

`tools/misterdeploy/bcnread.py` decodes it on the device (`--stats` for the
disk-time counters, `--perf` for the performance counters), `prof.py` samples
it as a statistical profiler, and `perfdiff.py` turns two `--perf` readings
into a workload's breakdown; see [the tools' README](../../tools/misterdeploy/README.md).
The comment above the writer in `sgiindy.sv` is the authoritative bit map.

## What is not there

- **Audio.** `AUDIO_*` is tied off. `hal2.sv` answers its register file, but
  `HAL2_REV` bit 15 is set — "no audio present" — so the PROM skips its audio
  initialisation, `hinv` lists no audio, and IRIX never loads the `kdsp_a2`
  driver, which spins with interrupts off against a HAL2 that has no DMA and
  no sample path ([scsi-fit-and-framebuffer-layout.md](../design/scsi-fit-and-framebuffer-layout.md) §3b).
- **Ethernet.** HPC3's Ethernet channel registers exist as storage — POST walks
  a pattern through them — but there is no Ethernet controller behind them.
  The Ethernet *address* exists so the PROM has one.
- **A remembered environment.** The DS1386's NVRAM is volatile: it comes up
  blank at every core load and the PROM prints `NVRAM checksum is incorrect:
  reinitializing.` on every boot. [nvram.md](nvram.md) is the plan for keeping
  it.
- **A GIO64 expansion card.** The slot is empty; the IRIS test device is a
  simulation fixture.
- **60 Hz.** See *Video out*.

## Installing a release

```
/media/fat/_Computer/SGIIndy_20260918.rbf   the core, in any "_" folder
/media/fat/games/SGIIndy/boot.rom           the PROM: releases/boot.rom
```

**`boot.rom` is a framework feature, not a core one.** Main uploads it at core
start with no OSD interaction (see *Downloads*); the name and the `.rom`
extension are fixed on the HPS side. Its directory is `games/<CoreName>`, where
`<CoreName>` is CONF_STR's first field, `SGIIndy` — not the file name — and
**MiSTer does not create that directory for you**: a missing one is silently
an absent PROM, and a machine executing whatever DDR3 powered up with.

`releases/boot.rom` is `roms/IP24_Indy/ip24prom.070-9101-011.bin` — PROM
Monitor SGI Version 5.3 Rev B10, R4X00/R5000, IP24, the image every test here
boots — under the name the framework looks for. `games/SGIIndy/boot1.rom`, the
Ethernet address, is optional. Disk and CD images go wherever the OSD's file
selector can reach them, and the mount is remembered.
[deploy-and-debug.md](deploy-and-debug.md) is the scripted path, for a build
under development.

## A trap paid for while writing this

**A line comment that begins with the word "Verilator" is a pragma.** The
first version of the top level had `// Verilator harness; ...` as the second
line of a comment, and every lint of the file failed with
`Unknown verilator comment: 'harness; on hardware nothing reads them.'`. It
costs a confusing five minutes the first time and nothing after that, and
several files here now say "the tool" instead.
