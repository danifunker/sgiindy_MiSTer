# Simulation

Everything this project claims about the machine's behaviour is measured under
Verilator first. `verilator/` builds a whole-machine harness — the core behind
C++ memory and device models — in a headless form for scripts and an
interactive one for looking, plus a bench for each module whose behaviour is
worth testing on its own. The regressions that drive the headless harness are
in `tests/` ([tests/README.md](../../tests/README.md)).

## What it needs

- **Verilator 5.** The Makefile's flag sets are the ones found to work with
  5.020, and its comments name each 5.020 fault they step around.
- **GHDL 6**, whose built-in synthesis backend lowers the CPU. The CPU is
  VHDL, which Verilator cannot read: `tools/gen_r4300_verilog.sh` lowers
  `rtl/cpu/r4300/`, `rtl/cpu/prim/` and `rtl/cpu/r4300_wrap.vhd` into
  `rtl/cpu/generated/r4300_wrap.v`, which is generated and gitignored. Quartus
  compiles the VHDL directly; the lowering exists for simulation only. **The
  Makefile runs the script only when that file is missing**, so after any
  change under `rtl/cpu/` run it by hand — a stale file quietly simulates the
  CPU as it was before the change, or fails with `PINNOTFOUND` if ports were
  added since. The script checks that `ghdl` actually runs, not just that it is
  on the path; a Debian `ghdl-llvm` whose libLLVM will not load fails there
  with the one-line fix printed.
