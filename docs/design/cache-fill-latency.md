# Where a cache line fill's clocks go, 3,000 ALMs back, and fewer trips to DDR3

Written 2026-09-16/17, resuming docs/design/r4600-accuracy-clock-disk.md's list of what was left: line fills
costing ~20 clocks on the board against ~8 in the simulator, a dirty data line
written back as four transactions, a load that still stalled behind a load,
and 93 % of the device in use.

| | build 36 (SGIIndy_20260916) | build 38 (SGIIndy_20260917) |
|---|---:|---:|
| ALMs / registers | 39,090 (93 %) / 47,945 | **37,235 (89 %) / 45,749** |
| cpu-tests on the board | 2264 / 0, 251 tests | **2415 / 0, 255 tests** |
| `bzip2 -9` of /unix | 94.6 s | **85.0 s** |
| 60 x `/bin/ls /` | 5.09 s | **3.97 s** |
| boot / login, clocks per instruction | 1.60 / 1.72 | **1.54 / 1.63** |
| launch to the X login screen | 113 s | **102 s** |
| an instruction line fill, clocks on the bus | 20.4 | **18.5** |

Board columns are the same night on the same board (§6): build 36 was run
again as a control after the board turned out to have slowed down since its
own release measurement.

## 1. A line fill's 20 clocks, accounted

The resume note asked where the ~12 clocks between the simulator's fill and
the board's go, before changing anything. Most of the answer was already
measured.

Counting the RTL clock by clock for an instruction fill (`instrcache_active`,
which is what the "clocks on the bus" counters integrate - from the write FIFO
pop to `mem_done`):

| clock | what | simulator | board |
|---|---|---|---|
| 1 | memstate pops the FIFO: `mem_request` | 1 | 1 |
| 2 | r4300_bus registers `bus_req`, `fill_grant` | 1 | 1 |
| 3 | main memory: `sim_ram` answers / `ddr3_mux` latches `pend` | 1 | 1 |
| 4 | `ddr3_mux` presents the command (`cmd_v`, `DDRAM_RD`) | - | 1 |
| 4+L | the bridge's first word, L clocks after it took the command | - | L |
| +1 | `ddr3_mux` registers `rdata_q`/`ack_q` | - | 1 |
| +1 | r4300_bus registers the beat (`fill_data_ready`) | 1 | 1 |
| +3 | the other three words | 3 | 3 |
| +1 | S_FILLEND | 1 | 1 |
| +1 | `mem_done` seen by memstate | 1 | 1 |
| | **total** | **~8** | **10 + L** |

docs/design/cpu-speed-tlb-icache.md §4 measured L - "the bridge answers a read's first word 9.7 clocks
after taking it" - with one transaction at a time, when nothing else could be
ahead of a read in the bridge. 10 + 9.7 = 19.7, and the board's counters say
19.6 (instruction) and 20.0 (data). So the display's words queued ahead of a
CPU read cost it well under a clock since FBR_SUB went to 4 (docs/design/r4600-accuracy-clock-disk.md §11); the
twelve clocks are two of `ddr3_mux`'s own registers and the bridge's latency.

That was arithmetic on an old measurement, so build 37 carries counters that
measure it directly (beacon ver 12, words 36-38): per main-memory read, the
clocks from the bridge taking it to its first word and the words owed to reads
taken before it; the same latency on reads taken with nothing owed at all,
which is the bridge alone; and gaps inside a RAM burst. tb_ddr3 computes the
same sums from its bridge model and checks the RTL agrees. Board numbers: §4.

What can be taken off the core's side of that table is §5.

## 2. 3,000 ALMs: two arrays that were flip-flops

Build 36's fit report (Fitter Resource Utilization by Entity) had two small
storage arrays at more than 3,000 ALMs between them - Quartus had built them
from registers and said nothing, the failure mode `quartus-ram-inference`
warns about.

