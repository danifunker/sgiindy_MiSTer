# Releases

Built bitstreams live in `releases/`, under the date they were built. Nothing
else is kept there — this file is the history, so that the directory a person
downloads from is only the files they need.

Each entry's md5 is checked against what was actually running on the board when
the result below was seen, not against whatever the fitter last left in
`output_files/`.

## Installing one

```
/media/fat/_Computer/SGIIndy_<date>.rbf     the core
/media/fat/games/SGIIndy/boot.rom           the PROM
```

Both files are in `releases/`. Two things about that second line, because both
of them fail silently:

* **MiSTer does not create `games/SGIIndy` for you.** `prefixGameDir` in the
  framework only *computes* the path; the `FileCreatePath` call beside it is
  commented out. A missing directory is not an error anywhere — it is an absent
  PROM, and the machine executes whatever DDR3 powered up with.
* **`SGIIndy` is not a name you can change.** It is the first field of
  `CONF_STR` in `sgiindy.sv`, and it is what the framework uses to find
  `boot.rom`. Rename the directory and the PROM stops being found.

`scripts/deploy.sh` does all of this over the network, including the directory.
See [19-hardware-bringup.md](19-hardware-bringup.md).

---

## SGIIndy_20260829 — the first build that draws

**The machine draws its own boot screen on a DE10-Nano**, and goes on to the
System Maintenance Menu. `releases/SGIIndy_20260829_bootscreen.png` is the
splash: the gradient, the hourglass, "Running power-on diagnostics...",
"WELCOME TO INDY" and "Silicon Graphics Computer Systems", in colour, stable
across screenshots ninety seconds apart. The frame buffer holds 171 distinct
colour indices where the build before it held three.

    rbf       md5 214e9fddd29f7322490de25643388446   3,813,644 bytes
    boot.rom  md5 11bb4acd64fb7c79c985d3d09390668b   PROM Monitor 5.3 Rev B10
                                                     (ip24prom.070-9101-011)
    Quartus 17.0.2 Lite, 5CSEBA6U23I7
    30,611 / 41,910 ALMs (73%), 294 / 553 M10K (53%), 51 / 112 DSP
    Timing met on every clock, TNS 0.000, core clock slack +4.287 ns

### What works

* The PROM runs, sizes memory, finds Newport, programs VC2, draws the boot
  screen and reaches the **System Maintenance Menu**.
* Video out at 1318 x 1024 — the raster `tests/run-newport.sh` asserts, to the
  pixel.
* The colour map: the boot screen's colours are right.
* Main memory in DDR3, 48 MB, and the PROM's own walking-bit sizing test passes
  over all of it.
* PS/2 keyboard and mouse reach the 8042 in IOC2; three SCSI drive slots exist.

### What does not

* **It is slow to get there.** REX3 waits for every write to be acknowledged,
  so a pixel costs a DDR3 round trip and the boot screen takes a while to
  paint. Give it a minute or two, and a restart if it seems not to be
  progressing. Correct, and slower than it needs to be — a "taken" handshake on
  the frame buffer port would let more than one write be in flight.
* **About 14 Hz.** `PIX_DIV` is 2 because at 1 the display wants 0.80 words a
  clock against a DDR3 port whose peak is 1.00. The fix is not a faster clock:
  it is to split the frame buffer into separate RGB and auxiliary planes the
  way IRIS does, which halves the fetch and gives 27 Hz back. See
  [18-mister-integration.md](18-mister-integration.md) section 0.
* **No mouse cursor.** The mouse's data reaches the 8042, but nothing draws a
  pointer: VC2 holds the position registers and generates no cursor planes, and
  `np_bt445`'s three cursor colours are wired to nothing. See
  [16-newport-plan.md](16-newport-plan.md), milestone N4.
* **No serial console.** With the graphics board unfitted the machine still
  runs, but `/proc/tty/driver/serial` on the HPS reports `rx:0` — not one start
  bit, ever. `sclk` is the suspect; the OSD's "UART debug" entry is a probe that
  settles it and has not been run yet.
* No audio, no Ethernet, and nothing persists across a reset — the PROM rebuilds
  its environment every boot.

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
