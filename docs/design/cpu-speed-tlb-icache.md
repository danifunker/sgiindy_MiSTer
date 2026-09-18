# Speed: where an IRIX session's time goes (builds 28-30)

Written 2026-09-16. The request was "this core is running slowly - fix the
speed before adding features; look at what is hurting the user experience."
This is the record of the measurement that answered it and of the changes
it pointed at, each measured on the board with the same workloads:

| build | change | boot to X | perl | bzip2 | 60 x ls |
|---|---|---:|---:|---:|---:|
| 27 | (the release, profiled) | 216 s | 44.5 s | 215.0 s | 8.8 s |
| 28 | the TLB matched in parallel, 16 KB instruction cache (§3-4) | 171 s | 26.6 s | 150.1 s | 8.5 s |
| 29 | the DDR3 port pipelined (§5-6) | 136 s | 20.1 s | 109.2 s | 6.0 s |
| 30 | refills after a TLB walk answered from the cache (§7) | 114 s | 16.1 s | 103.7 s | 4.8 s |

and the instruments left behind for the next round: the performance
counters, the beacon profiler, and the simulator's cache access traces.

## 1. Measuring without a fit

Beacon word 10 has carried `{decode PC, dbg_cop0}` since build 12, and
`dbg_cop0` bits 17:13 are the pipeline's stall vector (stall4 & stall3 &
stall2 & stall1), bits 10/11 the TLBDATA/TLBINSTR walk states
(`cpu_cop0.vhd`). Sampled at a steady rate from the ARM, that is a
statistical profiler of the running machine that needs nothing new in the
bitstream:

| Tool | Where | What |
|---|---|---|
| `tools/misterdeploy/prof.py` | board | samples words 0/10/13/15 at 250-1000 Hz into a capture, a full beacon snapshot at each end; `--until-idle N` stops once the kernel idle loop has held >= 90 % of the last N s, which is how a benchmark's end is found without reading the screen |
| `tools/misterdeploy/profan.py` | host | classifies every sample twice - WHERE (idle loop / kernel function by `unix.ecoff` / user text by `so_locations`) and HOW (advancing, fetch held, execute held, writeback held, TLB walk) - with a time series |
| `scripts/perfprobe.sh` | host | restores the pristine image, boots with a 360 s profile running, logs in as root, quits Software Manager, and types a fixed set of workloads into the Console, each timed by bash `time` into `/root/bench.txt` and profiled to idle; `init 0`, then `bench.txt` comes off the image with `efsread.py` |

