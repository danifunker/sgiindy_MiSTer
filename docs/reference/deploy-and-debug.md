# Deploying to a DE10-Nano, and debugging on the board

The simulator says what the RTL does ([simulation.md](simulation.md)). A
Quartus fit adds one fact — that the design builds and meets timing — and
nothing about behaviour. The board is where DDR3's latency, the scaler and the
whole of IRIX are real, and this is the loop for it: build, deploy, launch,
and the ways to look at a machine whose console is its own frame buffer.
[mister-integration.md](mister-integration.md) is the top level being
deployed.

## Setup

All machine configuration lives in `scripts/local.env`, which is
**gitignored**; `scripts/local.env.sample` is the committed template, and
nothing in this repository names a machine.

```sh
cp scripts/local.env.sample scripts/local.env && $EDITOR scripts/local.env
```

| variable | in the sample | what it is |
|---|---|---|
| `MISTER_HOST` | `MiSTer.local` | the MiSTer to deploy to |
| `MISTER_SSH_KEY` | `$HOME/.ssh/mister` | an ssh identity that reaches it as root |
| `MISTER_SSH_USER` | `root` | |
| `MISTER_HTTP_PORT` | `8182` | the mrext MiSTer Remote API |
| `MISTER_CORE_FOLDER` | `_Unstable` | the top-level `_` folder the core is pushed into and launched from |
| `QUARTUS_BIN` | `/c/intelFPGA_lite/17.0/quartus/bin64` | Quartus Prime Lite 17.0's binaries, for `scripts/build.sh` |
| `PROJECT_NAME` | `sgiindy` | the Quartus project |
| `RBF_NAME` | `sgiindy.rbf` | Quartus's output, in `output_files/` |
| `RBF_REMOTE` | `SGIIndy.rbf` | the name the core is filed under on the MiSTer |
| `MISTER_GAMES_DIR` | `SGIIndy` | where the framework looks for `boot.rom`; must match CONF_STR's first field |

`MISTER_RBF_PATH` is not in the template: it is set for a run, and names a
bitstream staged somewhere other than the card (see *Deploying*).

**Keep the core folder small while developing.** The launcher selects the core
by walking the main menu blind — the screenshot API does not capture the OSD —
and every row is one more keystroke that can be dropped. A folder holding only
the core under test is one `down`; `_Computer` is about fifty-five.

**On the MiSTer:** the MiSTer Remote script (mrext) running, which is what
answers on port 8182; root ssh with the key above; and `python3`, which the
device-side tools in `tools/misterdeploy/` run under. The scripts copy those
tools to `/media/fat/sgidbg/` as they need them, and most of them import
`/media/fat/sgidbg/ddr3_peek.py` from there.

**On the host:** bash (on Windows, Git Bash — the scripts set
`MSYS_NO_PATHCONV=1` so `/media/fat/...` arguments are not rewritten into
Windows paths), `ssh`, `scp`, `curl`, and Python with `websockets` for the
launcher and `ws_send.py`. `fbpng.py` needs Pillow, `tests/colcheck.py` Pillow
and numpy, `disbin.py` capstone.

## Building

```sh
bash scripts/build.sh [--log FILE]      # SEED=n picks the fitter seed
```

The whole Quartus flow — synthesis, fit, assembler, timing analysis — with
Quartus Prime Lite 17.0.2, about 45 minutes, into `output_files/sgiindy.rbf`,
logging to `build_full.log`. It runs the stages itself rather than
`--flow compile` so that it can check two things a green exit code does not:

- **The register count, between synthesis and the fitter.** An array that
  fails to infer as memory becomes flip-flops silently — Quartus lists the
  arrays it could see and says nothing about the ones it could not — and the
  first symptom is a fit that fails at 291 % of the device twenty minutes
  later. Above `MAX_REGISTERS` (60,000) the script refuses to run the fitter.
- **Uninferred RAM**, the `Info (276014)` family, printed when synthesis
  reports any.

After a successful compile it runs `tools/fit_report.py`, which writes the
reviewable build report into `reports/`: `summary.md` (the bitstream's md5,
size, date and seed; device use; the worst slack of every clock in the setup,
hold, recovery, removal and minimum-pulse-width checks; and where the SGI
machine's logic went, block by block), `resources-by-entity.txt` (Quartus's
per-entity table) and `timing.txt` (its timing summaries). It says `TIMING
FAILED` if any slack is negative. **Commit `reports/` with the release it
describes.**