* **`eeprom_93c56`** - 128 x 16 bits, 1,982 ALMs, 2,132 registers. The array
  was read asynchronously (the word loaded into the shifter in the clock its
  address completed) and written from four places, the reset among them. Now
  one registered write port (`wr_pend`) and one registered read (`mem_q`),
  alone in their own clocked process: a READ's word lands a clock after its
  address (`load_pending`) and a store a clock after the edge that makes it -
  both thousands of clocks before the next SK edge, which is three MC
  register writes away. The Ethernet address is written in the three clocks
  after reset, as `sgi_ds1386.sv` does.
* **`np_bt445`** - 1,056 ALMs, 2,103 registers: the 256-byte control space,
  while the gamma table beside it was an M10K all along. The difference was
  the three cursor colours, nine fixed-index reads of `ctrl`; an array with
  ten reads is not a memory block. They are three registers written alongside
  `ctrl` now (nothing connects them yet).

Both were probed with `quartus_map` on the module alone before the fit
(`altsyncram mem_rtl_0` with its power-up contents as a MIF - 127 words
erased, word 0x11 = CACHSZ_PAGES; `gamma_rtl_0` and `ctrl_rtl_0`), and both
were run A/B against the build 36 models on the same random stimulus: the
EEPROM for 5.36 M clocks and 376 k SK edges with garbage bits, CS toggles,
resets and WRAL/ERAL, the RAMDAC for 1.03 M clocks of bus traffic - no
difference in any output. `make -C verilator tb_eeprom` is new: the PROM's
Microwire protocol against a shadow copy.

Synthesis: 45,989 -> 42,292 registers. The fit: 39,090 -> 36,640 ALMs
(93 % -> 87 %) with the §1 and §3 logic added.

## 3. A load behind a load

LOAD_NO_STALL (docs/design/r4600-accuracy-clock-disk.md §6) let a load leave execute without holding it only
when the next instruction was not itself a memory access. Over IRIX 5.3's
kernel text:

| a load followed by | share of loads | share of all instructions |
|---|---:|---:|
| an instruction that reads the loaded register | 21.1 % | 5.2 % |
| a non-memory instruction that does not | 44.1 % | 10.9 % |
| **a load that does not name it** | **30.5 %** | **7.6 %** |
| an integer store that does not | 4.3 % | 1.1 % |

`LOAD_NO_STALL_MEM` (cpu.vhd, default true) lets the next instruction be an
integer load or store: LB/LH/LWL/LW/LBU/LHU/LWR/LWU, LD, LDL/LDR, SB/SH/SWL/
SW/SDL/SDR/SWR and SD. CACHE, the LL/SC family and the coprocessor loads and
stores keep the old rule. Two places had assumed it:

* **The data RAM's registered read** (cpu_datacache.vhd). A load done in IDLE
  returns the word presented a clock earlier; the load behind it now reaches
  stage 4 one clock later, so the first load's clock must present the second
  load's address. `q_addr` remembers what was presented and `q_match` says the
  RAM holds the stage-4 access's own word: a read is done in IDLE only with
  `q_match`, and otherwise holds its address and takes READWAIT. READWAIT
  presents the address of the access behind it. Every path that already
  worked has `q_match` set; the new READWAITs are a load right after a fill, a
  write-back or a CACHE command.
* **The load delay block** (cpu.vhd). A stalled load's execute hold was
  released on `datacache_readdone`. With a load ahead of it that did not stall
  and is still in READWAIT or its fill, that completion is the other load's -
  the stalled load was released before it reached stage 4, and the
  instruction that needed its value ran on the old register. The release now
  requires `datacache_readena`: its own read, issued that clock.

