# Work item: the R4600 CPU swap, then the CD-ROM attach, the burst fill path, Ethernet

Paste everything below the line as the opening message of a fresh session.
This follows [37](37-resume-cd-attach-fill-burst-cpu.md) and the evening
session of 2026-09-02 recorded in [36 section 5](36-scsi-fit-fb-relayout.md):
build 18b verified and closed with numbers, the VC2 line-numbering bug found
and fixed (build 19, verified on the board), the simulator's memory-lane
alignment bug found and fixed, and the queue reordered by the user: the R4600
first. Written 2026-09-02.

---

## STATE AT HANDOFF (read this first)

* **`main` is at `7467df8` or later.** The evening session's commits, in
  order: `716759f` the VC2 fix, `9a0ea66`/`e8b737d`/`7467df8` docs,
  `e1540e4` run-newport's row-for-row check (`tests/vidshift.py`), `826cbec`
  the simulator memory-model alignment fix + run-rex3's bar at 3000. The user
  pushes from his own environment.
* **Build 19 is on the board and VERIFIED** (`716759f` RTL, fitter seed 2, rbf
  md5 `aa74e33c09a90bc64779595b693fe869`, a copy in
  `output_files/sgiindy-b19-seed2.rbf`; `output_files/sgiindy.rbf` is the
  seed-3 refit, which is WORSE on the HDMI domain, -0.248 vs -0.162 ns, and
  was not deployed). Verified: store and screen edges on the same rows,
  bottom row lit, `lcache:` misses 0 at the chooser and on the desktop,
  cursor drawn on screen row 0, root login, clean `init 0`. The one blemish
  is the MiSTer scaler's HDMI PLL domain missing by 0.162 ns; every core
  clock meets. Build 18b (`7685736ba4794f453761c52664219d76`) is the fallback.
* **The board was left at the root desktop of build 19.** Before ANY
  redeploy: pointer onto the Console (x 25..425, y 260..650, pointer-focus),
  type `init 0`, Enter, wait for "Okay to power off the system now". A
  power-cut costs a 5-10 minute fsck on the next boot.
* **All four whole-machine ratchets pass on `main`** with the aligned memory
  model: run-prom, run-newport (now with `vidshift.py`), run-rex3 (3718
  commands, every one of 1,310,720 pixels matching), run-scsi. Re-run ALL of
  them after every RTL or harness change - run-rex3 had been failing since
  `30bab9e` because only the "related" ones were re-run.
* Read the auto-memory notes first: `vc2-line-numbering-off-by-one`,
  `sim-memory-lane-alignment`, `cpu-throughput-measured`,
  `display-fetch-path-board-only`, `shutdown-hang-kdsp-audio`,
  `indy-desktop-input-recipe`, `mister-main-death-instruments`, plus the
  older `newport-vdma-pixel-path`, `hardware-bug-instrument-first`,
  `local-toolchain`, `verilator-whole-machine`, `iris-oracle-local`,
  `quartus-ram-inference`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly** (a session may start in a worktree on a `claude/*` branch: commit
there, then `git -C C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only
<branch>`; fits run from the main checkout with `SEED=2`). The reference
emulator IRIS is `C:\Temp\mistercore\iris`. A fit is ~40 minutes. Another
Claude session on this box fits `MacQuadra800` (`ListAgents` shows it as
`macquadra800-mister-ac`); the agreement of 2026-09-02 is: no launch while
the other project's quartus is listed (`tasklist | grep -i quartus`), and
match a process's command line before touching it - the "silent fitter
death" of the first build-19 fit was that session's `Stop-Process`, not a
collision. The board is a SuperStation1 (not a DE10-Nano); its MiSTer
binary is a fork.

## The queue

### 1. CPU: the R4600 from Killer Instinct (the user moved it to the front)

**Why.** `cpu-throughput-measured`: the sluggishness is the 36-cycle L1
miss with no L2 - Count rate and the store path are fine. The R4600 is what
an Indy actually shipped with (no L2 by design), and Killer Instinct's core
has 2-way (to be confirmed) 16 KB caches with 32-byte lines against our
direct-mapped 16-byte ones.

