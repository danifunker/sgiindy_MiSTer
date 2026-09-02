# 36. The SCSI fit lands; the frame buffer goes to four bytes a pixel

Session of 2026-09-02, following [35](35-resume-scsi-fit-video-cpu-r4600.md).
Three things happened: the docs/29 SCSI fixes were fitted and put on the
board (item 1), the display's memory demand was halved so the refresh can go
back to one pixel per clock (item 2, RTL written and unit-tested here, fitted
next), and two board-side facts were established on the way - how to reach a
root shell, and that MiSTer's own ARM-side process died under the core once
this session, which is the shape of the "shutdown hang" the user reported.

## 1. The SCSI fit (build 16)

`917dce7` (per-target `sd_lba`/`sd_buff_din`, the mid-CDB timeout, S_UNKNOWN_GROUP
0x87, S_DISCONNECT 0x85) had been sim-verified and never fitted.

* Pre-fit gate re-run at `bf28b26`: `make -C verilator cputest` (model already
  current), `run-scsi` PASS, `run-scsiwr` ALL PASS, `run-cdrom` PASS.
* **Build-15 baseline captured before the fit**, from the board, so that the
  fit has something to be measured against:
  - `/var/adm/SYSLOG` read straight off the mounted image with `efsread.py`
    (it runs on the MiSTer; 0.2 s for the whole file). Every boot logs one
    `NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus` at
    attach, then - about six minutes in, when `mediad` starts polling the
    CD-ROM - bursts of `WARNING: wd93 SCSI Bus=0 ID=6 LUN=0: SCSI cmd=0xc9
    / timeout after 10 sec. Resetting SCSI bus / ALERT: Integral SCSI bus 0
    reset`. 35 of those in the log, 8 sync notices, 511 `ec0: no carrier`.
  - From a root shell (see section 3): `hinv -c disk` lists the WD33C93A and
    `Disk drive: unit 1` and **no CD-ROM at all**. IRIX never registered the
    drive on build 15. That is the acceptance bar for the fit: the CD-ROM
    appears in `hinv`, and the 0xc9 timeouts stop.
* The first fit attempt (`b16.log`) died silently in the fitter after five
  minutes - no error line, the log just stops - the Quartus 17 Lite mid-run
  death from docs/32's list, this time with another core's fit running on the
  same box. Recovery as documented: `db/` moved aside, re-run (`b16b`).
  Synthesis: 39,359 registers, the same six small uninferred RAMs as every
  build since 12.
* Third attempt (`b16c`, the box to itself): Fitter Successful 15:49, worst
  setup slack +0.373 ns (the HDMI PLL, as every build), rbf md5
  `47de3b67c336a5f948eb00a71b43b786`. Deployed with `deploy.sh --no-launch`
  and launched through `/dev/MiSTer_cmd` (`mount.sh`) so the framework's
  stdout capture survived - see section 3.
* **Board result, build 16.** IRIX boots to the chooser (a six-phase fsck
  first, dirty from the framework death). This boot's SYSLOG, read off the
  image: **zero `cmd=0xc9` timeouts, zero bus resets after boot (beacon
  `c_reset` stays at 3), and zero SYNC-negotiation notices** - the last was
  expected to persist and did not. `mediad`'s CD polling no longer wedges
  the bus. That is the payoff the four fixes were for.
* **Still open, newly characterised: IRIX never attaches the CD-ROM.**
  `hinv -c disk` lists only the WD33C93A and the disk on unit 1, `/CDROM` is
  empty, `df` shows only `/dev/root` - exactly as on build 15, so this is
  not a regression. The beacon's last command to ID 6 is the 12-byte MODE
  SELECT that follows INQUIRY (allocation 64, 54 returned); READ CAPACITY is
  never issued. Ruled out: the kernel's `cdrom_inquiry_test` (0x880ae6dc) is
  a substring search for "CDROM" / "CD-ROM" / "CD ROM" and our "CD-ROM
  CDU-8004" passes it (IRIS's oracle answers "Sony CDU-76S", which would
  not, so the test is not the attach gate). Then `scsicontrol -i
  /dev/scsi/sc0d6l0` from the root console **wedged the kernel**: 33 beacon
  samples put the PC in `bzero`'s 32-byte store loop (0x88016f8c..fa0) nine
  times in ten and the rest in mapped kernel text at 0xc00e3a04..a64 - a
  loadable module (the devscsi pass-through, presumably) calling `bzero`
  with an enormous length - with an unmasked LOCAL0 interrupt pending and
  never serviced, the console dead, the framework alive. Next SCSI lead:
  reproduce dksc's attach sequence in `tests/scsiwr` (INQUIRY alloc 64,
  MODE SELECT(6) with the 8-byte block descriptor) and check what completion
  the initiator reports; read `dkscinit`/`dksc_unit` (0x880aad10 /
  0x880ae4f0) for what it expects; then the devscsi ioctl path.