The second one was found by the suite, not by reading. The iris branch
`claude/r4600-cputests` gained `mem/load_then_load` (same line, two lines, the
same word at two widths, three in a row, the first load's value as the third's
base, the second's used at once, around a store, an LWL merge, KSEG1 against
KSEG0 - each with both lines cold, both warm and each warm alone),
`mem/load_then_load_evict` (the second load evicting the first's line, or
finding its own just written back), `mem/load_then_store` and
`tlb/load_then_mapped_load` (either load walking the TLB). The first build
failed `load_then_load`'s "second used" case in the cold passes and a dozen
FPU vector tests besides; LOAD_NO_STALL_MEM=false with the `q_addr` logic
passed everything, stores alone passed, loads alone did not - which pointed at
the release. With the fix: 2409 / 0 over 250 tests, the same on the build 36
control, and the same pass/fail sets with `--no-dcache` and `--no-icache`.

## 4. Build 37 on the board

Build 37 = build 36 + §2 + §3 + the counters, SEED=2: 36,640 ALMs (87 %),
44,672 registers, 486 / 553 M10K; core clock +2.438 ns; **the HDMI PLL
missed by 0.103 ns** at that seed, so build 37 was a measurement build and
not a release. `output_files/sgiindy-b37-seed2.rbf`, md5
`0deebce19cc30bd6face0acbc62056d5`.

On the board (.92, rbf staged in RAM): cpu-tests as the PROM **2414 / 0**
over 255 tests - every new load-behind test included; `diskcheck` PASS; no
SCSI notice in either boot's SYSLOG; no display line-cache miss in any
window.

**The counters, in every workload window alike:**

| | clocks |
|---|---:|
| a RAM read, from the bridge taking it to its first word | 10.4 - 10.7 |
| ...words owed to earlier reads when it was taken | 3.7 - 3.9 |
| a read taken with nothing owed (the bridge alone) | 9.4 - 9.6 |
| gaps inside a RAM burst | 0.00 |
| CPU accesses held behind a DMA transaction | 0.01 - 0.04 s per window |

So §1 holds: the bridge answers in 9.5 clocks whatever the core does, the
display's queued words add about one more, and a fill's words stream without
a gap. The display is not what makes a fill cost 20 clocks.

**The load behind a load** shows as execute held: 19.5 -> 16.6 % of the boot
window, 19.7 -> 16.3 % of login, 31.1 -> 25.1 % of bzip2; bzip2 took 89.8 s.

**And the board had changed.** Build 37's fills measured ~0.8 clocks slower
than build 36's release numbers (19.6 -> 20.4), the display held the port
71 % of the time against 67 %, and X came up an 11-second poll later. Nothing
in build 37 touches that path, so build 36's own bitstream was run again the
same night, after build 38 (`tests/out/hw/perf-b36ctl/`): 20.4 / 20.9-clock
fills, 70.8 % display, X at 113 s. The board rebooted around 21:57 that
evening (and its SD card had been repaired, 37 GB free); something outside
the core now shares the HPS's DDR3 controller more heavily - the scaler's
output mode is the first suspect, since the display share rose with it. §6
compares against that control.

## 5. Fewer trips: line writes, instruction fills, and the mux's latch

Three changes that take clocks off the core's side of §1's table, build 38.

**A dirty data line goes back as one transaction.** The data cache writes a
line back as four beats, and each beat was its own write FIFO entry and its
own trip - memstate, r4300_bus, ram_arb, ddr3_mux's latch and command, the
acknowledgement back: ~7 clocks a word, 28 a line, with the fill that evicted
it queued behind all four. Build 36's bzip2 window wrote back 13.7 M lines,
its login window 2.6 M.

* cpu.vhd issues the line when its four beats are staged, as one write FIFO
  entry: beat 0 where a write always was, beats 1..3 in new bits 299:108 (the
  FIFO is 300 bits wide, was 108), `(107) = '1'` with `(105) = '0'` as the tag.
  The staging queue pops all four at once. Consecutive beats of a line are
  consecutive words, so only beat 0's address travels.
* r4300_bus presents it as a write with `bus_burst = 4` and the other three
  words on `bus_wdata3`, each with the cache's half swap undone as before;
  ram_arb and sgi_indy pass them through.
