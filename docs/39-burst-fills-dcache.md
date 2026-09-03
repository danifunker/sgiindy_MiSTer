# 39. The R4600 swap, assessed; burst line fills instead, and why the data cache stayed 8 KB

Written 2026-09-02/03. Follows [38](38-resume-r4600-cd-fill-net.md), whose
item 1 was "swap the CPU for Killer Instinct's R4600". This is the record of
why that item was not done as written, what was done in its place, and what
it measured.

## 1. What the Killer Instinct core actually is

The premise in docs/38 was "Killer Instinct's core has 2-way (to be
confirmed) 16 KB caches with 32-byte lines against our direct-mapped 16-byte
ones". It was confirmed by reading `Arcade-KillerInstinct_MiSTer/rtl/cpu/`
(commit `bfdb073`, 2026-09-01) against the N64 base our own core is vendored
from (`N64_MiSTer` at `adbf9b5`, fetched into the scratchpad with
`git fetch --depth 1 origin <sha>`). KI's `cpu_TLB_instr.vhd`, `cpu_FPU.vhd`,
`cpu_FPU_sqrt.vhd`, `divider.vhd`, `functions.vhd` and `export.vhd` are
byte-identical to that base, so a three-way diff is exact.

| File | KI vs N64 | Ours vs N64 | What KI changed |
|---|---:|---:|---|
| `cpu.vhd` | 2036 lines | 284 | an 896-bit debug trace bus, FMV-restart and boot-ROM watchers, `ADDR32_ONLY`/`INSTR_KSEG_ONLY`/`NO_TRAP_INSTR` generics, and a request/acknowledge **mailbox between clk93 and clk1x** for every memory transaction, with a 16-entry read-ownership scoreboard behind it |
| `cpu_cop0.vhd` | 340 | 429 | PRId `0x2020`, `ADDR32_ONLY`, eret/TLB census counters, a delay-slot suppression fix; **32 TLB entries** (`widthad => 5`) |
| `cpu_instrcache.vhd` | 97 | 71 | the fill receiver moved from clk2x to clk1x. Geometry UNCHANGED: 512 lines x 32 bytes, direct-mapped, index 13:5 |
| `cpu_datacache.vhd` | 211 | 0 | 512 lines x **32 bytes = 16 KB**, direct-mapped (was 512 x 16 = 8 KB); a four-beat writeback with a registered-read-address fix; the same clk1x receiver; a write-through mode |

So:

* **Neither KI cache is 2-way.** Both are direct-mapped, like ours.
* **The instruction cache is identical to ours** in geometry. The only cache
  gain in the whole core is the data cache doubling from 8 KB / 16-byte lines
  to 16 KB / 32-byte lines - a 413-line diff to one file.
* **The mailbox is a cost, not a gain, on this core.** KI runs its CPU at
  75 MHz against a 50 MHz bridge and needs a real clock crossing.
  `r4300_wrap.vhd` feeds one clock to clk1x, clk93 and clk2x, so the two
  two-flop synchronisers, the ack round trip and the response's
  capture-then-rotate-then-pulse sequence are pure latency: about seven extra
  clocks on every uncached access and every miss, and a request cannot leave
  the FIFO until the previous one's acknowledgement has crossed back.
