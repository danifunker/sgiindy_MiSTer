# Releases

Built bitstreams, kept under the date they were built. Each one is exactly the
file that produced the result described below — the md5 is checked against what
was running on the board, not against what the fitter happened to leave in
`output_files/`.

## SGIIndy_20260830 — the first build that draws

**The machine draws its own boot screen on a DE10-Nano.** The gradient, the
hourglass, "Running power-on diagnostics...", "WELCOME TO INDY" and "Silicon
Graphics Computer Systems", in colour, stable across screenshots ninety seconds
apart. `SGIIndy_20260830_bootscreen.png` is that screen, captured through the
MiSTer's own screenshot API.

    rbf       md5 214e9fddd29f7322490de25643388446   3,813,644 bytes
    boot.rom  md5 11bb4acd64fb7c79c985d3d09390668b   PROM Monitor 5.3 Rev B10
                                                     (ip24prom.070-9101-011)
    Quartus 17.0.2 Lite, 5CSEBA6U23I7
    30,611 / 41,910 ALMs (73%), 294 / 553 M10K (53%), 51 / 112 DSP
    Timing met on every clock, TNS 0.000, core clock slack +4.287 ns

### Installing it

```
/media/fat/_Computer/SGIIndy_20260830.rbf     the core
/media/fat/games/SGIIndy/boot.rom             the PROM
```

**MiSTer does not create `games/SGIIndy` for you** — `prefixGameDir` only
computes the path, so a missing directory is silently an absent PROM rather
than an error. `scripts/deploy.sh` does the whole thing including that.

`SGIIndy` must stay the name: it is CONF_STR's first field and it is what the
framework uses to find `boot.rom`.

### What works

* The PROM runs, sizes memory, finds Newport, programs VC2 and draws.
* Video out at 1318 x 1024, the raster `tests/run-newport.sh` asserts.
* The colour map: the boot screen's colours are right.
* Main memory in DDR3, 48 MB, and the PROM's own walking-bit sizing test
  passes over all of it.
* PS/2 keyboard and mouse reach the 8042; three SCSI drive slots exist.

### What does not

* **It stops at "Running power-on diagnostics..."** and does not reach the
  System Maintenance Menu. That is the next thing to chase and it is
  undiagnosed — do not assume it is graphics.
* **About 14 Hz.** `PIX_DIV` is 2 because at 1 the display wants 0.80 words a
  clock against a DDR3 port whose peak is 1.00. The fix is not a faster clock:
  it is to split the frame buffer into separate RGB and auxiliary planes the
  way IRIS does, which halves the fetch and gives 27 Hz back. See
  `docs/18-mister-integration.md` section 0.
* **No serial console.** With the graphics board unfitted the machine still
  runs, but `/proc/tty/driver/serial` on the HPS reports `rx:0` — not one start
  bit, ever. `sclk` is the suspect; the OSD's "UART debug" entry is a probe
  that settles it and has not been run yet.
* **Drawing is slow.** REX3 waits for each write to be acknowledged, so a pixel
  costs a DDR3 round trip. The boot screen takes seconds. Correct, and slower
  than it needs to be: a "taken" handshake on the frame buffer port would let
  more than one write be in flight.
* No audio, no Ethernet, no cursor, nothing persists across a reset.

### What made it draw

Four bugs, and every one of them was the same bug: RTL written against
`verilator/sim_ram.v`, which accepts a request every cycle and never refuses
one, meeting `rtl/mister/ddr3_mux.sv`, which holds a single transaction at a
time and takes tens of cycles over it.

| | what was wrong |
|---|---|
| `ddr3_mux.sv` | a HELD request was latched twice, which put REX3 permanently one acknowledgement behind and made it write the CPU's instruction fetches into the frame buffer as pixels |
| `newport.sv` | `PIX_DIV` had gone to 1 for a free doubling of the frame rate; it was not free, and the display missed 710 of every 1318 pixels |
| `fb_linecache.sv` | rewritten as a four-buffer ring — and the first attempt declared them in a generate loop, which infers no memory at all and failed the fit at 291% of the device with no warning |
| `np_rex3.sv` | `DR_FILL` asserted a write every cycle and counted assertions rather than acceptances: 249 of a 256-pixel rectangle lost at DDR3 latency, and then it wedged |

In three of the four the existing test was actively reassuring. `tb_ddr3` drove
every master as a one-cycle pulse and never modelled one that holds its request
through the acknowledgement; `tb_linecache` hard-coded `PIX_DIV = 2` long after
the RTL moved to 1. Both fail against the old code now, and
`verilator/tb_rex3.cpp` is new.