**Trap paid (one lost run):** Software Manager opens by itself ~30 s after a
root login, on top of the Console, and takes every typed key ("The
distribution echo == fork ... does not exist"). The script now quits it
through its File menu. `ws_send` `mouseMove` steps of 4 pixels or less move
the pointer 1:1; larger steps are accelerated ~1.5x by X.

## 2. Build 27, measured (2026-09-16, board .92, pristine image)

**The boot is CPU-bound, not waiting on timeouts.** From launch to the X
login screen the machine was idle 0-16 % of the time (the kernel idle loop
over 20 s buckets) - the quiet stretch in docs/design/scsi-block-cache.md's disk log is user-space
work, not a network or disk timeout.

**Where the busy clocks went** (samples outside the idle loop):

| workload | advancing | fetch held (not TLB) | execute held (not TLB) | TLB walk | writeback held |
|---|---:|---:|---:|---:|---:|
| IRIX boot to X (360 s) | 26.5 % | 31.9 % | 23.1 % | **14.5 %** | 4.0 % |
| root login to settled desktop (64 s) | 25.8 % | 30.2 % | 22.2 % | **18.8 %** | 3.1 % |
| perl 200 000-iteration loop | 12.7 % | 24.9 % | 16.3 % | **45.9 %** | 0.3 % |
| bzip2 -9 of /unix | 26.0 % | 16.3 % | 25.1 % | **29.5 %** | 3.1 % |
| `ls -lR /usr/lib/X11` into the Console | 21.7 % | **45.9 %** | 20.2 % | 9.9 % | 2.2 % |
| 60 x `/bin/ls /` | 19.5 % | 33.0 % | 32.1 % | 7.4 % | 8.0 % |

**Timed** (bash `time`, real):

| workload | build 27 |
|---|---:|
| 60 x `/bin/ls / > /dev/null` | 8.76 s |
| perl loop | 44.52 s |
| bzip2 -9 -c /unix | 214.96 s |
| dd 10 MB off `/dev/rdsk/dks0d1s0` | 8.05 s |
| `ls -lR /usr/lib/X11` into the Console | 16.56 s |
| boot, launch returned to X login screen | 216 s |
| root login to a settled desktop | ~67 s |

What it says:

* **The TLB was walked, not matched.** `cpu_cop0.vhd` compared one entry per
  clock from the entry that matched last. The instruction mini-TLB has one
  entry and the data mini-TLB four, so a user program crossing pages walked
  up to 48 clocks per crossing, and every TLB refill walked all 48 to learn
  the entry was absent before the exception was taken. Upstream (N64, Killer
  Instinct) never noticed because their software barely uses the TLB; IRIX
  runs every user program through it.
* **The 8 KB instruction cache was the largest single stall** - the fetch
  stage held on fills for about a third of the busy clocks, nearly half while
  X drew a scrolling Console.
* `us_delay` held 8 % of the boot and 8.5 % of the login: a calibrated busy
  loop. Its callers are the WD33C93 driver (`wait_scintr`, `ack_msgin` - it
  polls the chip's Auxiliary Status with `us_delay(1)` and `us_delay(8)`) and
  the graphics driver's `vdma_wait` (polls the MC DMA engine's run bit with
  `us_delay(1)` until an X pixel transfer completes). Both are time the CPU
  spends waiting on a device model, not doing work.
* The idle desktop was 98.9 % idle: no background load.

## 3. Build 28

### The TLB is matched in parallel

`cpu_cop0.vhd`: the fields a match needs - VPN2 (27 bits), page mask (12),
ASID (8), region (2), global (1) - are shadowed in registers beside the entry
RAM (`TLBSH_*`), written from exactly what `TLBMEM` is written with in the
same clock (TLBWI, TLBWR, the init clear), so the two cannot disagree about
an entry. All 48 are compared at once (`TLB_camHit`, `TLB_camIndex`, lowest
index wins):

* **a lookup** (TLBINSTR/TLBDATA) compares the entry that matched last in its
  first clock exactly as before and, in the same clock, jumps to the matching
  entry; the second clock reads that entry and ends the lookup. No match
  anywhere ends it in the first clock, not found - the refill case, which
  used to take 48 clocks;
* **a probe** (TLBP) answers in one clock.

The RAM remains the source for TLBR and for the translation. Cost: ~2,400
registers and the compare logic. Where two entries match - IRIX never makes
that, an R4000 answers with a machine check - the lowest index wins, which is
also what the upstream probe walk returned.

### The instruction cache is 16 KB again

`cpu_instrcache.vhd`, `cpu.vhd`: index bits 13:5 (512 lines of 32 bytes),
both index bits above the page offset taken from the instruction mini-TLB's
translation (`FetchIndexPhys1/2 = FetchAddrTLBMuxed(13 downto 12) &
FetchIndex(11 downto 2)`), the fill index physical, tag 31:12 as before.
Build 24 went down to 8 KB because a VIRTUALLY indexed 16 KB cache aliased
under the R4600 colouring (docs/45); build 25 made the index physical
(docs/47), and a physically indexed cache has no alias to take whatever its
size. Config has always reported 16 KB, so IRIX's index flush loops now cover
it exactly once instead of twice. Cost: six more M10K and a 512-entry tag
MLAB instead of 256.

### The counters (beacon ver 10, words 21-34)

`sgi_indy.sv` counts the CPU's clocks and events, `sgiindy.sv` the DDR3
port's; `cpu.vhd` exports `dbg_perf` (fill requests, writeback beats,
uncached fetches, bus transactions, fills in flight) and `ddr3_mux.sv`
`dbg_tst/cur/pend/first/pick`. Counters marked /64 are 38-bit and report the
top 32 bits (46 minutes before wrapping).