* ddr3_mux writes the four words to the bridge as **four single-word write
  commands, back to back** - each presented in the clock the one before it is
  taken - and acknowledges the line once. No other master's command falls
  between them, and the bridge is never asked for anything it has not always
  done: an Avalon write burst would have saved nothing (four words still take
  four clocks) and would have been the first write burst this core put on the
  f2sdram port.

In the simulator (one-clock memory) the suite ran 3.9 % fewer clocks and
spent 10.5 % less time with writeback held; bus transactions fell by exactly
three per line. tb_ddr3 now makes a third of its RAM writes lines and reads
every one back as a line.

**An instruction line fill is done in the clock of its last word.**
r4300_bus's S_FILLEND holds `mem_done` back a clock after every line fill,
because the data cache answers a load out of the line in the very clock it
sees `ram_done`, reading port B of a RAM whose port A writes the last beat on
that edge. The instruction cache reads the line a clock later (its
`fill_done` is registered), so it never needed that clock. cpu.vhd tags an
instruction line `mem_size "101"`, and r4300_bus finishes it without
S_FILLEND. One clock off each of the 17 M instruction fills in build 36's
bzip2 window.

**A main-memory request goes in front of the bridge in the clock it
arrives.** ddr3_mux latched every request and presented it a clock later.
Main memory goes first, and the CPU and the DMA engines each wait for their
acknowledgement, so nearly every request arrives to an idle main-memory slot;
when the command slot is free too, the command is now loaded from the port
(`ram_now`) and the latch's `pend` is cleared on the edge that would have set
it. One clock off every main-memory transaction. tb_ddr3 completed 9,792 RAM
reads in its traffic run, against 8,425 before, every word checked.

Gates for build 38: cpuonly 728 / 0; the suite 2409 / 0 over 250 tests;
tb_ddr3 at FBR_SUB 4 and 3; tb_ramarb at latencies 1 and 60; linecache,
fetcharb, tb_eeprom.

