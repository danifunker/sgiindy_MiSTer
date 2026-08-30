# Running it on a DE10-Nano — the build, the deploy, and the three ways to look

Everything this project claims about the machine's behaviour comes from
Verilator. A Quartus fit adds one more claim — that the design is *buildable* —
and nothing else: it checks wiring, not behaviour. This document is the loop
that closes that gap, and it is deliberately built to be as observable as the
simulator is.

`docs/18-mister-integration.md` is the top level itself and the list of what is
known to be missing. Read it first. This is how to put a build on a board and
watch what it does.

## The three scripts

```sh
bash scripts/build.sh                 # the whole Quartus flow, ~45 minutes
bash scripts/hwcheck.sh --tag splash  # reset state, deploy, launch, look
bash scripts/deploy.sh                # games dir + PROM + bitstream + launch
bash scripts/console.sh --seconds 90  # the machine's serial console, live
bash scripts/grab.sh out.png          # what is on the screen right now
```

`scripts/hwcheck.sh` is the one to reach for during bring-up: it resets the
board's hidden state, sets the OSD options, launches, waits, and then takes
both views of the result.

**RESETTING THAT HIDDEN STATE IS NOT OPTIONAL AND IT IS WHY hwcheck EXISTS.**
DDR3 survives a core reload and a warm reboot of the HPS, so two things carry
over from the last run and both have already caused a wrong conclusion:

* the **frame buffer**, which makes a stale picture look like a working
  display — `fb_poke.py fill 0xE7` marks it;
* the **guest's main memory**, which is worse, because the machine boots on it.
  The MC's GIO DMA engine is a stub, so the PROM's own memory clear moves
  nothing. A machine that had drawn its whole boot screen sat dead at
  `rex3Clear` for an evening on a bitstream that was md5-verified three ways;
  zeroing memory brought it straight back. `memclear.py` does that, and
  `hwcheck.sh` runs it before every launch.

A launch that skips either of those is not measuring the build.

All machine configuration — host, ssh key, Quartus path, which `_` folder the
core goes in — lives in `scripts/local.env`, which is **gitignored**.
`scripts/local.env.sample` is the committed template. Nothing in this
repository names a machine.

The deploy path needs the **MiSTer Remote** script (mrext) running on the
device, which is what answers on port 8182, and an ssh key that reaches it as
root.

## What has to be on the SD card, and why one of them is easy to miss

```
/media/fat/_Computer/SGIIndy.rbf      the core
/media/fat/games/SGIIndy/boot.rom     the PROM
```

**MiSTer does not create the games directory for you.** `prefixGameDir` in the
framework (`file_io.cpp:1145`) only *computes* `games/<CoreName>`; the
`FileCreatePath` call next to it is commented out. A missing directory is
therefore not an error anywhere — it is silently an absent PROM, and the
symptom is a machine executing whatever DDR3 powered up with. `scripts/deploy.sh`
runs `mkdir -p` before it pushes anything, which is also its connectivity check.

`<CoreName>` is **CONF_STR's first field**, not the filename: `"SGIIndy;;"` in
`sgiindy.sv`. Rename that and the PROM stops being found.

`boot.rom` is pushed on **every** deploy and md5-verified. It is firmware, not
state; there is nothing in it to preserve. The `--seed-*` machinery in
`tools/misterdeploy/` is for the day `docs/17-nvram-persistence.md` lands and
there is something that *is* state.

## The three ways to look

A bring-up needs to be able to tell "no video" from "no machine", and a
screenshot alone cannot. There are three independent views and they fail
differently:

### 1. The screen — `scripts/grab.sh`

The mrext screenshot API captures the scaler's output. With **Graphics board:
Fitted** (the default) the PROM finds Newport, moves the console into the frame
buffer and draws the Indy splash, so this is the whole of the machine's output.

`grab.sh` will not hand you a stale frame: it notes the newest screenshot,
asks for a new one, and only reports success when a file with a later timestamp
appears. A stale frame of the *previous* core is exactly the picture that makes
a dead bring-up look like a working one.

### 2. The serial console — `scripts/console.sh`

**The core's UART is a real tty on the ARM side.** `sys_top.v` wires
`UART_TXD/RXD` to `cyclonev_hps_interface_peripheral_uart`, so the SCC's tty1
arrives as `/dev/ttyS1` on the HPS — not as pins on the user port. Over the
same ssh connection everything else uses, that makes the hardware console
exactly as readable as the simulator's, which is the single most useful fact in
this document.

Two rules:

* **Bring it up with "Graphics board: None".** Fitting the board moves the
  console off the SCC entirely — ARCS installs a DisplayController with
  `ConsoleOut|Output` — so with graphics fitted this capture is correctly
  empty.
* **The baud rate changes mid-boot.** The PROM opens the console at 9600 and
  then announces `diagnostic baud rate set to 19200`. A capture pinned to one
  rate gets either the banner or the rest of POST, not both. `--baud` picks.

The script runs `uartmode 0` first, because MiSTer parks `pppd`, `agetty` or
`midilink` on that tty depending on the OSD's UART setting, and two readers on
one tty each get half the bytes.

### 3. The core is running at all — the launcher's `coreRunning` check

`launch_unstable_core.py` drives the main-menu OSD blind (the screenshot API
does not capture the OSD) and then verifies against the `coreRunning`
broadcast. A missed keystroke selects the *adjacent* core, which is a much more
confusing failure than launching nothing, so this check is not optional; it
retries once on a miss.

## What to expect, and what to do about it

`docs/18-mister-integration.md` has the full list. The three that decide the
first ten minutes:

1. **If it executes garbage from the very first fetch, invert the PROM
   download's byte swap in `sgiindy.sv`.** That is the one thing in the whole
   path that is reasoned rather than measured — `hps_io`'s WIDE byte order
   within `ioctl_dout`. Everything else in the boot has been simulated.
2. **The refresh is about 28 Hz.** VC2 divides `clk_sys` and the PROM's table
   was written for a 107.5 MHz pixel clock. That is judder on a mostly-static
   screen, not a fault. A second clock domain is the fix and it is the top of
   the list in `docs/08-resume-prompt.md`.
3. **`NVRAM checksum is incorrect: reinitializing.` on every boot** is
   expected. Nothing persists yet.

## Reading a failure

The order that costs least:

| Symptom | Look at |
|---|---|
| Menu never leaves | `coreRunning` from the launcher; then the rbf's md5 on the device |
| Core runs, screen black, console silent | The PROM: `ls -l /media/fat/games/SGIIndy/boot.rom` on the device. Then the byte swap |
| Console prints garbage, not text | Baud. Then the byte swap |
| Console prints the banner and stops | Compare with `tests/run-prom.sh` under Verilator at the same point — the harness names the address being hammered with `--stuck` |
| Screen shows something, but wrong | `tests/run-rex3.sh`. A picture is not a test; print what the engine was asked to draw |