- **`SEED`.** The HDMI pixel clock's domain, the MiSTer scaler, has sat within
  a fraction of a nanosecond of its constraint on this design, and a missed
  setup there shows as pixels dropped at fixed screen positions. A different
  seed is the remedy. `sgiindy.qsf` keeps `SEED 2`, the seed build 44 met
  timing with.
- **Do not touch `sgiindy.qsf` while a compile runs — `git checkout`
  included.** Quartus watches it, stops with `Error (125085)` if it changes
  underneath, and then rewrites it with everything `sys/sys.tcl` sources
  inlined. Restore it with `git checkout -- sgiindy.qsf` and start again from a
  clean `db/`. Quartus also rewrites `LAST_QUARTUS_VERSION` on every run, a
  one-line diff to discard.
- `scripts/fit_when_free.sh TAG` waits until no Quartus process is running on
  the machine and then runs `build.sh` once, logging to `TAG.log` and
  `TAG.status`; two fits at once each take twice as long. It finds Quartus
  through PowerShell's `Get-Process`, so it is for a Windows host.
- `"$QUARTUS_BIN/quartus_sta" -t scripts/worstpaths.tcl` reports the worst
  setup paths of the fit already in `db/`, then the next ones with an endpoint
  pattern removed (`EXCLUDE`, default `*line_left*`) — which says whether one
  pipeline stage will do, without another fit.

## What has to be on the SD card

```
/media/fat/_Unstable/SGIIndy.rbf        the core: MISTER_CORE_FOLDER / RBF_REMOTE
/media/fat/games/SGIIndy/boot.rom       the PROM, releases/boot.rom
/media/fat/games/SGIIndy/boot1.rom      the Ethernet address, written on the device
/media/fat/config/SGIIndy.s1 .. s3      the saved SCSI mounts (the OSD, or mount.sh)
/media/fat/config/SGIINDY.CFG           the OSD settings (the OSD, or setopt.sh)
```

**MiSTer does not create the games directory for you.** `prefixGameDir` in
the framework (`file_io.cpp:1145`) only *computes* `games/<CoreName>`; the
`FileCreatePath` call next to it is commented out. A missing directory is
therefore not an error anywhere — it is silently an absent PROM, and the
symptom is a machine executing whatever DDR3 powered up with.
`scripts/deploy.sh` runs `mkdir -p` before it pushes anything, which is also
its connectivity check.

`<CoreName>` is **CONF_STR's first field**, not the file name: `"SGIIndy;;"`
in `sgiindy.sv`. Rename that and the PROM stops being found.