## 2. The frame buffer relayout (item 2) - what changed and why the plan moved

docs/18 section 0 planned "split the planes, the display reads RGB only":
8 -> 4 bytes a pixel, 0.80 -> 0.39 words a clock at `PIX_DIV=1`. Since docs/33
the compositor reads the auxiliary planes for every pixel as well - the popup
bits `aux[3:2]` and the overlay byte `aux[23:8]`, either buffer, per the DID
mode - and the board is 24 planes (CMAP0 revision 0x42, bit 7 clear). So the
display's per-pixel need is 24 + 2 + 16 = 42 bits; two pixels cannot share a
64-bit word, and a 48-bit packing (0.60 w/clk) still misses the 0.52 the
bridge measured. Fetch width alone was not going to do it.

What landed instead keeps every plane and every double buffer:

* **Two regions, four bytes a pixel each.** Drawing planes at `FB_BASE` as a
  32-bit slot `{4'b0, cid[3:0], rgb[23:0]}`; auxiliary planes 8 MB above as
  `{8'b0, aux[23:0]}`. Two pixels to a 64-bit word, the even pixel in the low
  half, selected with the byte enables the mux already honours
  (`np_rex3.sv`, `fb_slot_addr`). IRIS keeps `fb_rgb`/`fb_aux` as two arrays;
  this is that shape.
* **The window-ID nibble is copied into the drawing slot's spare byte.** The
  CID clip compares `aux[3:0]`; a CID-clipped draw into the drawing planes
  (most of what X does under an overlapping window) reads the copy from the
  slot it has to read anyway, so it stays one read + one write per pixel.
  A write that changes byte 0 of an auxiliary slot (popup and window-ID
  planes) pays a second write, `DR_CID`, to refresh the copy. Overlay writes
  (mask 0xFFFF00) do not.
* **The auxiliary planes are almost always empty, so they are almost never
  fetched.** `fb_linecache.sv` grew `TRACK_ZERO`: a 1024-entry flag table,
  one bit per line, "may hold something the compositor can see". The
  rasteriser sets a line's flag when it writes a nonzero overlay byte or
  popup bit into it (`aux_mark`); the auxiliary cache clears it when a whole
  fetched line comes back with nothing under `ZERO_MASK` (0x00FFFF0C per
  slot) and no mark landed during the fetch. A clear flag publishes the line
  as zeros without a fetch. Flags reset to set, so the first frame after
  reset fetches everything and the table settles from what is there.
* **Two caches, one burst port.** `u_linecache` (drawing planes, every line)
  and `u_auxcache` (TRACK_ZERO) behind `fb_fetch_arb.sv`, a strict one-burst-
  in-flight arbiter with the drawing planes at priority. 672 words a line
  each - the same 344 Kbit of M10K the single 1344-word cache used.
* **`PIX_DIV` is 1.** The display's demand on a plain desktop is the drawing
  stream, 0.39 words a clock, plus whatever lines carry a menu.
* Beacon word 15 (ver=8): drawing-plane misses, auxiliary misses, auxiliary
  lines skipped - `bcnread.py` prints it as `lcache:`. Misses are the number
  to watch on the board; skips should be near 1024 a frame on a bare desktop.

Everything that knew the old shape followed: `sim_video_cap.h`'s `--fbdump`
decoder and `sim_devices.cpp`'s PPM dumper (even pixel = bytes 4..7 of its
big-endian word, index at slot byte 3), `tb_linecache.cpp` (now built with
`-GTRACK_ZERO=1`, PIX_DIV=1, four frames: fetch-all, skip, mark, skip again),
`tb_rex3.cpp` (per-byte write tracking; a new check that a popup-plane draw
refreshes the window-ID copy), `fb_poke.py` and a tracked `fbgrab.py` (the
ARM sees the index of pixel x at byte `(y*2048+x)*4`, linear).

Verification so far:

* `verilator --lint-only` clean on `fb_linecache`, `fb_fetch_arb`, `np_rex3`,
  `newport`; the MiSTer top lints with only the framework's own warnings.
  (Lint-only on `sim_top` hits a Verilator 5.020 internal fault on the
  untouched HEAD sources too - the WM_OPT build is the one that works.)
