# Work item: after the burst fills - the CD-ROM attach, the burst-write path, Ethernet, and a bigger data cache done properly

Paste everything below the line as the opening message of a fresh session.
This follows [39](39-burst-fills-dcache.md), the session of 2026-09-02/03
that assessed the R4600 swap, built burst line fills instead, tried two
16 KB data caches that both killed IRIX's init, and shipped build 21 with
the original 8 KB cache and one-round-trip fills. Written 2026-09-03.

---

## STATE AT HANDOFF (read this first)

* **`main` is at `62be253` or later** (the burst fills, the shift-lowering
  fix, the 8 KB decision), plus the docs commit after it. The user pushes
  from his own environment.
* **Build 21 is on the board and VERIFIED**: commit `62be253`, fitter seed
  2, rbf md5 `5f02393b96f9e1361d5b6da6ed7b2a93`, a copy in
  `output_files/sgiindy-b21-seed2.rbf` of the worktree it was fitted from
  (`.claude/worktrees/modest-robinson-cad59e`; the main checkout's
  `output_files/` still holds build 19's). Every clock met (HDMI PLL domain
  +0.080 ns, core +2.772). Bench: `ld_miss` 13 ticks = 26 cycles for a
  16-byte line (build 19: 36), everything else identical. IRIX boots to the
  root desktop, the toolchest menus post, `init 0` halts it cleanly. Build 19 (`aa74e33c...`, in the main checkout's
  `output_files/sgiindy-b19-seed2.rbf`) is the fallback.
* **The board was left HALTED ("Okay to power off the system now") on
  build 21**, disk image `SGIIndy53-wedged-fsck.img` in slot 1, cleanly
  unmounted. Before ANY redeploy: pointer onto the
  Console, type `init 0`, Enter, wait for "Okay to power off the system
  now". The pointer walk is scripted in docs/39's traps and the
  `indy-desktop-input-recipe` note (slam to the corner, then aim for the
  window centre with the deltas divided by ~1.8; the 1:1 `xset m 0 0` was
  NOT in effect).
* **The IRIX boot in the simulator is now a gate**, and the only one that
  caught the two dead caches: `verilator/obj_dir/Vsim_top --prom
  roms/IP24_Indy/ip24prom.070-9101-011.bin --no-gfx --disk
  1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img --max-cycles 450000000
  --stuck 250000000 --type-on 'Option?' '1\r' --stop-on PANIC --console F`,
  ~45 minutes to the cycle limit at ~175k cycles/s, init at ~190M cycles.
  Run it before any fit that touches the memory hierarchy, with
  `--no-dcache` as the control and `--ramdump 0x88000000:0x4000000:F` for the
  post-mortem.
* All four whole-machine ratchets, `run-cputest` (2160/3, only
  `fpu/vec_cvt_from_l`), `cpuonly` (728/0), `ddr3test`, `ramarbtest`,
  `fetcharbtest`, `linecachetest` pass on `62be253`.
* Read the auto-memory notes first: `irix-hardcodes-dcache-line`,
  `ki-r4600-core-assessed`, `cpu-throughput-measured` (updated), plus the
  older `local-toolchain` (now with the GHDL 4.1 signed-shift trap),
  `verilator-whole-machine`, `vc2-line-numbering-off-by-one`,
  `sim-memory-lane-alignment`, `display-fetch-path-board-only`,
  `shutdown-hang-kdsp-audio`, `indy-desktop-input-recipe`,
  `mister-main-death-instruments`, `newport-vdma-pixel-path`,
  `hardware-bug-instrument-first`, `iris-oracle-local`,
  `quartus-ram-inference`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly** (a session may start in a worktree on a `claude/*` branch: commit
there, then `git -C C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only
<branch>`; a fit runs fine from the worktree too once `build_id.v`, `roms/`
and `tests/disks/` are copied in, `SEED=2`). The reference emulator IRIS is
`C:\Temp\mistercore\iris`. A fit is 20-40 minutes. Another Claude session on
this box fits `MacQuadra800`; no launch while its quartus is listed
(`tasklist | grep -i quartus`). The board is a SuperStation1; its MiSTer
binary is a fork.

## The queue

### 1. IRIX does not attach the CD-ROM (the CD install blocker) - unchanged from docs/38