`boot.rom` is pushed on every deploy and md5-verified; it is firmware, not
state. `boot1.rom` is six bytes, the machine's Ethernet address
([mister-integration.md](mister-integration.md#downloads-the-prom-and-the-ethernet-address)).

## Deploying

```sh
bash scripts/deploy.sh [--no-launch] [--rom-only] [--rbf FILE] [--rom FILE]
```

1. Refuses an rbf whose `output_files/sgiindy.fit.summary` does not say
   `Successful`, the leftover of a failed fit (and warns if there is no
   summary at all).
2. Creates `games/SGIIndy/` and the core folder on the device.
3. Pushes the PROM — `releases/boot.rom` unless `--rom` names another — to
   `games/SGIIndy/boot.rom`, md5-verified.
4. Writes `games/SGIIndy/boot1.rom` on the device with
   `tools/misterdeploy/mkmac.py`: `08:00:69:12:34` and the MiSTer's own last
   octet.
5. Pushes the bitstream — `output_files/sgiindy.rbf` unless `--rbf` names
   another — to `/media/fat/<MISTER_CORE_FOLDER>/<RBF_REMOTE>`, md5-verified.
6. Launches it with `tools/misterdeploy/launch_unstable_core.py`, which reboots
   the MiSTer to a clean menu, walks the OSD to the core from the live menu
   listing, and verifies against the `coreRunning` broadcast.

`--rom-only` stops after steps 3 and 4; `tests/run-cputest-hw.sh` uses it to
install the CPU test suite as the PROM, and to put the real one back.

**A bitstream does not have to go on the card.** Copy it to `/tmp` on the
device and export `MISTER_RBF_PATH=/tmp/SGIIndy.rbf`, and
`launch_unstable_core.py` (and `mount.sh`) load it through `/dev/MiSTer_cmd`
with `load_core` — no reboot, which would empty `/tmp`, and no OSD walk.
`scripts/regression.sh` works this way. The launcher prefers that variable to
everything else, so unset it before a `deploy.sh` meant to launch the copy it
just put on the card.

**Options without the OSD:** `bash scripts/setopt.sh name=value ...` writes the
core's 128-bit status word into `/media/fat/config/SGIINDY.CFG`, which the
framework reads once when the core starts — so relaunch afterwards. The names
follow CONF_STR: `gfx=fitted|none`, `cache=on|off`, `mem=48|32|64`,
`viddbg=off|raw`, `uartdbg=off|sys|ser`, `scsicache=on|off`. It writes the
whole word, so every option not named — the aspect ratio included — goes back
to its default.

**Disks without the OSD:** `bash scripts/mount.sh [--disk1 PATH] [--disk2 PATH]
[--cd PATH] [--no-launch]` writes the framework's saved-mount records
`config/SGIIndy.s1`, `.s2` and `.s3` — each the path, NUL-terminated and
zero-padded to 1,024 bytes — which the framework mounts at every core start.
Paths must be absolute on the device; a relative one attaches nothing and says
nothing. `--disk1 ""` detaches a slot. Unless `--no-launch`, it then zeroes
main memory, marks the frame buffer and loads the core (`MISTER_RBF_PATH`, or
the copy in the core folder). A disk that attached shows in the PROM's boot
message: with no disk it prints only `Unable to boot; press any key to
continue:`; with a blank one, `Cannot load /sash` first.

## DDR3 survives a reload: reset the hidden state first

DDR3 keeps its contents across a core reload and a warm reboot of the HPS, so
the previous run's frame buffer and main memory are still there when the next
launch starts. Every launch that is meant to measure something resets both:

- **The frame buffer**, because a stale picture looks exactly like a working
  display. `fb_poke.py fill 0xE7` fills the drawing planes' colour index with a
  marker and zeroes the auxiliary region (whose line cache would otherwise take
  old bytes for lines with something on them). A screen, grab or histogram that
  still shows index `0xE7` was not drawn by this boot.
- **Main memory**, because the measurements read state out of it — IRIX's
  `panicstr`, the CPU test suite's log — and the previous run's copy must not
  be read as this one's. `memclear.py` zeroes `0x30000000`–`0x34000000`. It
  was written when the MC's DMA engine was a stub and the PROM's own memory
  clear moved nothing, so a machine booted on the last run's leftovers; the
  engine fills memory now (`rtl/sgi/mc_gio_dma.sv`), and the scripts still
  clear.

`hwcheck.sh`, `mount.sh`, `bootrate.sh`, `irixrate.sh` and `textprobe.sh` do
both before they launch; `tests/run-cputest-hw.sh` zeroes memory. A launch
that skips them is not measuring the build now running.

## The ways to look

Once Newport is fitted the console is the frame buffer, so "no video", "no
drawing" and "no machine" all look like a black screen from outside. These
views fail differently.

### The screen — `scripts/grab.sh OUT.png`

The mrext screenshot API captures the scaler's output — everything from the
frame buffer to the pixel, but never the OSD. `grab.sh` will not hand back a
stale frame: it notes the newest screenshot, asks for a new one, and reports
success only when a file with a later timestamp appears; otherwise it says
`STALE` and exits 3. A stale frame of the *previous* core is exactly the
picture that makes a dead bring-up look like a working one.

### The frame buffer — `scripts/screen.sh`, `fbgrab.py`, `fb_poke.py`

The frame buffer is in DDR3, so the ARM can read it with no part of the
display path involved. `fbgrab.py` (on the device) writes the 1280×1024
colour-index plane to `/tmp/fb.raw`; `scripts/screen.sh [NAME] [--crop
X,Y,W,H] [--scale S] [--mode text|grey] [--full]` runs it, copies the result to
`tests/out/hw/NAME.raw` and renders it with `fbpng.py` — by default the console
band with index 7 inked black on white, the rendering you can read words in.
It expects `fbgrab.py` and `ddr3_peek.py` to be in `/media/fat/sgidbg/`
already.

Against a `grab.sh` capture this brackets the display path: the store right and
the screen wrong is the display; the store wrong is the rasteriser.
`tests/colcheck.py SCREEN.png FB.raw` makes the comparison exact: every
screen column X must show frame buffer column X + 8, the desktop's own columns
([mister-integration.md](mister-integration.md#video-out)). `fbgrab32.py X0 Y0
W H OUT` keeps whole 32-bit slots of both plane sets for a rectangle, for a
pixel that is wrong in a way an index cannot show. `fb_poke.py
bars|ramp|fill N|sig` writes a known picture from the ARM, cutting the display
path in half the other way: if it appears, everything from the frame buffer to
the monitor works. **Video debug: Raw index** in the OSD shows the index itself
as grey with the palette taken out, and a line-cache miss as mid-grey.

### The debug beacon — `bcnread.py`, `prof.py`

`sgiindy.sv` streams 43 status words to ARM physical `0x35800000`
continuously, whatever the guest is doing
([mister-integration.md](mister-integration.md#the-debug-beacon) has the map).
`bcnread.py` on the device decodes a sample: word 0's magic `0xBEC0` and
version say a bitstream with this beacon is loaded, and a moving heartbeat says
it is running now. The rest is the SCSI subsystem, interrupt delivery, the VDMA
engine, the display's line-cache misses (a display that is not being fed shows
here first), `--stats` for the disk-time counters and `--perf` for the
performance counters — two `--perf` readings a workload apart go to
`perfdiff.py` on the host. `prof.py` samples word 10, the PC entering decode
and the stall vector, as a statistical profiler; `profan.py` on the host
attributes the samples to kernel functions with the symbols `ecoffsyms.py`
reads out of `/unix`.

### Guest memory — `ddr3_peek.py`, `guestmem.py`, `alive.py`, `irixstate.py`

`ddr3_peek.py ADDR LEN [-o FILE] [--stats]` reads ARM physical addresses
through an mmap of `/dev/mem` (busybox `devmem` reads zeros from this window —
silently wrong). `guestmem.py ADDR [LEN] [-o FILE]` takes the guest's own
KSEG0/KSEG1 addresses and returns its bytes in its own order; a dump
disassembles on the host with `disbin.py`. `alive.py` compares two samples of
the PROM's stack a few seconds apart — is the CPU executing at all.
`irixstate.py` answers "where is the IRIX boot" in one line: `PANIC` with the
message, from the kernel's `panicstr`; `X-UP` from the frame buffer's index
histogram; or still booting.

### The disk image — `efsread.py` and friends

A SCSI image is an ordinary file on the SD card, readable with the core out of
the loop. `efsread.py IMAGE ls|cat|get|find PATH` reads files out of its EFS
root partition — `/var/adm/SYSLOG`, crash reports, `/unix`. Because the console
is the frame buffer, the disk is also the output channel for commands typed at
IRIX: `hinv.sh` has IRIX write `/hinv.txt`, halts it with `init 0` so the file
is flushed, and lifts the file off the image. `sgivh.py` checks a volume
header, `efsdiff.py` compares a used image with the pristine one it was
restored from, block by block, and `imgdiff.py` separates a write fault from a
read fault by comparing a copy on one image with its source on another. The
[tools' README](../../tools/misterdeploy/README.md) lists the rest.

### MiSTer's own disk I/O — `scripts/diskio.sh`

The core does not read the image itself: it raises `sd_rd`/`sd_wr` and Main,
on the ARM, does the `read()`. So Main's I/O counters and the file offset of
the descriptor it holds the image on show, with no instrumentation in the
core, whether the core is still asking for blocks. Climbing: the disk path is
alive. Frozen: the core has stopped asking, and the fault is in the SCSI RTL.

### The launch — `coreRunning`

`launch_unstable_core.py` drives the main menu blind and then checks the
`coreRunning` broadcast. A missed keystroke selects the *adjacent* core, which
is a far more confusing failure than launching nothing, so the check is on by
default and the launcher retries once.

### The serial console — `scripts/console.sh`

```sh
bash scripts/console.sh [--baud N] [--seconds N] [--out FILE]
```

`sys/sys_top.v` connects the core's UART to the HPS's own UART, so the SCC's
`tty1` is `/dev/ttyS1` on the ARM. `console.sh` runs `uartmode 0` first —
MiSTer parks `pppd`, `agetty` or `midilink` on that tty depending on the OSD's
UART setting, and two readers on one tty each get half the bytes — sets the
rate and reads. With **Graphics board: None** the PROM prints its console there
at 9600 baud and then announces `diagnostic baud rate set to 19200`, so a
capture pinned to one rate gets one part or the other.

**No byte from this core has ever arrived there on the boards used so far.**
The OSD's **UART debug** option is the instrument for that: it replaces the SCC
on the pin with an endless 9600-baud `0x55`, timed from `clk_sys` or from
`sclk`. If the first arrives and the second does not, `sclk` is dead; if
neither arrives, the fault is between the pin and `/dev/ttyS1`. Until it is
settled the board's text comes from the frame buffer, the disk or memory —
`tests/run-cputest-hw.sh` patches the CPU test suite to log into main memory
and reads the log back over ssh.

## Driving the guest

Input goes in through the MiSTer Remote websocket API: `ws_send.py STEP ...`
sends keys (`kbd:`, `kbdRaw:`, `text:`), relative mouse moves and clicks
(`mouseMove:dx,dy`, `mouseBtn:left`) and pauses (`sleep:`). The OSD cannot be
read back, so options go through `setopt.sh` and disks through `mount.sh`
rather than keystrokes into the OSD.

The IRIX recipe the scripts share, on the installed image they use: at the X
login chooser the login-name field has the focus, so `text:root` and Enter
(`kbdRaw:28`) log in with no password prompt. The desktop's Console window
then takes typed commands under a pointer parked by slamming it into the
top-left corner and stepping out from there (the window manager's focus
follows the pointer). Software Manager opens by itself about 30 seconds after a
root login, on top of the Console, and takes the keys until it is quit.
`xset m 0 0` typed into the Console makes mouse deltas one to one; after that
the scripts walk the pointer in small steps, because large relative moves are
not reliable. From launch to the login screen is about a minute and a half on a
pristine image — X was up at +90 s on build 44.

## The measurement scripts

The IRIX scripts expect an installed IRIX 5.3 image at
`/media/fat/games/SGIIndy/SGIIndy53.img`, attached as SCSI ID 1 (`mount.sh
--disk1 ...` once), and a pristine copy of it, `SGIIndy53-pristine.img`, for
`--fresh`. Neither is in the repository. `--fresh` loads the menu core first,
which stops the guest and makes Main close the image, waits until no process
holds it, and copies the pristine image over it in place — renaming a new copy
over an image Main still held open leaked its clusters on the card's exFAT
([cpu-speed-tlb-icache.md](../design/cpu-speed-tlb-icache.md) §8). `--img`
names another image. Everything writes its logs under `tests/out/hw/`.

| script | what it does |
|---|---|
| `hwcheck.sh [--no-deploy] [--no-clear] [--no-memclear] [--wait N] [--tag NAME] [opt=value ...]` | the bring-up loop: resets the hidden state, sets the options, deploys (or relaunches), waits, grabs the screen to `tests/out/hw/NAME.png` and prints a histogram of the frame buffer's colour indices, including how much of the `0xE7` marker survived |
| `bootrate.sh [N] [--no-memclear] [--poison HH]` | launches the diskless PROM boot N times and classifies each ending from the frame buffer: the boot prompt's panel, or a PROM exception box |
| `irixrate.sh [N] [--wait S] [--tag T] [--fresh IMG] [--stats]` | N IRIX boots, each classified `PANIC`, `X-UP` or still booting by `irixstate.py`; `--stats` logs the disk-time counters at every poll |
| `hinv.sh [--fresh IMG] [--out FILE]` | boots IRIX, logs in, runs `hinv`, halts, and reads the output off the image |
| `clockprobe.sh [--fresh IMG] [--gap S] [--out FILE]` | asks IRIX the time twice, `GAP` seconds apart by the host's clock: the date at boot, and whether the clock runs at real speed |
| `diskcheck.sh [--fresh IMG] [--out FILE]` | IRIX checksums files and copies one; `sumcheck.py` compares both with the image itself — DATA IN and DATA OUT |
| `diskstress.sh [--copies N] [--wait S] [--out FILE] [--keep]` | copies `/unix` N times under a directory walk, then `efsdiff.py` looks for any block that changed without a write |
| `cdread.sh --mode on\|off [--mb N] [--tag T] [--fresh IMG]` | reads N MB off the CD-ROM under IRIX with the SCSI block cache on or off |
| `diskpair.sh RBF [--tag T] [--boots N]` | IRIX boots with the SCSI block cache on and then off, logging the disk-time counters |
| `perfprobe.sh [--tag T] [--fresh IMG] [--no-boot] [--skip LIST]` | a fixed set of workloads typed into the Console, each timed by IRIX and profiled by `prof.py` |
| `saverprobe.sh [--tag T] [--fresh IMG] [--no-boot] [--only LIST]` | runs the desktop's screen savers — X's line savers and the GL ones — grabbing the monitor three times through each |
| `textprobe.sh TAG` | fills the Console with known glyphs and pulls both the screen and the frame buffer, for `tests/colcheck.py`; expects the bitstream staged at `/tmp/SGIIndy.rbf` |
| `regression.sh TAG RBF [--cpu] [--disk] [--no-perf] [--perf-skip LIST]` | the board regression for a new bitstream, below |

### `regression.sh`

```sh
bash scripts/regression.sh b44 output_files/sgiindy.rbf --cpu --disk --no-perf
```

It stages `RBF` at `/tmp/SGIIndy.rbf` and exports `MISTER_RBF_PATH`, so the
bitstream is not written to the card and no launch reboots the MiSTer, then:

- `--cpu` runs `tests/run-cputest-hw.sh --no-build`: the CPU test suite, built
  as a 512 KB ROM, runs *as the PROM* and its log is read out of main memory;
  the release PROM goes back afterwards (about 5 minutes). The ROM has to exist
  already at `tests/out/hw-cputest/boot.rom` — `tests/hw-cputest/build.sh`
  makes it from an IRIS `cpu-tests` checkout with a MIPS cross compiler.
- `--disk` runs `diskcheck.sh` on a freshly restored pristine image (about
  13 minutes).
- then `perfprobe.sh` on a restored image (about 20 minutes), unless
  `--no-perf`; `--perf-skip` passes a skip list to it.

After each IRIX boot it lifts `/var/adm/SYSLOG` off the image with `efsread.py`
and prints the SCSI notices in it. The summary is
`tests/out/hw/boardrun-TAG.txt`.

**Measure a control the same session.** The board's own speed has been seen to
change from one session to the next, so a speed comparison runs the previous
release again alongside the candidate before calling a difference a
regression ([cache-fill-latency.md](../design/cache-fill-latency.md)).

## Reading a failure

| symptom | look at |
|---|---|
| the menu never leaves, or the wrong core runs | the launcher's `coreRunning` check; then the rbf's md5 on the device |
| the core runs, the screen is black | `bcnread.py`: the magic and a moving heartbeat say the core is loaded and running. Then `ls -l /media/fat/games/SGIIndy/boot.rom`. Then `screen.sh` / `fbgrab.py`: still `0xE7` means nothing drew; a drawn store means the display — the line-cache misses in beacon word 15, and **Video debug: Raw index** |
| the picture is wrong | the store against the screen: `fbgrab.py` and `grab.sh`, `tests/colcheck.py`. In simulation, `tests/run-rex3.sh` and the Newport benches ([simulation.md](simulation.md)) — a picture is not a test; print what the engine was asked to draw |
| IRIX panics or hangs | `irixstate.py` for the panic message; `alive.py`; `prof.py` samples with `ecoffsyms.py`; `guestmem.py` and `disbin.py` at the PC; `/var/adm/SYSLOG` and crash reports through `efsread.py` |
| the disk stalls or data is wrong | `diskio.sh`; the SCSI words in `bcnread.py`; `diskcheck.sh`; `efsdiff.py` against the pristine image |