| word | high 32 | low 32 |
|---|---|---|
| 21 | instructions retired /64 | clocks with no stall /64 |
| 22 | clocks the fetch stage held /64 | clocks execute held /64 |
| 23 | clocks writeback held /64 | clocks in a TLB walk /64 |
| 24 | clocks an I-cache fill was on the bus /64 | clocks a D-cache fill was /64 |
| 25 | I-cache fills | D-cache fills |
| 26 | D-cache writeback beats | uncached fetches |
| 27 | instruction TLB walks | data TLB walks |
| 28 | bus transactions issued | clocks a transaction was on the bus /64 |
| 29 | clocks the display held the DDR3 port /64 | clocks RAM held it /64 |
| 30 | clocks the rasteriser held it /64 | clocks anyone else did /64 |
| 31 | clocks a RAM request waited unserved /64 | a rasteriser request /64 |
| 32 | RAM transactions | rasteriser transactions |
| 33 | clocks from a read's issue to its first word /64 | reads issued |
| 34 | clocks an issue waited on DDRAM_BUSY /64 | display bursts |

`bcnread.py --perf` prints one reading; `perfdiff.py` turns two into a
breakdown (miss rates per 1000 instructions, bus clocks per fill, clocks per
TLB walk, the DDR3 port's share per master, queueing per RAM transaction, the
bridge's read latency). `profan.py` prints the same breakdown for any capture
from a ver-10 bitstream. The simulator brings the CPU words out too
(`sim_top.sv` perf0-7, printed at exit), and `sim_cputest --prof FILE
--prof-callers HEX,..` writes a clock-weighted PC profile with call sites
(`simprof.py`).

### Gates

| Gate | Result |
|---|---|
| `make cpuonly` | 728 runs, 0 against expectation (both changes) |
| cpu-tests suite | 2161 / 3 - the known `fpu/vec_cvt_from_l` only (TLB change alone, and with the 16 KB cache) |
| IRIX 5.3 whole-machine boot, 230M cycles | init survives, no PANIC, the unclaimed-bus device table identical to the control's (build 27's source with the counters, `~/speedbase`) and to build 27's own run; last new peripheral at 181.49M cycles against 182.17M. Over the run: 93.5M instructions against 91.6M, instruction-cache fills 7.11 per 1000 instructions against 8.17, clocks in a TLB walk 0.25M against 2.41M |
| Quartus, SEED=2 | 38,835 ALMs (93 %), 47,446 registers, 481 / 553 M10K; core clock setup slack +2.267 ns (build 27: +3.069), HDMI PLL +0.127 ns, every domain met; `output_files/sgiindy-b28-seed2.rbf` md5 `37be5a16fe3ab092494283442cc428b0` |

## 4. Build 28 on the board

`scripts/perfprobe.sh --tag b28 --fresh ...pristine.img`, 2026-09-16 08:02,
the same workloads as §2 (xwsh replaced by xterm and xdpyinfo, because xwsh
detaches and its `time` measures nothing). Logs and reports in
`tests/out/hw/perf-b28/`.