`hinv -c disk` lists no CD-ROM, `/CDROM` is empty, and the beacon's last
command to ID 6 after INQUIRY (alloc 64, 54 returned) is a 12-byte MODE
SELECT - READ CAPACITY is never issued. Leads, in order: simulate dksc's
attach sequence in `tests/scsiwr` and look at the MODE SELECT completion
status (`917dce7`'s S_DISCONNECT 0x85 on ST_SAT_END is a candidate);
disassemble `dkscinit` (0x880aad10) / `dksc_unit` (0x880ae4f0) in
`unix.ecoff` (`ecoffsyms.py`, `disbin.py`); compare with IRIS's
`src/scsi.rs` (`exec_mode_select_6`). `scsicontrol` from the guest console
is safe (no audio driver since build 18).

### 2. Rasteriser fill speed: a burst-WRITE path - unchanged from docs/38

DR_FILL is one pixel per `fbw` transaction. Two pixels to a 64-bit word and
a burst-write port on `ddr3_mux` would make a span one transaction. The
read side now has the shape to copy: `ram_burst`/`ram_last` on the RAM
port, `burst_left` acking per word. `tb_rex3` (`REX3_ACK_DELAY=40`) is the
gate; `run-rex3` the replay check. `np_rex3` addresses 32-bit slots and
relies on byte enables.

### 3. Shave the miss further

26 cycles for a 16-byte line is the DDR3 trip (~17-19) plus the handshake
either side: cpu.vhd's write FIFO, `r4300_bus` S_IDLE, `ram_arb`,
`ddr3_mux`'s latch-then-issue (two clocks), `S_FILLEND`'s daylight clock,
the cache's `ram_done` path. Each is a clock or two; `tb_cpuonly` counts
requests and acks and `ld_miss` on the board is the number. Do not touch
the `S_FILLEND` clock without re-reading `r4300_bus.sv`'s ordering note.

### 4. A bigger data cache, done properly

Not a geometry tweak (docs/39 section 3b, `UPSTREAM.md`). Two designs
survive the analysis: **physically indexed** - `cpu_TLB_data.vhd`'s
`TLB_AddrOutFound` is combinational in the execute cycle, so index bits
13:12 can come from it when `EXETLBMapped`, but the tag read on a mini-TLB
miss must be redone after the walk (extend `ce_fetch` to the unstall clock
and use `TLB_dataAddrOutLookup` there) - or **two-way with 8 KB ways**,
which is the real R4600's shape and why IRIX's R4600 path colours on one
bit. Either way the line stays 16 bytes under PRId 0x0440 (IRIX hard-codes
it). Gate with `run-cputest`'s cache and tlb groups, then the IRIX boot in
the simulator, then the board.

### 5. Ethernet (docs/35 item 5, unchanged)

Honest carrier first: Seeq 8003 at HPC3 0x54000 is an unclaimed hole;
`ec_watchdog` reads 80C03 read-mode reg 5 NO_CARRIER (the desktop prints
`ALERT: ec0: no carrier` every 30 s and pops a dialog). Then the RX/TX
rings.

### 6. Audio, eventually - unchanged

## Instruments (all present, all proven)

* Everything in docs/38's list.
* `tests/run-cputest-hw.sh --no-build`: the `bench` group on the board.
* The IRIX boot in the simulator, above; `tools/misterdeploy/efsread.py
  IMAGE get /sbin/init F` (with `MSYS_NO_PATHCONV=1`) + a Python ELF
  header walk + `disbin.py` for user-space code; the harness's
  `--pc-user`, `--exc --exc-count N`, `--ramdump`.
* `ecoffsyms.py unix.ecoff syms` + `disbin.py` on the kernel's cache
  routines: `config_cache` 0x88003280, `__dcache_inval` 0x88002908,
  `__dcache_wb_inval` 0x88002ccc, `color_validation` 0x880486d0.

## Traps paid for (do not re-pay)

* Everything in docs/38's and docs/39's lists. The ones that cost the most
  this time: a 16 KB direct-mapped data cache kills init (both line sizes);
  IRIX ignores `Config.DB`; the cpu-tests suite and all four ratchets pass a
  cache that kills init - only the IRIX boot sees it; GHDL 4.1 lowers a
  signed `shift_right` as `>>`; `pkill -f` from a `wsl -- bash -lc` string
  kills your own shell; Quartus writes `SEED` back into the qsf.
