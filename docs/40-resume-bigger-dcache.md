# Work item: a 16 KB data cache that IRIX survives - physically indexed first, two-way as the backup; then the CD-ROM attach, the burst-write path, Ethernet

Paste everything below the line as the opening message of a fresh session.
This follows [39](39-burst-fills-dcache.md), the session of 2026-09-02/03
that assessed the R4600 swap, built burst line fills instead, tried two
16 KB data caches that both killed IRIX's init, and shipped build 21 with
the original 8 KB cache and one-round-trip fills. Written 2026-09-03, with
option 1 below already in the worktree and its gates running.

---

## STATE AT HANDOFF (read this first)

* **`main` is at `d149aa4`** (the burst fills `26b18fc`, the GHDL shift fix
  `b372921`, the 8 KB decision `62be253`, docs/39). The user pushes from his
  own environment.
* **Build 21 is on the board and VERIFIED**: commit `62be253`, fitter seed
  2, rbf md5 `5f02393b96f9e1361d5b6da6ed7b2a93`, a copy in
  `output_files/sgiindy-b21-seed2.rbf` of the worktree it was fitted from
  (`.claude/worktrees/modest-robinson-cad59e`; the main checkout's
  `output_files/` still holds build 19's). Every clock met (HDMI PLL domain
  +0.080 ns, core +2.772). Bench: `ld_miss` 13 ticks = 26 cycles for a
  16-byte line (build 19: 36), everything else identical. IRIX boots to the
  root desktop, the toolchest menus post, `init 0` halts it cleanly. Build 19
  (`aa74e33c...`, the main checkout's `output_files/sgiindy-b19-seed2.rbf`)
  is the fallback. `output_files/sgiindy-b20-seed2.rbf` is the DEAD 32-byte
  cut - never deploy it.
* **The board was left HALTED ("Okay to power off the system now") on
  build 21**, `SGIIndy53-wedged-fsck.img` in slot 1, cleanly unmounted.
  Before ANY redeploy of a running IRIX: pointer onto the Console, `init 0`,
  Enter, wait for that screen. The pointer walk: 40 steps of (-40,-40) to
  the corner, then aim for the window CENTRE with the deltas divided by ~1.8
  (the 1:1 `xset m 0 0` was not in effect), screenshot, click, type.
* **Option 1 (below) is IMPLEMENTED in the worktree, UNCOMMITTED, gates
  running when this was written**: `rtl/cpu/r4300/cpu_datacache.vhd`
  (16 KB, `tlb_unstall` port, `ce_fetch` on the unstall clock), `cpu.vhd`
  (`EXECacheAddr(13 downto 12)` from the mini-TLB), `r4300_wrap.vhd`
  (`SETTLE_CLOCKS` 2048), `rtl/cpu/r4300/UPSTREAM.md` (describes it). If
  the worktree is gone, the change is small enough to redo from the
  description in UPSTREAM.md and section 1 below. Do NOT merge it to `main`
  before the IRIX boot in the simulator has passed init.
* **The IRIX boot in the simulator is a GATE now**, the only one that
  caught the two dead caches: `verilator/obj_dir/Vsim_top --prom
  roms/IP24_Indy/ip24prom.070-9101-011.bin --no-gfx --disk
  1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img --max-cycles 450000000
  --stuck 250000000 --type-on 'Option?' '1\r' --stop-on PANIC --console F`,
  ~175k cycles/s, init at ~190M cycles (22 min), the limit at 45 min; a
  pass is "no PANIC and the console has begun `The system is coming up`".
  `--no-dcache` is the control; `--ramdump 0x88000000:0x4000000:F --exc
  --exc-count 2000 --pc-user F` the post-mortem. Launch it detached from a
  script file (`nohup ... & disown`); `setsid` inside a `wsl -- bash -lc`
  string silently did not start it, and `$vars` in that string are eaten.
* All four whole-machine ratchets, `run-cputest` (2160/3, only
  `fpu/vec_cvt_from_l`), `cpuonly` (728/0), `ddr3test`, `ramarbtest`,
  `fetcharbtest`, `linecachetest` pass on `62be253`.
* Read the auto-memory notes first: `irix-hardcodes-dcache-line`,
  `ki-r4600-core-assessed`, `cpu-throughput-measured`, plus `local-toolchain`
  (the GHDL 4.1 signed-shift trap), `verilator-whole-machine` (the IRIX-boot
  recipe), `vc2-line-numbering-off-by-one`, `sim-memory-lane-alignment`,
  `display-fetch-path-board-only`, `shutdown-hang-kdsp-audio`,
  `indy-desktop-input-recipe`, `mister-main-death-instruments`,
  `newport-vdma-pixel-path`, `hardware-bug-instrument-first`,
  `iris-oracle-local`, `quartus-ram-inference`.

You are working on an **SGI Indy (IP24) core** for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly** (a session may start in a worktree on a `claude/*` branch: commit
there, then `git -C C:/Temp/mistercore/sgiindy_MiSTer merge --ff-only
<branch>`; a fit runs from the worktree once `build_id.v`, `roms/` and
`tests/disks/` are copied in, `SEED=2`, and Quartus writes `SEED` back into
`sgiindy.qsf` - `git checkout -- sgiindy.qsf` afterwards). The reference
emulator IRIS is `C:\Temp\mistercore\iris`. A fit is 20-40 minutes. Another
Claude session on this box fits `MacQuadra800`; no launch while its quartus
is listed (`tasklist | grep -i quartus`). The board is a SuperStation1; its
MiSTer binary is a fork.

## The lesson this queue is built on

The data cache upstream inherited from the N64 R4300i is **virtually
indexed, physically tagged**. At 8 KB only index bit 12 is virtual and
IRIX's page colouring copes. At 16 KB direct-mapped, bit 13 is virtual too,
and IRIX 5.3 zeroes a page through one mapping and invalidates it through
another before DMA fills it: the zero lines stay dirty in the other index
and are written back over the file data - one page of `/sbin/init`'s text
came out all zeros, init ran a page of NOPs, "PANIC: init died (why = 2,
what = 0x9)". Both 32-byte and 16-byte lines died the same way. The cache
RTL was never wrong: Killer Instinct's identical direct-mapped design works
for KI because the game runs almost entirely unmapped and never makes that
alias; a real Indy R4400 survives it because its secondary cache traps the
alias (VCE), and the real R4600 is two-way with 8 KB ways so only bit 12 is
virtual. This core has neither. **So a bigger data cache must have no
virtual index bit above 12**: either take bits 13:12 from the physical
address, or keep the index at 12:4 and add a way.