**What is where.** Ours: `rtl/cpu/r4300/` (vendored N64 R4300i, VHDL, ~20
`-- SGI:` changes listed in `rtl/cpu/r4300/UPSTREAM.md`),
`rtl/cpu/r4300_wrap.vhd` (the entity `sgi_indy.sv` instantiates; feeds `clk`
to clk1x/clk93/clk2x and `ce` to both ce ports; DATACACHETLBON=1,
DISABLE_BOOTCOUNT=1), `rtl/cpu/r4300_bus.sv` (fills answered from ordinary
SGI bus reads), `rtl/cpu/prim/` (behavioural altdpram/altsyncram/mult
replacements). Theirs:
`C:\Temp\mistercore\Arcade-KillerInstinct_MiSTer\rtl\cpu\`: `cpu.vhd`,
`cpu_cop0.vhd`, `cpu_TLB_instr/data.vhd`, `cpu_FPU*.vhd`,
`cpu_instrcache.vhd`, `cpu_datacache.vhd` (512 lines x 32 bytes:
`tag_addr(13 downto 5)`; a write-back cache with dirty lines - read its
fill/writeback comments before touching it), `cpu_mul.vhd`, `divider.vhd`,
`dpram.vhd`, `RamMLAB.vhd`, `SyncFifoFallThroughMLAB.vhd`, `functions.vhd`,
`export.vhd`. Its `cpu` entity has the same `mem_*`/`rdram_*`/`ddr3_DOUT*`/
`SS_*` port set as ours plus generics (`LITTLE_ENDIAN` false by default,
`ADDR32_ONLY`, `NO_TRAP_INSTR`, `INSTR_KSEG_ONLY`, `DEBUG_TRACE`,
`BOOT_QUIET_BITS`), extra inputs (`DATACACHEWRITETHROUGH`, `ALECK64`),
`irqRequest(1:0)` where ours has `irqLines(4:0)`, and a `debug_*`/`error_*`
set where ours has nine `dbg_*`.

**The plan, in order - each step has a gate, do not skip one.**

1. Copy the KI files to `rtl/cpu/r4600/` with their own `UPSTREAM.md` (source
   commit, licence). Do NOT touch `rtl/cpu/r4300/` - it stays the fallback
   and the diff base.
2. Re-apply the SGI change list from `rtl/cpu/r4300/UPSTREAM.md` onto the
   R4600 files, one table at a time, each marked `-- SGI:`: the corrections
   (nested exceptions preserve EPC/BD; FP load/store alignment faults;
   AdEL/AdES by direction; opcode 0x33 reserved; the four FPU NaN/zero
   fixes), the presentation (PRId - an R4600 is 0x2020, which KI already
   reports, so check what IRIX and the PROM do with it before choosing
   between 0x2020 and the 0x0440 we present today; FIR; **48 TLB entries** -
   check whether the R4600 files still have 32, IRIX writes indices to 47;
   Config's cache geometry must now say 16 KB/32-byte, which is TRUE for
   this core; COP2 unusable; the MIPS IV COP1 codes), the machine-size fixes
   (no 29-bit physical truncation; the kseg strip on the unmapped fetch path
   and reset PC), the cache changes (the `mem1_addrCompare` tag; `CONFIG_K0`
   export; KSEG0 cacheable iff K0 /= 2), and the five interrupt lines
   (`irqLines(4:0)` -> `Cause.IP(6:2)` every cycle, preNMI tied low). Some
   of these may already be fixed upstream in KI's newer code - check each
   against the R4000 manual rather than porting blindly.
3. A second wrapper, `rtl/cpu/r4600_wrap.vhd`, from `r4300_wrap.vhd`, with the
   same nine `dbg_*` outputs (the beacon and `tb_cpuonly` need them) mapped
   from KI's `debug_*` where they exist and derived where they do not. Keep
   `r4300_bus.sv` - a 32-byte line is four 64-bit beats instead of two, so
   check its burst/beat count is a parameter, not a constant.
4. Regenerate the Verilator lowering: `tools/gen_r4300_verilog.sh` (GHDL,
   6-9 minutes, the LLVM shim from `local-toolchain`, CHECK THE OUTPUT
   TIMESTAMP) pointed at the new files, then `make -C verilator cpuonly`:
   `tb_cpuonly` is 364 checks in seconds and is the A/B instrument. Then
   `tests/run-cputest.sh` (the 240-test MIPS III/IV suite; today 2161 checks
   passed / 3 failed, the only failing test `fpu/vec_cvt_from_l`) - the new
   core must not lose a single passing check.
5. The whole machine: `make -C verilator cputest` then ALL of run-prom,
   run-newport, run-rex3, run-scsi (LF copies under WSL). Expect the boot to
   reach the same points; `run-scsi`'s hinv is the "IRIX-level" check the
   sim can afford (a full IRIX boot is 20-28 minutes in the sim and worth
   doing once: `verilator-whole-machine`).
6. Fit (`SEED=2`), deploy over a cleanly halted IRIX, and measure: the
   `bench` group of `tests/hw-cputest` (`tests/run-cputest-hw.sh --no-build`,
   `cpu-throughput-measured`): `ld_miss` at 36 cycles a miss is the number
   to beat, `i_cached`/`st_cached` at 1.0 CPI must not regress. Then the
   desktop: login, toolchest menus, `init 0`. `bcnread.py`'s `cpu:` word
   still has to decode - the beacon takes `dbg_pc`/`dbg_cop0` from the
   wrapper.

**Traps to expect.** The KI core targets a 93 MHz-class clocking with
`clk2x`; we feed one clock to all three, as today - check every `clk2x`
domain crossing in the cache files (`fill_line_2x`, `fill_beat_2x` in the
data cache) still means "same clock". `LITTLE_ENDIAN` must stay false. The
`SS_*` savestate ports are unused - tie them as `r4300_wrap.vhd` does.
Quartus RAM inference: `quartus-ram-inference` lists the array shapes that
silently became flip-flops before; watch the "uninferred RAM" list in the
build console (today: 6 instances, all known).

### 2. IRIX does not attach the CD-ROM (the CD install blocker)

`hinv -c disk` lists no CD-ROM, `/CDROM` is empty, and the beacon's last
command to ID 6 after INQUIRY (alloc 64, 54 returned) is a 12-byte MODE
SELECT - READ CAPACITY is never issued. Same on builds 15, 16 and 19, so it
is not the docs/29 fixes. Ruled out: the kernel's `cdrom_inquiry_test`
(substring match for CDROM/CD-ROM/CD ROM; ours passes). Leads, in order:

* Simulate dksc's attach sequence in `tests/scsiwr` (INQUIRY alloc 64,
  MODE SELECT(6) with the 8-byte block descriptor setting 512-byte blocks,
  then whatever the kernel sends next) and look at the completion status
  the initiator reports for the MODE SELECT - `917dce7`'s S_DISCONNECT
  (0x85) on ST_SAT_END is a candidate if the target goes bus-free early.
* Disassemble `dkscinit` (0x880aad10) / `dksc_unit` (0x880ae4f0) in
  `unix.ecoff` (`ecoffsyms.py`, `disbin.py`) for what it expects after MODE
  SELECT; compare with IRIS (`src/scsi.rs`: Sony CDU-76S, 36-byte INQUIRY,
  `exec_mode_select_6` switching the block size).
* `scsicontrol` from the guest console is safe now (no audio driver since
  build 18); keep console lines short all the same.

### 3. Rasteriser fill speed: a burst-WRITE path

DR_FILL is still one pixel per `fbw` transaction, tens of cycles each. With
two pixels to a 64-bit word a span cache can emit one write per pair, and a
burst-write port on `ddr3_mux` (the `fbr` burst port is read-only) would
make a span one bridge transaction. `tb_rex3` (`REX3_ACK_DELAY=40`) is the
gate; `run-rex3` the replay check (it passes again as of `826cbec`). Beacon
word 13 counts REX3 beats. Remember `np_rex3` addresses 32-bit slots and
relies on byte enables to pick the half of the word - a burst-write port
must keep that contract or write both halves explicitly.

### 4. Ethernet (docs/35 item 5, unchanged)

Honest carrier first: Seeq 8003 at HPC3 0x54000 is an unclaimed hole;
`ec_watchdog` reads 80C03 read-mode reg 5 NO_CARRIER (the desktop console
prints `ALERT: ec0: no carrier` every 30 s today). Then the RX/TX rings.

### 5. Audio, eventually

HAL2 reports "absent" (bit 15) because the kdsp_a2 driver wedges on a HAL2
with no DMA engine. Real audio = the HPC3 PBUS DMA channel + a sample
pipeline; only then clear bit 15 again. `run-scsi`/`run-cdrom` stop on the
`cdrom(6)` hinv line now.

## Instruments (all present, all proven)

* `bcnread.py` ver=8 (16 words); word 15 = `lcache:` - read it with rapid
  `--raw` samples and factor the deltas: multiples of 1318 are whole lines,
  and misses/1318 a second is the frame rate (27.9 Hz).
* `tests/vidshift.py` (in run-newport): the raster shows the store row for
  row. On the board the same check is `fbgrab.py` row transitions against
  `scripts/grab.sh`'s.
* `tb_vc2` (now checks the first visible line is row 0), `tb_fetcharb`,
  `tb_linecache`, `tb_rex3`, `tb_cpuonly` (the CPU A/B instrument).
* The PROM's VC2 timing tables decode straight from the ROM image with the
  docs/16 run format (docs/36 section 5 has the scanner's rules).
* Kernel forensics at zero fit cost: beacon PC -> `ecoffsyms.py unix.ecoff
  syms` (K0) or, for K2 addresses, `kptbl` (K0 0x881ec000) entry -> PFN ->
  `guestmem.py` -> `disbin.py`, then byte-search the module .o pulled with
  `efsread.py` (`/usr/cpu/sysgen/IP22boot/`).
* The framework: `gdb -p $(pidof MiSTer) -batch -ex "bt 8"`; its stdout in
  `/tmp/mister_stdout.log` after the dup2 trick (survives `load_core`, not
  a reboot); `mwatch.sh` on the board in `/media/fat/sgidbg`.
* Input: root login is `text:root` + Enter at the chooser; `xset m 0 0` in
  the console; <= 40 px mouse steps; `ws_send.py` types shifted keys. There
  is NO held-button message in the ws API (`mouseBtn:` is a click), so a
  title-bar drag cannot be scripted; 4Dwm has no keyboard move bound.
* `fbgrab.py` (4 B/px) + `fbpng.py`; `fb_poke.py` zeroes the aux region;
  `scripts/grab.sh` for the monitor. Always both.
* Post-fit: `deploy.sh --no-launch`, then `mount.sh` (no arguments keeps the
  saved disks) to launch through `/dev/MiSTer_cmd`.
* Other sessions on this box: `ListAgents` / `SendMessage` reach them.

## Traps paid for (do not re-pay)

* Everything in docs/35's and docs/37's lists still applies, except that
  the "two fits at once die silently" entry is now known to have been a
  kill from the other session at least once; serialise anyway.
* The simulator's `Memory::write64/read64` now aligns to 8 bytes like the
  hardware; any new harness memory must too. `tb_rex3`'s own model already
  did, which is why it never saw the bug.
* A whole-machine "PASS" is good only for the commit it ran on. Re-run all
  four ratchets. `tests/run-*.sh` are CRLF: under WSL run copies with the
  carriage returns stripped, made inside `tests/`, and
  `make -f <stripped copy of verilator/Makefile>`; delete the copies
  afterwards.
* The `--fbdump` store is taken at the END of the run, the `--viddump` frame
  is the last COMPLETE one: the two differ by whatever was drawn in between
  (the PROM's logo lands late; 104M cycles gets it into the frame, 90M does
  not).
* Python on this box is the Windows one: give it `C:/...` paths, not `/c/...`.
* A unit test can pass while the board fails only when the test's model
  differs from the hardware's contract - when a unit test and the board
  disagree, read the contract (`r4300_bus.sv` documents the bus one) before
  the RTL.