| workload | build 27 | build 28 | |
|---|---:|---:|---:|
| launch returned to the X login screen (10 s polls) | 216 s | **171 s** | 1.26x |
| root login to a settled desktop | ~67 s | **~53 s** | 1.26x |
| perl loop | 44.52 s | **26.60 s** | **1.67x** |
| bzip2 -9 -c /unix | 214.96 s | **150.12 s** | **1.43x** |
| `ls -lR /usr/lib/X11` into the Console | 16.56 s | **12.88 s** | 1.29x |
| 60 x `/bin/ls /` | 8.76 s | 8.45 s | 1.04x |
| dd 10 MB off the raw disk | 8.05 s | 7.74 s | 1.04x |
| `xterm -e /bin/true` (cold, then warm) | - | 1.98 s, 0.77 s | |
| `xdpyinfo > /dev/null` | - | 0.27 s | |

The TLB is gone as a cost - its walk states are live in 0.5-2 % of the busy
clocks (perl 6.5 %), 1.9 clocks per walk. What the counters say is left
(prof.py windows, so the idle loop is mostly outside them):

| workload | clocks/instr | I-cache fills /1000 instr | D-cache fills /1000 | clocks per fill on the bus | TLB walks /1000 (I + D) | bus transactions: clocks each |
|---|---:|---:|---:|---:|---:|---:|
| perl | 3.95 | **38.7** | 4.2 | 41 | 22 + 73 | 38.5 |
| bzip2 | 3.30 | 15.1 | 15.2 | 36-38 | 7 + 35 | 30.3 |
| scroll | 2.88 | 15.4 | 4.6 | 33-37 | 3 + 5 | 48.4 |
| login | 2.75 | 20.0 | 7.2 | 34-38 | 6 + 10 | 32.2 |
| 60 x ls | 2.70 | 16.6 | 8.8 | 32-37 | 4 + 6 | 28.2 |