Two more facts from `/unix` that bound the design: **IRIX never reads
`Config.IB`/`DB`** - `__dcache_inval` (0x88002908) and `__dcache_wb_inval`
(0x88002ccc) hard-code `andi 0xf`/step 0x10 on the R4400 path and 0x1f/0x20
only on the R4600 path chosen by `config_cache` (0x88003280) for PRId imp
0x20 - so the data line stays 16 bytes under PRId 0x0440; and
`Create_Dirty_Exclusive` is not in the kernel at all. The cpu-tests suite
and all four ratchets passed BOTH dead caches; only the IRIX boot sees this
class of bug, on the board or in the simulator.

## The queue

### 1. Option 1: 16 KB direct-mapped, PHYSICALLY indexed (in the worktree; finish it)

The design, as implemented: `cpu_TLB_data.vhd`'s mini-TLB compares
`calcMemAddr` combinationally in the execute cycle and produces
`TLB_dataAddrOutFound`, so in `cpu.vhd`

    EXECacheAddr(13 downto 12) <= TLB_dataAddrOutLookup(13 downto 12) when TLB_dataUnStall = '1'
                             else TLB_dataAddrOutFound(13 downto 12)  when EXETLBMapped = '1'
                             else calcMemAddr(13 downto 12);

and the cache reads its tag AGAIN on the unstall clock (`ce_fetch` extended
with the new `tlb_unstall` input) because the read it did on the miss clock
used `Found` bits that were not yet valid; the execute stage still presents
the same access on that clock (decode is frozen through the stall) and
stage 4 consumes the read one clock later exactly as after an ordinary
fetch. Unmapped regions translate to themselves in those bits. Index cache
ops use K0 addresses in IRIX and the PROM, so they are unaffected; hit ops
through user/K2 addresses now land in the right line, which is the point.

Gates, in order, nothing skipped: `make -C verilator cpuonly` (728/0, bursts
in 78 runs), `run-cputest` (the `tlb` and `cache` groups are the ones that
exercise a mini-TLB miss on a cached access; 2160/3 is the bar), the four
ratchets, **the IRIX boot in the simulator to past init**, then a fit
(`SEED=2`) - watch the core clock's slack: the mini-TLB compare and mux now
sit in front of the tag RAM's address, and the core clock had +2.772 ns on
build 21 - then the board: `tests/run-cputest-hw.sh --no-build` (`ld_miss`
should stay ~13 ticks; the gain is fewer misses, which the bench group does
not measure - `i_cached`/`st_cached` must stay 1.0 CPI), IRIX to the
desktop, toolchest, `init 0`. Then commit, UPSTREAM.md already describes it,
docs/41.

If it fails timing, the shortest fix is to register nothing and instead
give the tag RAM the virtual bits when unmapped and the mini-TLB bits when
mapped with the mux moved after the entry compare (what it is now) - i.e.
there is no cheaper form; go to option 2. If it fails the IRIX boot, take
the RAM dump exactly as docs/39 did (`findpage.py`/`survey.py` in the
scratchpad of that session, or re-derive: find init's pages by 64-byte
signatures, diff word by word) before changing anything.

