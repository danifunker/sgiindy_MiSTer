# 39. The R4600 swap, assessed; burst line fills and a 16 KB data cache instead

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

### 3b. The data cache: 16 KB with 32-byte lines

KI's geometry change to `cpu_datacache.vhd`, transcribed hunk for hunk into
`rtl/cpu/r4300/cpu_datacache.vhd` and marked `-- SGI:` like every other local
change (KI's write-through mode, `LITTLE_ENDIAN` generic and debug port left
out). `cpu.vhd` issues the data fill as `mem_size = "100"` at a 32-byte
address, exactly like an instruction fill, and its write FIFO went from 8 to
16 deep: a dirty line is now four beats with no ready handshake, started with
up to three entries already queued, and eight entries held seven before
`Full`.

`Config` now tells the truth: 16 KB with 32-byte lines for both caches
(`IC = DC = 2, IB = DB = 1`). docs/10 argued that under-reporting a line size
was safe, and for index-based flushes it is; but IRIX's `Create_Dirty_
Exclusive` sweeps step by the reported data line size, and a step of 16 over
real 32-byte lines marks the untouched half of a line dirty with whatever the
cache RAM held, to be written back over memory later. An R4400 takes `IB` and
`DB` as boot-mode options, so a 32-byte configuration is an R4400 too; the
one test in IRIS's `cpu-tests` that asserted 16 bytes for an R4400
(`cache/geometry`) now accepts either, with the reason in a comment.

`rtl/cpu/r4300/UPSTREAM.md` has the change list.

## 4. Gates

Every gate the plan named, plus the two the burst path added.

| Gate | Result |
|---|---|
| `make -C verilator ddr3test` (RAM master now issues 1/2/4-word bursts, checked word by word with `ram_last`) | PASS |
| `make -C verilator ramarbtest` (CPU asks bursts; port streams; `cpu_last` checked) | PASS, all latencies 0..60 |
| `make -C verilator cpuonly` (every case streamed AND word-by-word, 0..12 latency, all cache modes) | RESULTS_CPUONLY |
| `tests/run-cputest.sh` (240 tests) | RESULTS_CPUTEST |
| `tests/run-prom.sh` | RESULTS_PROM |
| `tests/run-newport.sh` | RESULTS_NEWPORT |
| `tests/run-rex3.sh` | RESULTS_REX3 |
| `tests/run-scsi.sh` | RESULTS_SCSI |

## 5. The board

RESULTS_BOARD

## 6. Traps paid for

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