* **The DDR3 port is the bottleneck behind every fill.** The display held it
  41 % of the time in every window; a main-memory transaction waited 15-20
  clocks unserved before holding the port for 8-11 (the bridge answers a
  read's first word 9.7 clocks after taking it). In bzip2, 125.8M bus
  transactions averaged 30.3 clocks: half the wall clock. §5 is the fix.
* **perl's instruction cache thrashes**: 38.7 fills per 1000 instructions
  at 41 clocks is ~40 % of its clocks - direct-mapped conflicts inside the
  interpreter loop, not capacity. The next lever after the port.
* The simulator measures the pipeline's own share of a fill: ~8 clocks
  with a one-cycle memory. So a board fill is ~8 of CPU path, ~10 of
  bridge, ~4 words, and the rest queueing.

## 5. Build 29: the DDR3 port pipelined

`rtl/mister/ddr3_mux.sv` (commit `ae15f0d`). One transaction at a time was
the rule since the file was written; the bridge does not need it. It takes a
new command while earlier reads are still answering - `sys/ascal.vhd`'s own
Avalon master depends on that on its port - and answers reads in the order it
took them.

* **The command stage and the read queue.** A command is presented
  (`cmd_v`); the clock the bridge takes it, a write is acknowledged and a
  read is appended to `rf_*` ({master, words}), and the next command is
  presented in that same clock. Every DOUT_READY belongs to the queue's head.
* **One transaction per master, fixed order.** A pulsing master waits for
  its acknowledgement before asking again and the latch refuses a master
  still `busy`, so no master can take turns back to back: main memory first
  (the CPU stalls on every one of its transactions and never has two),
  then the display, then the download / PROM / rasteriser rotating, the
  beacon last.
* **The display's bursts are served as 16-word sub-bursts**, at most two
  outstanding (`FBR_SUB`, `FBR_AHEAD`), so its stream stays continuous and a
  CPU read waits for a few words, not 128 and a round trip. `fb_linecache`
  and `fb_fetch_arb` are unchanged: they still ask for 128 words and count
  them, and `fbr_taken` still arrives before the first word. (Shortening
  the line cache's own bursts to 32 was tried first and failed
  `tb_linecache`/`tb_fetcharb`: each burst then pays its own round trip and
  lines that need both plane sets fall behind.)
* **tb_ddr3** had been reading `DDRAM_BURSTCNT` after the clock edge, which
  only worked while the mux left it alone for a few clocks after each
  command; it samples it with the command now. Its display check is a bound
  (worst wait under 400 clocks, against ~5000 clocks of line-cache slack)
  rather than "never waits longer than the rasteriser", which only absolute
  display priority could meet. `make ddr3test_sub` runs it with 3-word
  sub-bursts. On the same traffic, main memory completed 3443 transactions
  (worst wait 47 clocks) against the build 28 mux's 827 (worst 969).

Gates: tb_ddr3 PASS, tb_ddr3 with 3-word sub-bursts PASS, tb_ramarb PASS,
tb_linecache PASS, tb_fetcharb PASS; the whole-machine simulator does not
contain the mux (sim_top has its own one-cycle memories), so the board is
the rest of the test.

Quartus, SEED=2: 38,790 ALMs (93 %), 47,408 registers, 481 / 553 M10K; core
clock setup slack +2.674 ns (build 28: +2.267), HDMI PLL +0.057 ns, every
domain and every hold/recovery/removal check met;
`output_files/sgiindy-b29-seed2.rbf` md5 `979a00fb1d22320fecc77e8acac27bab`.

## 6. Build 29 on the board

`scripts/perfprobe.sh --tag b29 --fresh ...pristine.img`, 2026-09-16 09:01,
the same workloads. Logs and reports in `tests/out/hw/perf-b29/`.

| workload | build 27 | build 28 | build 29 | b29 vs b28 | b29 vs b27 |
|---|---:|---:|---:|---:|---:|
| launch returned to the X login screen (~11 s polls) | 216 s | 171 s | **136 s** | 1.26x | 1.59x |
| root login to a settled desktop | ~67 s | ~53 s | **~47 s** | 1.13x | 1.43x |
| 60 x `/bin/ls /` | 8.76 s | 8.45 s | **6.03 s** | 1.40x | 1.45x |
| perl loop | 44.52 s | 26.60 s | **20.10 s** | 1.32x | 2.21x |
| bzip2 -9 -c /unix | 214.96 s | 150.12 s | **109.20 s** | 1.37x | 1.97x |
| dd 10 MB off the raw disk | 8.05 s | 7.74 s | **5.46 s** | 1.42x | 1.47x |
| `ls -lR /usr/lib/X11` into the Console | 16.56 s | 12.88 s | **9.28 s** | 1.39x | 1.78x |
| `xterm -e /bin/true` (cold, then warm) | - | 1.98 s, 0.77 s | **1.42 s, 0.55 s** | 1.39x | |
| `xdpyinfo > /dev/null` | - | 0.27 s | **0.20 s** | 1.34x | |

The queueing is gone: a main-memory transaction now waits 1.0 clock for the
port (15-21 on build 28) and an instruction-cache fill is on the bus 24.4
clocks (38-41). The display's line caches missed nothing in any window
(`display line-cache misses: rgb 0, aux 0`), and the desktop drew as before.
(The screenshots of both builds show the odd stray or missing pixel in a
glyph - the same kind on build 28 - so that is not the mux; the grab comes
off the scaler, not the frame buffer.)

Where the clocks go now (prof.py windows):

| workload | clocks/instr | I-cache fills /1000 | D-cache fills /1000 | writeback beats /1000 | TLB walks /1000 (I + D) |
|---|---:|---:|---:|---:|---:|
| boot | 1.76 | 10.1 | 3.2 | 6.4 | 3.5 + 4.1 |
| login | 1.99 | 15.5 | 5.5 | 9.2 | 4.5 + 7.7 |
| perl | 3.11 | **38.7** | 4.1 | 0.9 | **21.7** + 73.2 |
| bzip2 | 2.48 | 14.5 | 13.7 | 21.4 | 6.9 + 35.7 |
| scroll | 2.27 | 15.4 | 4.6 | 7.9 | 2.7 + 5.2 |
| 60 x ls | 2.17 | 16.2 | 8.7 | 17.8 | 3.3 + 5.1 |

Every fill costs ~24 clocks on the bus plus the CPU's own request and
response path, so instruction-cache fills are still the largest single cost
in every CPU workload - and, per perl, more than half of them are not misses
at all (§7).

## 7. Build 30: a refill of a line the cache holds is answered from it

**Half of perl's instruction-cache fills were not misses.** `cpu.vhd` asks
the instruction cache for a fill after EVERY instruction TLB walk, without a
lookup: by the clock the walk hands the fetch back, the fetch-path lookup
(`read_index`/`read_addrCompare`) has moved on to the next PC, so the only
thing it can do with the translated address is fill. The instruction
mini-TLB (`cpu_TLB_instr.vhd`) holds ONE page, so every fetch that crosses
into another mapped page walks - 21.7 per 1000 instructions in the perl loop,
against 38.7 fills in all - and each of those paid a whole DDR3 line fill for
a line that was usually in the cache already. Build 28 made the walk itself
two clocks; the fill behind it was still ~30.

`cpu_instrcache.vhd` now keeps a third copy of its tags (`itagramf`, beside
the two fetch-path copies), read asynchronously at the fill request's own
line. A request for a line that is there goes to state `CACHED` instead of
`FILL`: no `ram_request`, and `fill_done` two clocks later with the word on
`read_data` exactly as after a fill (the data RAM's read address is the
fill's line whenever the state is not IDLE). Not taken in a clock where a tag
write is landing (`tag_wren_a`), because the asynchronous read cannot see an
invalidate before its edge. Cost: one 512 x 21-bit MLAB.

Beacon ver 11 adds word 35 so the board can see it: {fills requested after an
instruction TLB walk, fill requests answered from the cache}
(`dbg_perf` bits 8 and 9; `bcnread.py --perf` prints 30 integers,
`perfdiff.py`/`profan.py` report the pair and still read ver 10).

### Gates

| Gate | Result |
|---|---|
| `make cpuonly` | 728 runs, 0 against expectation |
| cpu-tests suite | 2161 / 3 - the known `fpu/vec_cvt_from_l` only |
| IRIX 5.3 whole-machine boot, 230M cycles | console byte-identical to build 28's run, no PANIC, the unclaimed-bus table identical to the cycle (the whole kernel boot runs unmapped, so nothing changes before init at ~181.5M); after init: 72,432 refills requested after an instruction TLB walk, **65,172 (90 %) answered from the cache**; instruction-cache fills over the run 614,331 against 664,719 |

### What the instruction cache's geometry is worth (the simulator trace)

`sim_cputest --itrace` writes every fetch that looks in the instruction
cache (`dbg_ifetch`: the physical line), and `tools/icachesim.c` replays the
stream through other geometries. Over the IRIX boot (89.5M cached fetches,
18.9M line changes):

| geometry | misses | vs 16 KB direct-mapped (today) |
|---|---:|---:|
| 8 KB direct-mapped (builds 24-27) | 784,212 | 133 % |
| **16 KB direct-mapped** | 588,454 | 100 % |
| 2 x 8 KB | 464,928 | 79 % |
| 32 KB direct-mapped | 385,019 | 65 % |
| 2 x 16 KB | 298,561 | 51 % |
| 4 x 8 KB | 268,399 | 46 % |
| 64 KB direct-mapped | 228,194 | 39 % |
| 2 x 32 KB | 166,173 | 28 % |

The replay's 588,454 plus the run's 71,817 instruction TLB walks is 660,271 -
the simulator counted 664,719 fills - so the trace is faithful and the
walk-refills were the whole difference. The user-space tail of the boot (the
last window, init and the rc scripts) misses harder than the kernel: 78.7 per
1000 line changes direct-mapped, 45.7 at 2 x 16 KB, 25.9 at 2 x 32 KB. A
16 KB direct-mapped first level with a block-RAM second level of 64 KB would
answer 61 % of its misses, 128 KB 77 % - but a second way costs 14 M10K where
a 64 KB second level costs ~57.

### Build 30 on the board

`output_files/sgiindy-b30-seed2.rbf` (md5 `e05126e36faaa667686a8839123148fd`;
Quartus: 40,698 ALMs - 97 %, see below - core clock +2.628 ns, HDMI PLL
**-0.016 ns**), 2026-09-16 09:42, `tests/out/hw/perf-b30/`.

| workload | build 29 | build 30 | |
|---|---:|---:|---:|
| launch returned to the X login screen (~11 s polls) | 136 s | **114 s** | 1.19x |
| 60 x `/bin/ls /` | 6.03 s | **4.79 s** | 1.26x |
| perl loop | 20.10 s | **16.14 s** | 1.25x |
| bzip2 -9 -c /unix | 109.20 s | **103.73 s** | 1.05x |
| dd 10 MB off the raw disk | 5.46 s | 5.54 s | - |
| `ls -lR /usr/lib/X11` into the Console | 9.28 s | 9.32 s | - |
| `xterm -e /bin/true` warm | 0.55 s | 0.49 s | 1.12x |
| `xdpyinfo > /dev/null` | 0.20 s | 0.19 s | |

(The cold `xterm` read 2.04 s against 1.42 s; it is the run that loads the
binary off the disk, the only one this change cannot touch, and the board had
been rebooted just before this run - see §8.)

| workload | I-cache fills /1000 (b29 -> b30) | refills after an instruction TLB walk /1000 | answered from the cache | clocks/instr (b29 -> b30) |
|---|---:|---:|---:|---:|
| boot | 10.1 -> 7.2 | 3.9 | 91.0 % | 1.76 -> 1.69 |
| login | 15.5 -> 10.9 | 4.4 | 87.7 % | 1.99 -> 1.84 |
| perl | 38.7 -> 25.1 | 21.4 | 84.1 % | 3.11 -> 2.71 |
| bzip2 | 14.5 -> 8.3 | 6.8 | 95.9 % | 2.48 -> 2.38 |
| scroll | 15.4 -> 12.3 | 2.3 | 78.3 % | 2.27 -> 2.09 |
| 60 x ls | 16.2 -> 10.7 | 3.2 | 91.5 % | 2.17 -> 1.91 |

No display line-cache misses in any window, no panic.

**The fit was too big to keep.** The third tag copy as an asynchronously read
MLAB is ~430 ALMs (320 of memory, ~105 of read mux - the same as each of the
two fetch-path copies), and the fit came out at 40,698 ALMs, 97 % of the
device, with the HDMI PLL's output clock 16 ps short. Build 30b (`cc68149`)
puts that copy in block RAM (`mem.dpram`, two M10K) with a registered read: a
fill request waits one clock in `CHECK` for the tag, so a refill answered
from the cache takes three clocks instead of two and a real fill one more of
~30. Gates: `cpuonly` 728 / 0; cpu-tests 2160 / 3 (the known
`fpu/vec_cvt_from_l`; `cp0/compare_sets_ip7` took its "timer did not fire"
path - the test reads Cause before Count in its wait loop, so Count can pass
the deadline between the two reads and the loop exits with IP7 unseen: one
check fewer, still PASS, a race in the test).

IRIX gate for 30b: console byte-identical to build 30's run, no PANIC, the
unclaimed-bus table the same addresses, kinds and counts with every cycle
number ~12,000 later (the kernel boot's real fills each wait the extra
clock); 63,971 of 70,732 refills after an instruction TLB walk (90.4 %)
answered from the cache.

Quartus, 30b: 38,919 ALMs (93 %, the instruction cache 972 ALMs against 1,402)
and 483 M10K; core clock +3.031 ns but the HDMI PLL -0.141 ns at SEED=2 - that
domain is the MiSTer scaler's 148.5 MHz output and misses or meets by a tenth
of a nanosecond from seed to seed on this design whatever the CPU does (build
28 +0.127, 29 +0.057, 30 -0.016), and a miss there drops pixels at fixed
screen positions (`scripts/build.sh`). **SEED=3 meets everything:** HDMI PLL
+0.143 ns, core clock +3.091 ns, 38,846 ALMs, 483 M10K;
`output_files/sgiindy-b30b-seed3.rbf` md5 `aea29ae92655eb59a8fa88549f2c5f31`.

30b (SEED=2 bitstream) on the board, `tests/out/hw/perf-b30b/`:

| workload | build 30 | build 30b |
|---|---:|---:|
| launch returned to the X login screen (~11 s polls) | 114 s | 125 s |
| 60 x `/bin/ls /` | 4.79 s | 4.86 s |
| perl loop | 16.14 s | 13.67 s |
| bzip2 -9 -c /unix | 103.73 s | 104.22 s |
| dd 10 MB off the raw disk | 5.54 s | 5.42 s |
| `ls -lR /usr/lib/X11` into the Console | 9.32 s | 8.98 s |
| `xterm -e /bin/true` (cold, then warm) | 2.04 s, 0.49 s | 1.46 s, 0.51 s |
| `xdpyinfo > /dev/null` | 0.19 s | 0.19 s |

The SEED=3 bitstream (`tests/out/hw/perf-b30b3/`, first released as SGIIndy_20260916
and replaced under that name by build 36 the same day - docs/design/r4600-accuracy-clock-disk.md §12):
X login screen 125 s, login ~49 s, 60 x ls 4.89 s, perl 13.46 s, bzip2
101.94 s, raw disk 5.92 s, scroll 8.77 s, xterm 1.55 s / 0.51 s, xdpyinfo
0.19 s; no display line-cache misses, no panic.

The same machine within the noise - except perl, whose instruction-cache
fills went 25.1 -> 9.9 per 1000 between the two runs with nothing in the
change to account for it. A direct-mapped cache makes an interpreter loop
hostage to where its hot pages land in physical memory: two lines that
share an index ping-pong, and a different boot puts them elsewhere. Single
perl runs are therefore a noisy measure on this cache (builds 28 and 29 both
read 38.7, so the layout is often stable, but not always), and a second way
would take most of that sensitivity away along with the misses.

## 8. The board's card filled up: restores now copy in place

The first build 30 run died restoring the image: `cp: error writing
'.../SGIIndy53.img.tmp': No space left on device`. On .92 `df` said 59 G of
59 G used, `du -xs /media/fat` 22 GiB. Not cluster slack (23,667 files at
128 KB clusters is under 3 GB), no file deleted but still open, and a reboot
did not give it back - the card's exFAT allocation bitmap had ~37 GB of
clusters that belong to no file.

Every `--fresh` restore in `perfprobe.sh`, `irixrate.sh`, `hinv.sh` and
`cdread.sh` did `cp pristine img.tmp && mv img.tmp img` while MiSTer still held
the old `img` open for the core - deliberately, so a guest still running
could not write into the fresh copy. The old file was unlinked while open,
and the board's exFAT driver (exfat-nofuse 1.2.11) evidently never freed its
clusters on the last close: about eighteen such 2 GB replacements over two
weeks is the 37 GB. (A strong hypothesis rather than a proof - but the
arithmetic fits and nothing else on the card accounts for it.)

The four scripts now load the menu core first (`load_core
/media/fat/menu.rbf` into `/dev/MiSTer_cmd`), which closes the image and
stops any guest, wait until no `/proc/*/fd` names it, and `cp` the pristine
image over it in place - no rename, and no free space needed, which is how
the build 30 run went ahead on a card with 0 bytes free. The orphaned space
comes back only from a repair with the card out of the board (`chkdsk /f`,
or `fsck.exfat` on another machine): the MiSTer's own root filesystem is a
file on that partition, so it can never be unmounted from the board itself.