**Tried and left out: fill beats straight through r4300_bus.** Making
`fill_data`/`fill_data_ready` combinational from `bus_rdata`/`bus_ack` puts
the last beat's write an edge ahead of `mem_done`, which would let the data
cache drop S_FILLEND too. It passed the suite (one clock off every data fill,
3.4 % of the suite's fill clocks) but adds a path from ddr3_mux's registers
through sgi_indy's 13-way read mux into both caches' M10K inputs, for about
half a percent; kept out of build 38 so a timing failure could not cost that
build. It is commit `eb7c53f` on the local branch `claude/fill-comb`.

## 6. Build 38 on the board

Build 38 = build 37 + §5, SEED=5: **37,235 ALMs (89 %)**, 45,749 registers,
483 / 553 M10K; core clock +1.401 ns, **HDMI PLL +0.178 ns**, no negative
slack in any setup, hold, recovery or removal check.
`output_files/sgiindy-b38-seed5.rbf`, md5 `93c2b5e47d6194ac9c858b3455e920cf`
= `releases/SGIIndy_20260917.rbf`. By entity: ddr3_mux 586 (build 36) -> 748
(counters) -> 1,133 ALMs (line writes, direct issue); r4300_bus 150 -> 201,
ram_arb 136 -> 188; eeprom_93c56 1,982 -> 102 and np_bt445 1,056 -> 35.

On the board: cpu-tests as the PROM **2415 / 0** over 255 tests; `diskcheck`
PASS; no SCSI notice in either boot's SYSLOG; no display line-cache miss in
any window; the desktop intact after every workload.

`scripts/perfprobe.sh` on a pristine image, all four the same board:

| workload | build 36, released | build 36, control | build 37 | **build 38** |
|---|---:|---:|---:|---:|
| launch to the X login screen (11 s polls) | 102 s | 113 s | 113 s | **102 s** |
| `bzip2 -9` of /unix | 94.4 s | 94.6 s | 89.8 s | **85.0 s** |
| 60 x `/bin/ls /` | 4.98 s | 5.09 s | 4.37 s | **3.97 s** |
| `ls -lR /usr/lib/X11` into the Console | 8.12 s | 8.18 s | 7.82 s | **7.74 s** |
| dd 10 MB off the raw disk | 3.95 s | 4.18 s | 4.00 s | **3.96 s** |
| `xterm -e /bin/true`, cold / warm | 1.22 / 0.48 s | 1.27 / 0.47 s | 1.22 / 0.45 s | 1.28 / **0.41 s** |
| perl loop | 12.2 s | 11.2 s | 12.3 s | 12.4 s |
| boot / login / bzip2, clocks per instruction | 1.59 / 1.70 / 2.18 | 1.60 / 1.72 / 2.16 | 1.61 / 1.72 / 2.02 | **1.54 / 1.63 / 1.98** |
| instruction / data line fill, clocks on the bus | 19.6 / 20.0 | 20.4 / 20.9 | 20.5 / 20.8 | **18.5 / 20.2** |
| RAM request queued in the mux, clocks per transaction | 1.0 | 1.0 | 1.0 | **0.0** |
| writeback held, boot / login / fork | 9.5 / 11.3 / 17.9 % | 9.9 / 11.5 / 17.6 % | 10.0 / 11.8 / 17.4 % | **8.4 / 9.7 / 11.5 %** |
| display holds the port | 66.5 % | 70.8 % | 70.8 % | 70.8 % |

Against the control: bzip2 -10 %, fork -22 %, login -5 % clocks per
instruction, X one poll sooner. The perl row is the interpreter's
instruction-cache placement lottery again - the control's window had 5.25
instruction fills per 1000 instructions against 10.9-11.7 in every other run.

Two readings of the counters:

* **Instruction fills lost two clocks, data fills 0.7.** An instruction fill
  lost S_FILLEND and the mux's latch clock; a data fill only the latch clock,
  and the RAM read then often waits behind the display's queued words anyway
  (§4) - taking the command a clock sooner does not bring its first word a
  clock sooner when four display words are ahead of it. cpu-tests'
  `bench/ld_miss` agrees: 107,530 -> 106,789 ticks for 8,192 data-cache
  misses, a third of a clock each.
* **The line writes show as writeback held**, 17.4 -> 11.5 % in the fork
  window, and as fewer, longer bus transactions (13.7 -> 15.6 clocks each in
  the boot window: three cheap single-word writes per line are gone from the
  average).

## 7. What is left

* **The bridge's 9.5 clocks are the floor of every DDR3 read**, and a line fill
  still costs ~18.5-20 clocks on the bus with it. What is left is fewer trips:
  an instruction cache that misses less (perl's lottery says conflicts, not
  capacity), or a fill that overlaps the latency (a sequential line fetched
  before execution reaches it).
* **Display words ahead of a RAM read, ~1 clock, and they absorb the mux's
  latch saving on data fills.** FBR_SUB 4 -> 2, or not issuing a display
  sub-burst while a CPU fill is on its way through the scheduler, would trade
  display latency (5,000 clocks of slack) for it; the counters now measure
  both sides.
* **Fill beats straight through r4300_bus** (§5, branch `claude/fill-comb`,
  not fitted): one more clock off every data fill.
* **The scheduler in front of the FIFO**: a cache's request reaches `mem_request`
  three clocks after its pulse (issue_pending, the FIFO write, the pop); a
  bypass when both are empty would take two off every transaction.
* **The disk**: 11.2 s of DATA phases in the boot window, ~13 clocks a byte -
  REQ/ACK per byte between wd33c93.sv and scsi.v, and the look-ahead only
  batches four. A READ's sector could move to the DMA engine a word at a time.
* **Area**: sgi_hpc3's register arrays (3,671 ALMs of its own, reset by loops,
  read twice per access) are the next flip-flop storage.
* **The board slowed down** between 18:00 and 23:30 with the same bitstream
  (§4); worth finding what shares the DDR3 controller now.