- A C++17 compiler; SDL2 and OpenGL for the GUI; zlib for `newportreplay`.
- Python 3 for the tests' checkers, and a MIPS cross compiler for the
  bare-metal test images ([tests/README.md](../../tests/README.md#the-toolchain)).

## The whole-machine harness

One top level and one set of device models serve both the headless and the
interactive harness. A GUI that wrapped a different top level would drift, and
then "it works in the GUI" would stop meaning anything about what the scripts
run.

| file | what it is |
|---|---|
| `verilator/sim_top.sv` | the core, `sgi_indy`, wired the way `sgiindy.sv` wires it, with C++-backed models on its memory, PROM, GIO64 and frame buffer ports |
| `verilator/sim_ram.v` | those models' RTL side, reached by DPI. Every port answers the cycle after its request; main memory's reads may be bursts of up to four words, one word a cycle, as on `ddr3_mux` |
| `verilator/sim_devices.cpp`, `sim_devices.h` | the storage — RAM, the PROM, and the 16 MB frame buffer holding both plane sets — the IRIS test device, the ELF loader and the SCSI disk images |
| `verilator/sim_scsi.h` | the SCSI block device as `hps_io` presents it: request levels, runs of 512-byte blocks through the sector buffer, a few hundred cycles per block, because an instant acknowledgement hides every ordering bug in the requester |
| `verilator/sim_ps2.h` | keyboard and mouse events in `hps_io`'s toggle form |
| `verilator/sim_uart.h` | the serial decoder and transmitter both harnesses share |
| `verilator/sim_video_cap.h` | the video output pins captured into frames |
| `verilator/sim_cputest.cpp` | the headless harness |
| `verilator/sim_gui.cpp` | the interactive harness |

**What it does not model is the MiSTer memory path.** Every port of `sim_top`
is a one-cycle `sim_ram`, so the whole-machine simulator never runs
`ddr3_mux`, the display line caches or their arbiter; the benches below and
the board are the only places those run
([mister-integration.md](mister-integration.md#the-display-path)). The harness
also drives the SCC's serial clock itself — one period every eight system
clocks rather than the board's 3.6864 MHz — at a rate chosen to keep console
runs short.

### Headless: `make -C verilator cputest`

```sh
make -C verilator cputest
./verilator/obj_dir/Vsim_top --prom roms/IP24_Indy/ip24prom.070-9101-011.bin \
    --no-gfx --stuck 20000000 --hot
./verilator/obj_dir/Vsim_top --elf .../cputest.elf --testdev --no-gfx
```

No SDL, no window: this is the build the regressions use. It is compiled with
`WM_OPT` rather than `-O3`: on this design Verilator 5.020 dies with an
internal fault that prints no location at every optimisation level above
`-O0`, and its gate optimiser fails on `rtl/scsi/scsi.v`, so `WM_OPT` is
`-fno-gate -O0` plus the individual optimisations that survive, with the
unroll limits `sgi_hpc3.sv`'s reset loop needs. It costs about half the
simulation speed and it is the flag set known to elaborate the whole design.

The same machine builds under other names:

| target | binary | what differs |
|---|---|---|
| `wholemachine` | `verilator/obj_wm/Vsim_top` | nothing but the directory |
| `wholemachine2` | `verilator/obj_wm2/Vsim_top` | a second directory, so an instrumented build can compile while a long run still executes the first (overwriting a running executable fails); `WM_DEFS=+define+...` adds defines — `MSG_DEBUG` turns on `scsi.v`'s per-message trace, the only way to see the bytes IRIX puts in a MESSAGE OUT |
| `cputest-rex3-debug` | `verilator/obj_dir_rex3dbg/Vsim_top` | `REX3_DEBUG`: one line per accepted drawing command |
| `cputest-dcb-debug` | `verilator/obj_dir_dcbdbg/Vsim_top` | `DCB_DEBUG`: one line per Display Control Bus transfer and per byte the colour map receives |
| `cputest-dma-debug` | `verilator/obj_dir_dmadbg/Vsim_top` | `DMA_DEBUG`: the SCSI DMA engine's state, every cycle |
| `gui` | `verilator/obj_dir/Vsim_gui` | the interactive harness, below |

`gui` and `cputest-dma-debug` are still built with `-O3`, the level the
`WM_OPT` comment says Verilator 5.020 cannot build this design at; whether they
build with the Verilator you have is not verified here. The Makefile's default
target (`make` with no target, `obj_dir/Vemu`) names source files that no longer
exist and does not build.

### Loading and running

| option | what it does |
|---|---|
| `--prom FILE` | load a boot PROM image at `0x1FC00000` |
| `--elf FILE` | load a bare-metal ELF straight into RAM and boot from its entry point. Both ends of every segment are probed after writing, because unmapped physical space accepts writes silently and a mis-addressed load would otherwise show up as a CPU fetching zeros |
| `--boot-pc HEX` | override the reset PC (default `0xBFC00000`) |
| `--testdev` | fit the IRIS test device in GIO64 slot 0 — the CPU test suite's exit channel |
| `--ram-mb N` | main memory size, default 64 (the OSD's default is 48) |
| `--max-cycles N` | give up after N clocks (default 4×10⁹) |
| `--no-gfx` | leave Newport unfitted, which keeps the PROM's console on the serial port |
| `--no-icache`, `--no-dcache` | run with one or both primary caches off |
| `--scsi-nocache` | bypass the SCSI block cache, as the OSD's *SCSI cache: Off* does |
| `--disk ID=PATH` | attach an image at SCSI target ID (default 1); read-only — writes are kept in memory for the run. ID 6 is the CD-ROM, as on the board |
| `--disk-rw ID=PATH` | the same, with writes going through to the file |
| `--console FILE` | also write the console output to FILE |
| `--type STR`, `--type-on TRIG STR` | type at the console once it goes quiet, or once TRIG has appeared (`\r`, `\n` and `\t` understood); `--idle N` sets what counts as quiet |
| `--stop-on STR` | end the run once STR has appeared on the console |
| `--key TEXT`, `--key-on TRIG TEXT`, `--key-at N STR` | type at the PC keyboard port instead — the only way to type once Newport has taken the console |
| `--uart` | also decode the SCC's `txdb` pin and compare it with the byte tap |

With `--elf` the exit status is the program's own: the value it hands the test
device, or the `rc=` it prints in `IRIS-CPUTEST-DONE` when there is none.

**The console is read from a byte tap, not from the wire.** `sgi_scc.sv`
presents each byte as the transmitter pops it off its FIFO — what the CPU
handed the hardware, independent of the bit rate. `--uart` decodes the `txdb`
pin as well, with the bit time measured from the first start bit and the stop
bit checked on every frame, and `tests/run-scc.sh` insists the two agree: a
model that queued the writes and never shifted anything would pass the first
and fail the second.

**Typing goes in on the wire.** The console input is a real UART transmitter
on `rxdb`, not a back door into the SCC's receive FIFO, so a keystroke only
arrives if the receiver, the baud rate generator and the FIFO all work. Its bit
rate is not configured but measured from the machine's own transmitter, so
whatever the PROM programs into WR12/13 is what the harness sends at. The PROM
changes rate during boot — it announces `diagnostic baud rate set to 19200`
before the System Maintenance Menu — so the rate is re-measured for every
burst of output, and a run shorter than the current bit time is taken at once
as proof that the machine has sped up. Nothing is typed until the machine has
printed something, because sending at a guessed rate produces plausible wrong
characters. `tests/uart/run.sh` tests exactly those cases on the host.

### Diagnostics

| option | what it does |
|---|---|
| `--stuck N` | report when no new bus address has appeared for N clocks, and name the address being hammered |
| `--hot` | on exit, the most-accessed addresses |
| `--trace`, `--trace-from N`, `--trace-count N` | a timestamped bus trace with decoded register names |
| `--trace-from-pc HEX` | arm the bus trace the first time that PC is decoded (implies `--trace`) |
| `--watch HEX`, `--watch-count N` | every bus access to that doubleword, with cycle, direction and data (repeatable) |
| `--pc`, `--pc-from N`, `--pc-count N` | one line per instruction entering decode |
| `--pc-user FILE` | every user-mode PC with its cycle, for diffing two runs |
| `--exc`, `--exc-count N` | one line per exception the CPU accepts: `ExcCode`, `BadVAddr`, `EPC` |
| `--epc`, `--cop0` (`--epc-count`, `--cop0-count`) | one line per change of CP0's EPC, or of its exception-state word |
| `--irq` | one line per change of INT2's five lines into the CPU, with the status and mask registers that decided them |
| `--ramdump ADDR:LEN:FILE` | on exit, guest RAM to a file (repeatable); KSEG0 and KSEG1 are stripped, so `0x88010174` works |
| `--fatal-errors M` | which `cpu_error` bits abort the run (default `0x12`: a wedged pipeline or a write-FIFO overflow) |
| `--prof FILE`, `--prof-callers H,...` | a clock-weighted decode-PC profile, and the call sites of listed functions |
| `--itrace FILE`, `--dtrace FILE` | the instruction and data caches' access streams, for replaying through other geometries (`tools/icachesim.c`, `tools/dcachesim.c`) |

Every run prints, on exit, **the last 64 PCs** with the cycle each was decoded
on, **the unclaimed-address summary** — every bus cycle no device answered,
grouped by address with counts and first and last cycle — and how often each
`cpu_error` flag was raised, if any was. The unclaimed list is the most useful chipset
diagnostic there is: the next thing to build is nearly always the address at
the top of a poll loop. The CPU's own error outputs are N64 debugging aids, not
faults — the test suite raises most of them on purpose — so only the two that
mean the core itself has wedged stop the run by default.

Some of these need a word on how to read them:

- **`--stuck` watches the bus, not the PC**, and so names the register being
  polled, which the PC alone would not.
- **On PROM text, `--watch` is a PC watch.** The PROM runs from `0xBFC…`,
  KSEG1, which is uncached, so every instruction it executes is a bus read: a
  watch on a PROM address says whether a routine was reached, and one on a RAM
  address says what a pointer was set to. It answers "is this code even
  running" without a trace of four million transactions — it is what showed
  that the PROM had been printing the `hinv` disk line all along while the
  harness exited first ([history.md#13](../history.md#13)). **Read the counts
  as a lower bound**: they are bus cycles, and code inside a loop is not
  fetched once per iteration. Zero means never reached.
- **The PC is the decode tap**, `dbg_pc` in `rtl/cpu/r4300/cpu.vhd`, because
  `pcOld2`..`pcOld4` and `cpu_export.pc` live inside `-- synthesis
  translate_off` and are not in the netlist GHDL lowers. It is the instrument
  for a failure that has stopped touching the bus: an IRIX kernel wedged in a
  loop small enough to sit in the caches issues no bus cycles, so `--stuck` has
  nothing to name. Read the cycle numbers as well as the addresses:
  consecutive cycles on one PC are a stall, a repeating span with no gaps is a
  spin, and the same PC after a long gap is a machine that waited. See
  [cpu-validation.md](cpu-validation.md#a-tlb-refill-taken-with-exl-set)
  for the bug sixty-four PCs named in one run.
- **`--pc-user` re-presents an instruction on every pipeline replay**, because
  it is the decode tap; two configurations replay in different places, so a
  raw diff of two runs reports divergences that are not there. Collapse
  consecutive repeats in both streams first and treat the result as a lead.
  `dbg_rpc`/`dbg_retire` exist in the RTL for a retire-accurate trace, but the
  stream they give is not yet sequential and the harness does not use them.
- **`--exc`** separates a TLB miss from an address error from a reserved
  instruction, where the console says "generated trap" for all three. With
  `--trace-from-pc`, `--exc`, `--epc` and `--cop0` start at the arm instead of
  at cycle 0, which on a running kernel is the difference between the
  exception you want and two hundred timer interrupts.
- **`--irq`** tells an interrupt that never fires from one that fires and is
  ignored: an asserted status bit against a zero mask is software that has not
  enabled the source; a clear status bit is the device. It is what showed that
  the PROM masks LOCAL0 off entirely and polls the SCSI chip instead.
- **`--ramdump`** is `guestmem.py` for the simulator: disassemble the result
  with `tools/misterdeploy/disbin.py`.
- **`--prof`** charges every clock to the decode PC, stalled clocks counted
  separately, the way the board's beacon profiler sees it;
  `tools/misterdeploy/simprof.py` folds a profile through the kernel's symbols.

### Interactive: `make -C verilator gui`

```sh
make -C verilator gui
./verilator/obj_dir/Vsim_gui --prom roms/IP24_Indy/ip24prom.070-9101-011.bin --run
```

SDL2, OpenGL2 and Dear ImGui, from the MiSTer simulation framework vendored in
`verilator/sim/`. It takes `--prom`, `--elf`, `--boot-pc`, `--testdev`,
`--ram-mb`, `--no-gfx`, `--disk`, `--disk-rw` and `--run`. The panels, each
toggled from the View menu:

- **Display (Newport)** — the picture off the video pins, or the frame buffer
  store.
- **Control** — run and stop (`F5`), single step (`F11`), 5,000 steps (`F6`),
  reset, the cycle rate and the `cpu_error` flags.
- **Console** (SCC channel B, `tty1`) — what the machine printed, with a box to
  type back at it, which stays disabled until the machine has printed
  something to measure the bit rate from.
- **Bus trace**, with decoded register names; **Unclaimed addresses**; **Hot
  addresses**.
- **PROM patches** — runtime word patches, for "would it get further if this
  returned X". They live in the harness and never in the image on disk.
- **RAM** and **PROM** hex editors, which start closed.

`F12` hands the keyboard and mouse to the machine, as PS/2 through the 8042,
and takes them back; while it has them the pointer is captured in relative
mode, so the guest sees continuous motion. The GUI has no PC panel — the
headless harness prints the PC.

This is core ImGui, **not the docking branch**: the panels are plain windows,
tiled into columns the first time and the user's business after that. Every one
resizes from any edge or corner, and the layout is remembered in an
`imgui.ini` written to whatever directory the harness was launched from
(gitignored). The View menu's **Reset layout** is the escape hatch when a
window ends up where its resize grip cannot be reached; deleting the ini file
does the same. Two things made this look broken once and are worth not
rediscovering: `MemoryEditor::DrawWindow` clamps its window's width to its own
content, so a hex editor built with it refuses to widen — use `DrawContents`
inside a window of your own; and ImGui's default `ResizeGrip` colour is nearly
transparent, which on a dark theme reads as "this window cannot be resized".

## Graphics in the harness

Newport is fitted by default, and **that changes where the console goes**: the
PROM moves it to the graphics head as soon as ARCS finds a DisplayController,
and the serial port falls silent after the NVRAM line. Every serial-console
test passes `--no-gfx` for that reason. With the board fitted, the picture is
the output:

| option | what it writes |
|---|---|
| `--fbdump FILE` | the frame buffer store as a binary PPM on exit: frame buffer columns 0..1279 of rows 0..1023, the drawing planes' colour |
| `--fbindex` | with `--fbdump`, the colour index as grey instead — what you want before a palette has been loaded |
| `--viddump FILE` | the last complete frame that came out of the video **pins**, after XMAP9's mode table and CMAP's palette |

**`--fbdump` and `--viddump` are not the same picture, and the difference is a
diagnostic.** A fault in the palette, in the mode table, or in the channel
order of the readout is invisible in one and unmissable in the other — which is
how a Display Control Bus that dropped the third byte of every colour write was
found: it turned the whole boot screen yellow-green while the store looked
perfect. `tests/vidshift.py PINS.ppm STORE.ppm` compares the two row for row.

Every run that fits the board prints a video summary from the **pins**:

```
video: N frames, best WxH, last WxH, N lit pixels
video edges: N hsync, N vsync, N display-enable, N displayed pixels
video colour: N red, N green, N blue pixels
```

A non-zero summary means the whole chain worked — VC2 walked its timing table,
the readout found pixels, XMAP9 and CMAP turned them into colour. The size is
the display-enabled width by the frame's lines: exactly 1280 × 1065 on the
PROM's table, which `tests/run-newport.sh` asserts.

`make -C verilator vc2test` builds a unit test of VC2's timing generator alone
(`verilator/tb_vc2.cpp`, run as `verilator/obj_dir_vc2/Vnp_vc2`): it drives the
Display Control Bus port directly with a table of a known geometry, so a wrong
picture in a boot can be attributed to the table walk or ruled out of it in a
second.

### REX3's command trace

`make -C verilator cputest-rex3-debug` builds the machine with `np_rex3.sv`'s
`REX3_DEBUG` block on. It prints one line per accepted drawing command with
every register that command depends on:

```
[REX3] 205 dm0=00009106 dm1=30007109 xy=(696,974)-(702,0) sav=696 oct=1 zp=e0000000 ci=00000030 ...
```

That is the first tool for a wrong picture, not the last: a trace line
against what the PROM's graphics driver meant to draw settles in minutes what a
screenshot cannot settle at all. `tests/rex3_replay.py` replays the trace into
a model frame buffer and compares it pixel for pixel with the one the run
dumped; `tests/run-rex3.sh` is that end to end, and on build 44 it checks all
1,310,720 pixels of the PROM's screen against 3,928 commands with none left
unchecked.

### The Display Control Bus

`make -C verilator cputest-dcb-debug` builds the machine with `DCB_DEBUG`. It
prints one line per Display Control Bus transfer and one per byte a colour map
receives:

```
[DCB] WR addr=1 crs=2 width=3 crsinc=0 data=05050500
[CMAP4] WR crs=2 data=05 ctr=0 addr=1d05
[CMAP4] WR crs=2 data=05 ctr=1 addr=1d05
[CMAP4] WR crs=2 data=00 ctr=2 addr=1d05
```

Four lines, and that bug is in them: the PROM asked for grey 5 and the third
byte arrived as zero, because the datum is left-aligned in `DCBDATA0` and the
bus shifts it out from the top. Everything on the Newport board except REX3 is
reached through this bus, so when a palette, a mode table or a timing table is
wrong, this is where the wrongness is either visible or ruled out.

## The module benches

Each builds into its own directory under `verilator/`. The whole-machine
harness answers memory in one cycle; most of these exist because the board
does not.

| `make -C verilator` | bench | run | what it checks |
|---|---|---|---|
| `ddr3test` | `tb_ddr3.cpp` | `obj_dir_ddr3/Vddr3_mux` | the DDR3 mux against a bridge with random `BUSY`, random latency and garbage on `DOUT` except when it is valid: every read the last write, every request acknowledged once, the regions apart, the display not starved, REX3's held request taken once |
| `ddr3test_sub` | `tb_ddr3.cpp` | `obj_dir_ddr3sub/Vddr3_mux` | the same with 3-word display sub-bursts |
| `ramarbtest` | `tb_ramarb.cpp` | `obj_dir_ramarb/Vram_arb` | the CPU/DMA arbiter with both masters in their real shapes; `RAMARB_LAT=N` sets the port's latency (default 20) |
| `linecachetest` | `tb_linecache.cpp` | `obj_dir_lcache/Vfb_linecache` | the display line cache, built with the empty-line flags, driven with the display's real pattern against a memory that accepts bursts late and returns them in gaps: every pixel after the first frame correct, empty lines skipped without a fetch, a marked line fetched again |
| `fetcharbtest` | `tb_fetcharb.cpp`, `.sv` | `obj_dir_fetcharb/Vtb_fetcharb` | both line caches and their arbiter against a bridge that latches a request when it first sees it and issues it later, as the mux does |
| `vc2test` | `tb_vc2.cpp` | `obj_dir_vc2/Vnp_vc2` | VC2's table interpreter, the visible window's width, the display-ID walk |
| `rex3test` | `tb_rex3.cpp` | `obj_dir_rex3/Vnp_rex3` | that a drawn rectangle reaches a memory that is not always ready; `REX3_ACK_DELAY=N` (0 is `sim_top`'s memory, 40 is DDR3-like), `REX3_MAP=1` prints the coverage |
| `rex3draw` | `tb_rex3draw.cpp` | built and run | `np_rex3` against a transcription of IRIS's rasteriser (`rex3_generic.rs`), over IRIS's corpus of the draw shapes a real IRIX desktop used and a random walk over the modes; `REX3D_CASES`, `REX3D_SEED`, `REX3D_ACK`, `REX3D_VERBOSE` |
| `newporttest` | `tb_newport.cpp` | built and run | `newport.sv` at its own bus, below |
| `newportreplay` | `tb_newport_replay.cpp` | built, then its self-test | an IRIS REX3 bus trace through `newport.sv`, below |
| `mcdmatest` | `tb_mcdma.cpp` | built and run | the MC's GIO64 DMA engine against a transcription of IRIS's `dma_worker` and `translate_addr`: fill, both copy directions, the µTLB and its faults |
| `hal2test` | `tb_hal2.cpp` | built and run | HAL2's indirect register file against IRIS's decode, and the ISR bit the PROM's audio init spins on staying clear |
| `tb_hpc3` | `tb_hpc3.sv` | built and run | HPC3's register file against a shadow of the specification's map; `HPC3=FILE` runs it on another version of the module |
| `tb_scsi_cache` | `tb_scsi_cache.sv` | built and run | the SCSI block cache against an engine-like requester and a slow device: prefetch, write-behind, re-base, passthrough, mount invalidation, the OSD bypass, a random mix |
| `tb_scsi_cache_sgi`, `tb_scsi_cache_nocd` | `tb_scsi_cache.sv` | built and run | the same bench in the shape `sgi_scsi.sv` instantiates (the CD slot cached, a 64-sector window, multi-block) and with the CD slot passed through |
| `tb_eeprom` | `tb_eeprom.sv` | built and run | the 93C56 configuration EEPROM driven the way the PROM drives it, against a shadow copy |
| `tb_ds1386` | `tb_ds1386.sv` | built and run | the DS1386's time registers loaded from `hps_io`'s RTC, kept across resets, overridden by software |
| `cpuonly` | `tb_cpuonly.cpp`, `.sv` | built and run | the CPU and `r4300_bus` alone against a memory whose latency is swept — it builds where the whole machine does not |

Build 44's recorded gates: `newporttest` 27 of 27, `tb_rex3` at acknowledgement
delays 0, 8 and 40, `tb_rex3draw` over five seeds at latencies 0, 2 and 25
(20,426 cases each, no difference from IRIS), `tb_vc2`, `run-newport.sh` and
`run-rex3.sh` all passing.

### The Newport benches

`tb_rex3` and `tb_rex3draw` drive `np_rex3`'s 32-bit register port. The
Newport benches drive **`newport.sv` itself** — REX3, VC2, both XMAP9s, both
CMAPs and the BT445 — through the bus the machine really uses:
`verilator/tb_newport.h` has the contract (the CPU's 32- and 64-bit loads and
stores with `r4300_bus.sv`'s byte lanes, and the MC's VDMA beats) and a 16 MB
frame buffer model whose latency `--fb-lat N` sets.

**`newporttest`** runs nine groups of directed tests: 32-bit register writes
read back through both word lanes; the 64-bit register pairs GL writes
(`XYSTARTI`+`XYENDI` and `HOSTRW0`+`HOSTRW1` with GO, and the colour pairs);
reads behind a running primitive, with `STATUS` never waiting; VDMA beats with
the start byte in the address; GL's float coordinates and `XENDF1`; a write to
`SETUP`; and display column alignment, with VC2, XMAP9 and CMAP programmed over
the Display Control Bus as the PROM does and the pins sampled on the pixel
enable the way the MiSTer scaler samples them — pixel N of the 1280-pixel
window must be frame buffer column 8 + N. Every test starts from a reset and a
cleared frame buffer, and a draw check compares the whole frame buffer against
a snapshot: the rectangle must have changed to the expected values and nothing
else anywhere may have changed. Every check is must-pass.

```sh
make -C verilator newporttest
./verilator/obj_dir_newport/Vnewport_test --fb-lat 20 2 5    # tests 2 and 5, slower memory
```

**`newportreplay`** replays a REX3 bus trace captured from IRIS through
`newport.sv` and compares the frame buffers with IRIS's. The trace is
RX3TRACE — every CPU load and store to REX3 with its width and every VDMA beat,
in program order, with MARKERs where IRIS dumped its frame buffers;
`tools/rx3trace.py` writes, prints and synthesises them. Each record is driven
through the same bus model as the directed tests, waiting for each
acknowledgement the way the CPU and the DMA engine do; at every MARKER both
plane sets are dumped (`core_rgb_NNNN.bin`, `core_aux_NNNN.bin`, 2048 × 1024
32-bit words, IRIS's layout) and, given `--iris-rgb`/`--iris-aux` patterns,
compared with IRIS's dumps of the same moment under a mask (by default the low
24 bits: byte 3 of a drawing slot is the core's copy of the window ID), with
PNGs of both and of the difference wherever they differ. `--init-rgb` and
`--init-aux` start the replay from a dump, because IRIS powers up with noise in
its frame buffers rather than zeros. `--split64`, `--gl-coords` and
`--sync-reads` (all three: `--emulate-fixes`) are bench-side emulations that
change what is sent, never the RTL, so a trace can be compared past a defect
already named; `--fail-on-diff`, `--max-records` and `--timeout` bound a run.

```sh
make -C verilator newportreplay    # builds, then the synthetic self-test
./verilator/obj_dir_npreplay/Vnewport_replay TRACE -o OUT \
    --iris-rgb 'IRIS/rgb_%04u.bin' --iris-aux 'IRIS/aux_%04u.bin'
```

On build 44 the IRIS capture of IRIX 5.3 from power-on — the PROM, the boot, X,
`xlock` and the GL demos `ep`, `bongo` and `buttonfly`, 43,401,483 records and
ten markers — replays with no difference in any of the twenty plane sets
compared (8.37 G clocks, about 48 minutes).

## Writing a bench

The benches above found real defects because of how their models were built,
and each of these was learned by a bench that passed when it should not have:

- **The model must be as unhelpful as the thing it stands for.** A memory that
  answers in one cycle hides every bug whose window is as wide as memory is
  slow: the CPU/DMA arbiter, REX3's opaque-fill path losing writes nothing
  accepted, the mux taking a held request twice, the line cache tested at half
  the pixel rate the hardware ran at. Sweep the latency.
- **Settle everything a model presents before the clock edge.** Two bridge
  models decided whether a request had been accepted after the edge, by which
  time the module had already seen the signal and moved on; one made a working
  mux look broken, the other made a working cache report zero pixels checked
  and zero misses, which reads like success.
- **Test both sides of a handshake against one contract.** `tb_ddr3` never
  checked when `fbr_taken` arrived, and `tb_linecache` modelled a bridge that
  asserted it at issue — which the mux did not do. Two benches, both passing,
  and the two sides disagreeing.