### 2. Option 2 (backup): 16 KB two-way, 8 KB per way

The real R4600's shape, and why IRIX's R4600 path colours on one bit.
Index stays 12:4 (512 sets), two tag RAMs (22 bits each, compared in
parallel against `RW_addr(31 downto 13)` - the tag gains bit 13 back), two
data RAM banks (1024 x 64 each, the same 16 KB of M10K in total), one LRU
bit per set (a 512-bit register file or a third small RAM), the hit way
selecting the read data (a 64-bit 2:1 mux in front of `read_data`'s shift -
watch timing there), fills and merges into the victim way, the victim's
writeback if dirty, and `Index_*` cache ops selecting the way by address
bit 13 (IRIX sweeps 0..16 KB in 16-byte steps under an R4400 presentation,
so both ways get visited). KI's core is NOT a reference here - it is
direct-mapped. `tests/run-cputest.sh`'s `cache` group plus the IRIX boot are
the gates; expect two or three tries.

### 3. IRIX does not attach the CD-ROM (the CD install blocker) - unchanged from docs/38

`hinv -c disk` lists no CD-ROM, `/CDROM` is empty, and the beacon's last
command to ID 6 after INQUIRY (alloc 64, 54 returned) is a 12-byte MODE
SELECT - READ CAPACITY is never issued. Leads: simulate dksc's attach in
`tests/scsiwr` and look at the MODE SELECT completion status (`917dce7`'s
S_DISCONNECT 0x85 on ST_SAT_END is a candidate); disassemble `dkscinit`
(0x880aad10) / `dksc_unit` (0x880ae4f0) in `unix.ecoff`; compare with IRIS's
`src/scsi.rs` (`exec_mode_select_6`). `scsicontrol` from the guest console
is safe.

### 4. Rasteriser fill speed: a burst-WRITE path - unchanged from docs/38

DR_FILL is one pixel per `fbw` transaction. The read side now has the shape
to copy: `ram_burst`/`ram_last` on `ddr3_mux`'s RAM port, `burst_left`
acking per word. `tb_rex3` (`REX3_ACK_DELAY=40`) is the gate; `run-rex3` the
replay check; `np_rex3` addresses 32-bit slots and relies on byte enables.

### 5. Shave the miss further

26 cycles for a 16-byte line is the DDR3 trip (~17-19) plus the handshake
either side: cpu.vhd's write FIFO, `r4300_bus` S_IDLE, `ram_arb`,
`ddr3_mux`'s latch-then-issue (two clocks), `S_FILLEND`'s daylight clock,
the cache's `ram_done` path. `tb_cpuonly` counts requests and acks;
`ld_miss` on the board is the number. Do not touch `S_FILLEND` without
re-reading `r4300_bus.sv`'s ordering note.

### 6. Ethernet (docs/35 item 5, unchanged); 7. Audio, eventually

## Instruments (all present, all proven)

* Everything in docs/38's list; `tests/run-cputest-hw.sh --no-build` for
  the bench group on the board (`board_phase.sh`'s shape: deploy
  `--no-launch`, the bench, `mount.sh` with no arguments).
* The IRIX boot in the simulator, above; `efsread.py IMAGE get /sbin/init F`
  (with `MSYS_NO_PATHCONV=1`) + a Python ELF header walk + `disbin.py` for
  user-space code; the harness's `--pc-user`, `--exc --exc-count N`,
  `--ramdump`; the harness prints the last 64 user-mode PCs at exit - a run
  of sequential PCs through `jal`s is a page of NOPs.
* `ecoffsyms.py unix.ecoff syms` + `disbin.py` on the kernel's cache
  routines: `config_cache` 0x88003280, `__dcache_inval` 0x88002908,
  `__dcache_wb_inval` 0x88002ccc, `color_validation` 0x880486d0,
  `pagecoloralign` 0x8802a570.
* The beacon (`bcnread.py` ver=8) decodes on build 21: `cpu:` gives kernel
  and user PCs, `lcache:` zero misses.

## Traps paid for (do not re-pay)

* Everything in docs/38's and docs/39's lists. The ones that cost the most
  this time: a 16 KB direct-mapped VIPT data cache kills init (both line
  sizes) and only the IRIX boot sees it; IRIX ignores `Config.DB`; GHDL 4.1
  lowers a signed `shift_right` as `>>` (the generator rewrites it now);
  `pkill -f` from a `wsl -- bash -lc` string kills your own shell and `$vars`
  in it are eaten - use script files; Quartus writes `SEED` back into the
  qsf; a worktree fit needs `build_id.v`; Verilator 5.020 can abort in its
  thread-pool teardown after the binary is already linked.