* `make linecachetest`: PASS - 5,396,972 pixels checked over four frames, zero
  wrong, zero misses after frame 0; 6150 bursts in the fetch-everything
  frame, 768 once the flags settled (one line in eight is visible in the
  test's memory), 774 in the frame with the marked line. **It caught a real
  bug first:** the fill walked past line 1023 into the vertical blanking,
  "line 1024" aliased flag 0, fetched memory beyond the frame, found it empty
  and cleared line 0's flag - line 0 went black from frame 1. The fill now
  stops at `LINES`.
* `make rex3test` at acknowledgement delays 8, 0 and 40: PASS, including the
  two new checks (a drawing-plane write leaves the window-ID copy alone; a
  popup-plane draw sets the popup bits and refreshes the copy in every
  drawing slot).
* Whole-machine, rebuilt `cputest` (WM_OPT, an incremental minute): `run-prom`
  PASS, `run-newport` PASS (1318x1065 exact at `PIX_DIV=1`, the video
  capture lit), `run-rex3` PASS (5162 commands replayed, 1,310,720 pixels
  checked, none unchecked), `run-scsi` PASS. Committed as `52f24ef`, fitted
  as build 17 (42,229 registers, worst slack +0.055 ns, block memory 52%).
* **Build 17 on the board: a black screen with one stale line**, the beacon's
  new word showing both caches missing every pixel and no aux line ever
  skipped - while `fbgrab.py` through the new layout showed the console
  picture sitting correctly in the store. So REX3 was right and the fetch
  path was starved, and the fetch path is the one piece `sim_top` never
  exercises (it reads the frame buffer through plain one-cycle memories).
  `tb_fetcharb` was written to close that gap - both caches and the arbiter
  against a bridge that, like `ddr3_mux`, latches a request's address and
  burst the first cycle it sees it and issues them later - and it found
  three things in a row:
  - the arbiter chose its winner combinationally until `fbr_taken`, so when
    the aux cache asked first and the drawing cache a cycle later, the mux
    issued the aux burst while the arbiter credited the drawing cache and
    waited for a word count that never came: both caches dead in their data
    phase, the vsync restart never reached. The selection is latched now;
  - the aux cache took its line number from address bits that include the
    8 MB region offset, so every request looked like line y+1024 and never
    hit, and its fills read the drawing region instead of the aux region -
    the actual cause of the black screen: double traffic starving both
    caches. `REGION_BASE` is a parameter now;
  - the empty-line test looked at all 672 fetched words, but the display
    shows 1318 pixels = 659 words and nothing ever clears the rest of a line
    (the PROM's clear stops at pixel 1342), so leftover bytes beyond the
    visible span kept every line flagged (`VIS_WORDS`). And with the flags
    resetting SET, the first frame fetched both plane sets everywhere and
    the over-subscribed bus starved the aux fills for several frames; they
    reset CLEAR now - every visible aux value reaches memory through the
    rasteriser, which marks its line, so nothing is lost and there is no
    storm. `fb_poke.py` zeroes the aux region as well.
  After those: `linecachetest` PASS, `fetcharbtest` PASS with zero misses in
  every frame including the first and 6912 bursts a frame (6144 drawing +
  the 128 marked aux lines). Fitted as build 18 together with the audio fix.

## 3. Board facts established on the way

* **A root shell is one typed word away.** At the login chooser the
  Login-name field is focused; `ws_send.py "text:root" "kbdRaw:28"` logs in
  with no password prompt, and about a minute later the desktop has a Console
  window with a root prompt at x 25..425, y 260..650. 4Dwm is pointer-focus,
  so park the pointer over it first. `xset m 0 0` typed there makes the ws
  mouse deltas 1:1 for the rest of that X session (measured: 80 requested,
  78 moved). `ws_send.py` now types capitals and shifted symbols (LEFTSHIFT
  held around the key), so `/CDROM` and a pipe are typeable.
* **Large relative deltas are still not safe.** Four moves of -70/-100 landed
  as roughly -115/-110 in total and then the pointer froze - but see the next
  point, the freeze was not the mouse.
* **MiSTer's main process died under the core.** At 14:33 input stopped
  reaching the guest; at 14:34:55 a new `/media/fat/MiSTer menu.rbf` process
  appeared (HPS uptime intact, so not a Linux reboot; `inittab` starts MiSTer
  once at sysinit, so the restart was its own `app_restart` to the menu). The
  menu core then survived the identical mouse deltas, so the deltas do not
  kill the framework by themselves. This board is a SuperStation1 with its
  own MiSTer fork (`strings` shows the upstream "GPI[31]==1. FPGA is
  uninitialized?" / "restarting to %s" messages). The user reports the same
  class of hang when the toolchest's System Shutdown (`/usr/Cadmin/bin/chaltsys`)
  is clicked and its screen-greying draw does not appear.
  Instruments now in place for the next occurrence: the framework's stdout
  and stderr are redirected into `/tmp/mister_stdout.log` (via `gdb -p` and
  `dup2`; a `load_core` switch inherits it, a Linux reboot does not), `gdb -p
  $(pidof MiSTer) -batch -ex "bt 8"` names the syscall a hung framework is
  blocked in, and `mwatch.sh` logs pid/state/wchan once a second.
* Power-cutting the guest is what that restart did, so the boot after the fit
  fscks. Item 6's "log in and `init 0` before redeploying" is now possible
  from the console above.

## 3b. The shutdown hang, found: the audio driver

Reproduced on build 16 with the beacon sampling once a second: toolchest
System -> System Shutdown, the menu closes, the busy cursor appears, and
nothing else ever draws. The CPU sits in `bzero`'s 32-byte store loop
(0x88016f8c..fa0) nine samples in ten, the tenth in mapped kernel text at
0xc00d3a20, with an unmasked LOCAL0 interrupt pending and never taken. The
console had wedged the same way minutes earlier on a garbled command line
(a terminal bell, in hindsight).

Mapped kernel text is not in `/unix`, so the frozen guest's page table was
read from the ARM: `kptbl` (K0 0x881ec000) entry 0xd3 = 0x4028b1df, physical
0x0a2c7000, `guestmem.py` dumped the page, `disbin.py` showed a ring-buffer
zeroing loop - `s1 = min(size - index, remaining)` with a SIGNED compare,
`bzero(ring + index*4, s1*4)`, index wrapping at size, `remaining -= s1`
until zero. A negative `remaining` zeroes for ever. The byte pattern is not
in `/unix` and is in `/usr/cpu/sysgen/IP22boot/kdsp_a2.o` at text offset
0x39e0: **`transfer_samps` of the `kdsp_a2` audio driver**, called from
`kdsp_timercallback`. `/var/sysgen/system/audio.sm` loads that module when
its probe of HAL2_REV at 0xBFBD8020 finds bit 15 clear - which this core
clears so the PROM's POST lists the audio processor - and the driver then
runs against a HAL2 with no DMA engine and no sample path, derives a
negative sample count from the DMA position, and spins with interrupts off
the first time anything plays a sound. The shutdown confirmation plays one;
so does the console bell.

Decision: `hal2.sv` `REV_VALUE` is 0xC010 again - bit 15 set, "no audio
present", the state IRIS models as `hal2_absent_read`. The PROM skips its
HAL2 init, hinv prints no audio line, IRIX never loads `kdsp_a2`. The
register file stays for when the DMA channel and the sample pipeline exist.
`tests/run-scsi.sh` and `run-cdrom.sh` stop on the CD-ROM line now (it is
the last hinv line) and run-scsi forbids the audio line. Sim-verified with
the whole machine: `run-prom` PASS, `run-scsi` PASS, `run-cdrom` PASS (the
PROM boots, lists the disk and the drive, prints no audio line). Fitted as
build 18 together with the fetch-path fixes.

**A timing note, build 18 -> 18b.** Build 18's fit met every clock but the
HDMI PLL domain (the MiSTer scaler), which it missed by 0.176 ns - the same
domain build 17 met by 0.055. `scripts/build.sh` grew a `SEED=n` knob for
exactly this margin; `SEED=2` refit it to +0.616 ns (build 18b, rbf md5
`7685736ba4794f453761c52664219d76`), same RTL. The console text shows a few
thin vertical strokes rounded away by the scaler's 1280-to-HDMI downscale
("cloc<" for "clock"), identical between build 18 and 18b and present on the
known-good builds 15 and 16 - the frame buffer STORE is byte-clean (an
index-plane dump of the boot text reads correctly), so it is a capture/
downscale artifact, not the timing violation and not the relayout. 18b is
the build to keep.

**Verified on the board, build 18:** toolchest System -> System Shutdown
posts its "Power off and set boot time ... Are you sure?" dialog with the
CPU idling (beacon PCs in the idle loop, none in `bzero`), an error dialog
that rings the bell earlier in the same session did not freeze anything,
and clicking Ok shut IRIX down cleanly back to the PROM - the first clean
shutdown this board has had, so the next boot fscks nothing.

## 4. Item 4 scoping, from reading rather than guessing

The current CPU is the vendored N64 R4300i (`rtl/cpu/r4300/`, UPSTREAM.md
lists every local change). Killer Instinct's `rtl/cpu/cpu.vhd` has the
identical `mem_*` / `rdram` / `ddr3_DOUT` / `SS_*` port set, plus generics
(`LITTLE_ENDIAN` false by default, `ADDR32_ONLY`, ...) and a `debug_*` set in
place of our nine `dbg_*`. Its caches fill 32-byte lines (four 64-bit beats)
over 512 lines = 16 KB; the associativity claim still needs the tag compare
read. PRId constant 0x2020. So `r4300_wrap.vhd` and `r4300_bus.sv` carry over
and the work is re-applying the SGI change list to the R4600 files.