* The 32-entry TLB and PRId `0x2020` would have to be redone as 48 and
  `0x0440` (or IRIX's R4600 paths audited) - the same work docs/10 already
  did once.

Porting the 74 `-- SGI:` hunks onto a `cpu.vhd` that has moved by 2036 lines,
to arrive at a core whose one real improvement is a 413-line change to a file
we already have, was not the right trade.

## 2. Where the miss cost really was

`cpu-throughput-measured` (2026-09-02, build 19, `tests/hw-cputest`'s bench
group) gave these on the board, in CPU cycles:

| | cycles | what it is |
|---|---:|---|
| `ld_uncached` | 17.4 | one bus read, one DDR3 round trip |
| `i_uncached` | 19.6 / instr | one bus read per instruction |
| `ld_miss` | **36** | a 16-byte data line fill = **two** round trips |
| (derived) I-cache miss | ~72 | a 32-byte line = **four** round trips |

The reason is in three files that have nothing to do with the CPU core.
`rtl/cpu/r4300_bus.sv` issued one bus transaction per 64-bit word of a fill
and waited for its acknowledgement before issuing the next; `rtl/sgi/
ram_arb.sv` allows exactly one transaction in flight; `rtl/mister/
ddr3_mux.sv`'s main-memory port was single-word (`DDRAM_BURSTCNT = 1`), with
bursts reserved for the display's line caches. So a fill paid the DDR3 round
trip once per word, and **the round trip - not the word - is what a DDR3
access costs.** A 32-byte data line on that path would have taken a data miss
from 36 cycles to ~72: the KI cache, swapped in as planned, would have made
the machine slower.

## 3. What was built

### 3a. Burst line fills, end to end

One request for the whole line; the words stream back one per clock after
the first; the requester counts them. The contract, in the order the signals
are met:

* `r4300_bus.sv`: a fill puts `bus_burst` (1, 2 or 4 doublewords) on the bus
  with the request. Every `bus_ack` delivers a word to the cache's fill port
  as before; `bus_last` with an ack says the responder is done. If the line
  is not complete when `bus_last` arrives, the remainder is requested again
  (one request for all of it), so **any responder that cannot burst still
  works** - the PROM, a hole in MEMCFG - at the old word-at-a-time cost. The
  address advances per word either way, so a bus trace shows every word.
* `sgi_indy.sv`: `bus_last = cpu_ram_ack ? ram_arb's cpu_last : 1`. Only
  main memory streams.
* `ram_arb.sv`: `cpu_burst` is payload, held like the address; `inflight`
  clears on `ram_ack && ram_last`, not on the first ack. The DMA engines are
  single-word (`ram_burst = 1` when they own the port).
* `ddr3_mux.sv`: the RAM port latches `ram_burst` with the request, puts it on
  `DDRAM_BURSTCNT` for a read (a write is always one word), and acknowledges
  **every** `DDRAM_DOUT_READY` word for that master with `ram_last` on the
  final one - the same `burst_left` counter the display port already used,
  with per-word acks instead of one at the end.
* `sgiindy.sv`: two wires.
* The simulator: `verilator/sim_ram.v` streams a burst the same way
  (`burst` in, `last` out; the PROM/GIO/frame-buffer instances are tied to
  single-word, as their ports are on the board), so the whole-machine
  ratchets exercise the real path. `tb_cpuonly.sv`'s memory takes a
  `burst_en` input and every case runs **both ways at every latency** and
  must agree in every register, and at least one burst must have been
  streamed or the run fails.

### 3b. The data cache: two attempts to grow it, and why it is still 8 KB

**Attempt 1: KI's geometry whole** - 512 lines of 32 bytes, transcribed hunk
for hunk, `Config` reporting the truth (IB = DB = 1). It passed every gate
below, fitted clean, and **killed `init` on the board** ("PANIC: init died
(why = 2, what = 0x9)") and, decisively, **in the simulator at 188,024,331
cycles with the caches on**, while the `--no-dcache` boot ran straight past
that point. The traced run's RAM dump showed the shape: exactly one page of
`/sbin/init`'s text (va 0x7fc07000, phys 0x00399000) held zeros from +0x40
to the end while every other loaded page was byte-perfect; the last 64
user-mode PCs were init running through four consecutive `jal`s without
taking any - a page of NOPs.

Two things were learned from the kernel binary on the way. `Create_Dirty_
Exclusive`, the hazard docs/10 worried about, does not appear in `/unix` at
all. And **IRIX 5.3 never reads `Config.IB`/`DB`: it hard-codes the primary
data line size from `PRId`** - `__dcache_inval` (0x88002908) and
`__dcache_wb_inval` (0x88002ccc) mask with `andi 0xf` and step `0x10` on
the R4400 path, `0x1f`/`0x20` only on the R4600 path chosen by
`config_cache` for imp 0x20. That is a real hazard for a 32-byte line under
an R4400 presentation (a plain `Hit_Invalidate_D` at a 16-byte-aligned
buffer edge discards the dirty other half of the line), and reason enough
on its own not to change the line - but it is not what zeroed the page: a
16-byte-stepped invalidate still visits every 32-byte line base.

**Attempt 2: 16 KB of 16-byte lines** - the original file with one more
index bit, everything else upstream's, `Config` back to 16 KB/16-byte. Same
gates passed; **same death in the simulator, at 200,100,483 cycles, the
same page of NOPs.** So the killer is the size, i.e. **the virtual index
bit 13**. The R4300's data cache is virtually indexed and physically tagged;
at 8 KB only bit 12 of the index is virtual, at 16 KB bits 13:12 are. IRIX
colours pages for a 16 KB cache (`cachecolormask` = 3, `pagecoloralign`,
`color_validation` flushing on a mismatch) - but evidently not on the path
that zeroes a page through one virtual alias and invalidates it through
another before DMA fills it: the zero lines stay dirty in the other index
and are written back over the file data. A real R4400 has its secondary
cache catch exactly this (the VCE machinery, `ecc_kvaddr_vcecolor` in the
kernel); this core has no secondary cache and no VCE.

So the data cache is the R4300's 8 KB again, unchanged, and a bigger one is
a different design: physically indexed (feasible - the data mini-TLB in
`cpu_TLB_data.vhd` produces `TLB_AddrOutFound` in the same cycle the cache
reads its tags - but the tag read on a mini-TLB miss has to be redone after
the walk), or two-way with 8 KB per way, which is what the real R4600 is
and why IRIX's R4600 path colours on one bit. `UPSTREAM.md` records both
attempts so they are not made a third time.

What the data cache did get is the burst: its 16-byte line is one two-word
request on the SGI bus instead of two round trips.

## 4. Gates

Every gate the plan named plus the two the burst path added, run on the
final geometry (the 8 KB data cache, burst fills). Both 16 KB attempts
passed every one of these too - which is the point of section 3b: this
list could not see the failure, and the IRIX boot in the simulator now sits
in it.

| Gate | Result |
|---|---|
| `make -C verilator ddr3test` (RAM master issues 1/2/4-word bursts, checked word by word with `ram_last`) | PASS |
| `make -C verilator ramarbtest` (CPU asks bursts; port streams; `cpu_last` checked) | PASS, all latencies 0..60 |
| `make -C verilator fetcharbtest`, `linecachetest` (rtl/mister changed) | PASS |
| `make -C verilator cpuonly` (every case streamed AND word-by-word, 0..12 latency, all cache modes) | PASS: 728 runs, 0 against expectation; the 78 runs that fill do it in one request instead of two |
| `tests/run-cputest.sh` (240 tests) | 2160 checks passed, 3 failed, the one failing test `fpu/vec_cvt_from_l` as before (the GHDL shift fix makes this box match the documented number; it was 2159/5 here before it) |
| `tests/run-prom.sh` | PASS |
| `tests/run-newport.sh` | PASS (1318x1065, the raster shows the store row for row) |
| `tests/run-rex3.sh` | PASS (every checked pixel matches the command trace) |
| `tests/run-scsi.sh` | PASS (POST with a disk on ID 1, hinv lists the disk and the CD-ROM, nothing forbidden) |
| **the IRIX boot in the simulator** (`--disk 1=SGIIndy53-master.img`, stop on PANIC, ~22 min) | PASS: no panic in 450,000,000 cycles (the two 16 KB caches died at 188M and 200M), init running and its "The system is coming up" begun on the console when the cycle limit stopped the run |

## 5. The board

### 5a. Build 20, the 32-byte first cut (fitted, benched, and dead)

Commit `26b18fc` (+ `b372921`), seed 2, fitted from the worktree in 36
minutes: 40,531 registers after synthesis, the same six uninferred arrays as
build 19, every clock met including the HDMI PLL domain (+0.426 ns; build
19 missed it by 0.162), 83% of the ALMs, rbf md5 `ff2067b9...`. The bench
ran clean on it - and it is worth keeping the numbers because the fill
path is what they measure and the fill path survives:

| bench | build 19 | build 20 (32-byte line) | |
|---|---:|---:|---|
| `ld_miss` (one `lw` per 32-byte stride over 256 KB: every load a miss) | 18 ticks = **36 cycles** for a 16-byte line | 13 ticks = **26 cycles** for a 32-byte line | the round trip paid once |
| `i_cached` / `st_cached` | 500 / 501 t/kinstr | 500 / 500 | unchanged, 1.0 CPI |
| `ld_cached` | 945 | 944 | unchanged |
| `i_uncached` / `ld_uncached` / `st_uncached` | 9782 / 8689 / 3161 | 9779 / 8689 / 3160 | unchanged |
| `count_rate` | 25.0 MHz | 25.0 MHz | unchanged |

Then IRIX: "PANIC: init died (why = 2, what = 0x9)", a crash dump to the
swap partition of `SGIIndy53-wedged-fsck.img`, and section 3b.

### 5b. Build 21: the 8 KB data cache with burst fills

Commit `62be253`, seed 2, fitted from the worktree in 21 minutes on top of
build 20's database: 40,541 registers after synthesis, the same six
uninferred arrays, every clock met - the HDMI PLL domain by 0.080 ns this
time (seed-dependent as ever: +0.426 for build 20, -0.162 for build 19), the
core clock by 2.772 ns. rbf md5 `5f02393b96f9e1361d5b6da6ed7b2a93`, kept as
`output_files/sgiindy-b21-seed2.rbf`.

The bench (`tests/run-cputest-hw.sh --no-build`, Count ticks, 1 tick = 2
CPU cycles):

| bench | build 19 | build 21 | |
|---|---:|---:|---|
| `ld_miss` (one `lw` per 32-byte stride over 256 KB: every load a miss) | 18 ticks = **36 cycles** | 13 ticks = **26 cycles** (106,796 ticks / 8192 loads) | the DDR3 round trip paid once per line, not once per word |
| `i_cached` / `st_cached` | 500 / 501 t/kinstr (1.0 CPI) | 500 / 500 | unchanged |
| `ld_cached` | 945 | 944 | unchanged |
| `i_uncached` / `ld_uncached` / `st_uncached` | 9782 / 8689 / 3161 | 9778 / 8689 / 3160 | unchanged |
| `count_rate` | 25.0 MHz | 25.0 MHz | unchanged |

The suite on hardware: 2165 checks passed, 3 failed (245 tests), the three
being `fpu/vec_cvt_from_l` as before. The instruction cache's 32-byte line,
which nothing in the bench group measures directly, had the same
four-round-trip fill and gets the same treatment: an instruction miss that
cost ~72 cycles should now cost about what `ld_miss` does. What is left in
the 26 cycles is the ~17-19-cycle trip itself plus the handshake stages
either side of it (the write FIFO, `r4300_bus`, `ram_arb`, `ddr3_mux`'s
latch-then-issue, the fill-end daylight clock, the cache's `ram_done` path)
- a few cycles each, and the next thing to shave.

The desktop: the boot ran `savecore` on build 20's dump and the root
filesystem check, reached the login chooser, `text:root` + Enter logged in,
the root desktop came up (Toolchest, Console at `~#`, Software Manager, the
Ethernet no-carrier alert as always), the Toolchest's System menu posted
with all its entries, `init 0` typed at the Console echoed `INIT: New run
level: 0` and the machine halted to "Okay to power off the system now".
The beacon's `cpu:` word decodes (kernel and user PCs alike) and
`lcache:` shows zero misses. **The board was left at that halt screen on
build 21.**

## 6. Traps paid for

* **GHDL 4.1.0 lowers `shift_right` on a signed operand as Verilog's logical
  `>>`.** cpu.vhd's 65-bit `calcResult_shiftR` is the one place it matters:
  under Verilator `dsra 0x8000000000000000, 4` read `0x1800000000000000`
  (one sign bit at position 64-n instead of a fill) and
  `alu/dsll_dsrl_dsra` + `alu/dshift32_variants` failed. Pre-existing on
  this box - the evening's pre-change binary gives the same 2159/5 - and
  invisible on the board, where Quartus compiles the VHDL. The "2161/3"
  the docs quote was a GHDL 6 number. `tools/gen_r4300_verilog.sh` now
  rewrites the operator to `>>>` on the way out and prints the count.
* `tests/baseline/iris-r4400.log` was never committed, so `run-cputest.sh`
  dies in `compare.py` after the run; the suite's own `RESULT:` line in
  `tests/out/r4300.log` is the number.
* A fit from a worktree needs `build_id.v` (gitignored, written by the
  framework's pre-flow script, which `scripts/build.sh`'s stage-by-stage
  flow does not run) plus `roms/` and `tests/disks/` copied across for the
  ratchets.
* `pkill -f <pattern>` from inside `wsl.exe -- bash -lc '...'` matches the
  `-lc` command line itself whenever the pattern appears in it; anchor the
  pattern (`^bash /tmp/gates.sh`) or the kill takes your own shell and
  nothing after it runs. Shell variables inside that `-lc` string are eaten
  too - put anything with a `$` in a script file.
* Quartus writes `SEED n` back into `sgiindy.qsf` when `--seed=n` is used;
  `git checkout -- sgiindy.qsf` before the next commit, never while a fit is
  running.
* Verilator 5.020 can abort at the very end of a build with "Internal Error:
  attempted to destroy locked Thread Pool" after the binary has already been
  linked; the second `make` finds nothing to do and the binary is current.
* The IRIX boot's console file is flushed as it goes, but the harness's own
  summary (`--- stop-on ...`, the last 64 user PCs) only at exit; `--exc`
  stops at 400 entries, well before a late panic - raise `--exc-count`.

* `cpu_datacache.vhd`'s line-index register grew to 14 bits; one assignment
  still fed it 13 and GHDL's **synthesis** reported it (`out of bound
  expression`) while its **analysis** only warned. The generator script's
  `rc` was 0 and the old `r4300_wrap.v` kept its timestamp - the exact trap
  `local-toolchain` warns about, from a different cause. Check the timestamp.
* `ddr3test` had stopped building since the round-robin arbiter went in:
  Verilator 5.020 reads the loop-local `cand` in `pick`'s `always_comb` as a
  latch and the target lacked `-Wno-LATCH` (the whole-machine flags have it).
  Waived in the Makefile; the bench itself was fine.
* `make ramarbtest` and `make ddr3test` only BUILD; run
  `./obj_dir_ramarb/Vram_arb` and `./obj_dir_ddr3/Vddr3_mux` yourself.
* Under WSL the suite build needs a line-feed copy of `iris/cpu-tests`
  (`~/cputests`, refreshed from the Windows checkout with the carriage
  returns stripped) and `CPUTESTS=~/cputests`; `tests/run-cputest.sh
  --no-build` after `make -f Makefile.lf cputest`.
