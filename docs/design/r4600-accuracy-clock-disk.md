# The CPU against real Indys, the clock, and the disk byte path

Written 2026-09-16. Three requests: make the CPU accurate against the cpu-tests
suite now that the suite has been validated on real SGI hardware (the resume
note's "Goal 1"), look at the clock ("I don't think our clock is correct on
this system"), and keep going on speed with IRIS as the yardstick ("Goal 2").

| | before | after |
|---|---|---|
| cpu-tests, R4600 case, simulator | refused the CPU (rc=127); with an R4600 case 2096 / 54, 12 tests | **2259 / 0**, 246 tests |
| cpu-tests on the board (suite ROM as the PROM) | 2102 / 54 on build 30b - the same 12 tests as the simulator | **2264 / 0**, 251 tests (build 36) |
| the clock IRIX boots with | 1996-02-12 12:00 on every load, then its last shutdown time | the MiSTer's clock |
| SCSI DATA phases in the boot window | 23.3 s for 42 MB (build 31) | **11.2 s** (build 36, §12) |
| clocks per instruction, boot / login | 1.67 / 1.89 (build 31) | **1.59 / 1.70** (build 36) |
| launch to the X login screen | 125 s | **102 s** (build 36, released as SGIIndy_20260916) |

## 1. The suite learns the R4600 (`../iris` branch `claude/r4600-cputests`)

The suite selects expectations by PRId and knew imp 0x04 (R4400) and 0x23
(R5000); this core presents as an R4600 (0x2020, forced by IRIX 5.3's
hard-coded 32-byte data-cache line, docs/39). The branch, in the iris repo:

| commit | what |
|---|---|
| `c0349bf` | Dani's old local patch (iris branch `unknown-work`), captured and rebased |
| `93159ca` | `CPU_R4600` as its own kind, `is_r4600()` / `has_mips4()`, and `cpu-tests/docs/r4600.md`: where every R4600 answer comes from |
| `7d106f9` | `excep/cp0_unusable_user`, `excep/cp0_usable_cu0` (§3) |
| `eb255ff` | `identity/config_k0` back on, its K0 sweep kept in registers (§4) |
| `980b840` | `mem/load_then_use`: the instructions right behind a load, cached and not (§6) |
| `4dd5585` | README: the tests added since the oracle runs, not yet on silicon |
| `5f0c1b2` | `mem/load_then_trap`, `mem/load_then_more`, `fpu/trap_behind_a_load` (§6) |

The branch is local to this machine: the iris `origin` is
`techomancer/iris`, and nothing was pushed there.

`docs/r4600.md` sorts the R4600's expectations into classes, because no R4600
has run the suite: **documented** (PRId/FIR imp 0x20, 16 KB caches with 32-byte
lines in two ways, 48 TLB entries - IDT data sheet, IRIX's hinv); **both
oracles agree** (every unconditional test: the R4400 rev 6.0 and the R5000
rev 1.0 give the same answer, so the R4600 is held to it - including the
`fpu/denorm_*` group, where the R5000's *reported* observations are
byte-identical to what the R4400 *asserts*); **ISA level** (the R4600 is MIPS
III and refuses MIPS IV like the R4400); and **unknown** - a partial `LWR`,
where the two measured parts differ (the R4400 keeps the upper half of rt, the
R5000 sign-extends), so an R4600 passes with either and the log names which.
This core sign-extends.

## 2. Four "corrections" that the real Indys proved wrong

The SGI edits to the vendored CPU had been made to match the suite's old
expectations. When the suite ran on real hardware (iris `5150db0`) sixteen of
those expectations turned out wrong - IRIS and the suite had agreed with each
other - and four of this core's changes were fitting them. Each is reverted to
what upstream (N64/KI) already did, or corrected to what silicon does:

| commit | change | silicon |
|---|---|---|
| `8d94204` | `cpu_FPU.vhd` NaN polarity back to upstream, in all four places | the R4000 family uses the legacy MIPS encoding: fraction MSB **set** = signalling. `0x7FC00000` in arithmetic is Invalid (trapped, or the default quiet NaN `0x7FBFFFFF` and Flag.V); `0x7FA00000` is a quiet NaN the part will not propagate in hardware (Unimplemented Operation, no flag); compares signal on `0x7FC00000` for every predicate, on `0x7FA00000` only for the signalling ones. The suite's `F_QNAN`/`F_SNAN` macro names follow IEEE 754-2008 and invert that - read the bit patterns, not the names |
| `c845707` | MIPS IV COP1 function codes reach the FPU again | a COP1 word is dispatched to the FPU, which answers Unimplemented Operation (`EXC_FPE`); Reserved Instruction is for undecodable main opcodes (MOVCI, COP1X) |
| `a420b9c` | COP2 is Coprocessor Unusable only with `Status.CU2` clear | with CU2 set, `mfc2` takes no exception on either part |
| `45a8933` | `cvt.s.l`/`cvt.d.l` refuse sources beyond ±2^53 (upstream: the N64 R4300's ±2^55) | both parts trap 2^53+1 and 2^62+2^10 and convert 2^40+1. The "56-bit truncation" comment was never reachable |

Gates: `cpuonly` 728/0 after each; the suite 2096/54 -> 2133/17 -> 2143/7 ->
2150/0. **The IRIX simulator boot of these four is byte-identical to build
30b's** - console, unclaimed-bus table, and every performance counter to the
unit: an IRIX boot never reaches these corners.

## 3. CP0 was usable from User mode

Not something the suite could see: every test ran in Kernel mode. The
N64-derived core executed MFC0/MTC0, the TLB instructions, ERET and CACHE in
any mode, so any IRIX user process could write Status and make itself the
kernel. R4000 manual chapter 5: usable in Kernel mode (which EXL and ERL force)
or with `Status.CU0`, otherwise Coprocessor Unusable with `Cause.CE = 0`.

The suite test (`excep/cp0_unusable_user`) maps a scratch page at kuseg
0x00400000, ERETs into it with KSU = User (then Supervisor), runs `mfc0` and
`tlbp` there and comes home through a `syscall`; a test-local exception hook
steps over faults in the mode they came from and gives up after eight, so a
broken CPU cannot hang the run. A control (only the syscall) proves User mode
was entered. On build 30b: control passes, the three accesses execute (6 failed
checks).

The fix (`ba434ec`) had to move. **A decode-time check does not work**: the
first instruction after an ERET is decoded while that ERET is still on its way
through - with EXL, and so Kernel mode, still set - so it let exactly the
instruction a user program starts with through (the test stayed red). It is
`EXCTYPE_COP0U` in `exceptionNew3`, in execute, with the COP0 read/write, TLB,
ERET, LL-clear and cache-command enables gated by the same `COP0_usable` where
execute registers them. Suite 2164/0.

## 4. `identity/config_k0`, and the suite's cache handling

Dani: "there is a small issue with the test suite related to caching not being
handled correctly with some of the tests". The one documented case is
`identity/config_k0`, disabled upstream on 2026-09-12: it swept Config.K0 while
GCC's spill of `orig` sat dirty in the D-cache, so an uncached reload read
pre-spill RAM and the restore wrote a wrong K0 - a real hazard on hardware too,
which the Indy survived by luck. The rewrite keeps everything between the first
MTC0 and the restore in registers (no load, store or call), with one failure
bit per K0 value. It passes on this core, which serves instruction fetch
uncached while K0 = 2 inside the loop.

Nothing else cache-shaped differed: the R4600 suite on the board and in the
simulator failed exactly the same checks (§7). `cp0/compare_sets_ip7` sometimes
*reports* "timer did not fire" - always in the simulator, on the board with
build 31 but not with build 30b: its loop reads Cause, then Count six
instructions later, and exits once Count is past the deadline, so a deadline
that falls between the two reads is never seen (b31's board run: Count passed
it by one). That window exists on silicon too at these instruction rates; it is
a race in the test, not a missed interrupt.

## 5. The clock

**What was wrong.** `sgi_ds1386.sv` has no battery and had no time source: it
powered up at `POR_YEAR 0x56` - 1996, the year register counts from 1940 - on
every load. IRIX then says "time of day clock behind file system time -
resetting time" and runs from its root file system's last-write time, so the
machine always believed it was the moment of its last shutdown. The *rate* was
never the problem: the PLL is 50.000000 MHz from the board's 50 MHz, `ce` is
tied high, and the RTC and the 8254 divide it exactly.

**The fix** (`8827ce2`). hps_io's `RTC` output - the MiSTer's clock, sent by
Main_MiSTer's `send_rtc()` once when the core starts: BCD seconds to year of
the century and a binary weekday, bit 64 toggled at the end of the command -
goes through `sgi_indy.sv` to the DS1386, which loads its time registers from
it (year - 1940; weekday Sunday-0 to Monday-1; hundredths cleared). A time that
arrives while the machine is in reset (boot.rom's download holds it for 65,535
clocks) loads when reset releases, and once the host has set the clock a reset
no longer restores the power-on date. Software writes still win. The simulator
ties the input to zero so its IRIX boot console stays comparable to a control.
`make -C verilator tb_ds1386` checks every field, the 1940-based year across
1940 / 1999 / 2000 / 2039, the weekday, a time sent during reset, resets
keeping the time, and software writes.

**The time zone.** Main sends *local* time (board .92 runs EST5EDT), and that
is what the part now holds. IRIX keeps its hardware clock in GMT and applies
`/etc/TIMEZONE` - `TZ=PST8PDT` on the install - so for IRIX to show the
MiSTer's time, set `TZ=GMT0` there (the zone then reads "GMT", and the
MiSTer's own DST changes carry through). The alternative - an OSD UTC offset so
IRIX can keep a real zone - needs changing twice a year.

**Measured** with `scripts/clockprobe.sh` (new): boots IRIX, logs in, quits
Software Manager, types `date >> /root/clock.txt` twice across a host-timed
gap, halts, and reads the file off the image. (Its first run lost both
readings: typed ~50 s after the login, they went to Software Manager, which
opens ~30 s after a root login and takes the focus. It now quits it first, as
perfprobe.sh does.)

Build 30b, the released core (`tests/out/hw/clockprobe-b30b.txt`), booted
at 14:11 EDT on 2026-09-16:

| | |
|---|---|
| host UTC at the first `date` | 2026-09-16 18:17:30 (11:17:30 PDT) |
| what IRIX said | **Mon Aug 31 18:57:34 PDT 2026** - the pristine image's last write, 15 days and ~8 hours behind |
| host gap between the two readings | 313.32 s |
| IRIX's gap | 18:57:34 -> 19:02:47 = **313 s** |

So the rate is right to the reading's one-second resolution, and the date is
the image's shutdown time. Build 31: §7.

## 6. Speed: where the time goes now, and the disk byte path

**Login to a settled desktop is ~29 s, not "~49 s".** perfprobe's login
capture runs with `--min 45`, so it cannot stop earlier; recomputing the idle
fraction per second from build 30b's own capture (`tests/out/hw/perf-b30b3/
perf-login.bin`): 0-28 s almost entirely busy, 29-33 s idle, 34-41 s busy again
(Software Manager's timed start), idle from 42 s. IRIS takes ~3 s, so this
phase is ~10x slower where the boot is ~4x.

In that window (47 s capture): 27 MIPS at 1.85 clocks per instruction;
instruction-cache fills 11.0 per 1000 instructions at ~24 clocks each (~0.27
clocks per instruction), data-cache fills 5.0 (~0.12); and **`us_delay` - the
WD33C93 driver busy-waiting on the disk - 9.8 % of all samples**, with 9.93 MB
through DATA phases in 5.01 s and 2.64 s of target wait.

**The byte path, measured by stage.** 5.01 s for 9.93 MB is ~25 clocks a byte.
Reading the RTL: the initiator (`wd33c93.sv`) waits out scsi.v's RAM access in
`ST_SAT_DIN` (DIN_SETTLE, ~8 clocks), hands the byte to the DMA engine and
raises ACK (~5 more with the target's REQ timing); and `hpc3_scsi_dma.sv` wrote
**every byte as its own main-memory transaction** - D_RUN, D_MEM_WR, the DDR3
round trip (~10 clocks holding the port plus one queued on the board), D_ADVANCE:
about half of the total.

**Word batching** (`hpc3_scsi_dma.sv`, build 32 candidate): DATA IN bytes
collect in a 64-bit word written once - when its last lane fills, at the
descriptor's last byte, when the target ends the phase, when the channel is
stopped or flushed, or after 1024 idle clocks - and DATA OUT reads a word once
and serves the rest of its bytes from it. The controller still gets an
acknowledge per byte and cbp/bc still advance per byte, so every register a
driver reads is unchanged; what changes is that a byte can reach memory up to
seven bytes later, never past an event a driver could act on. Expected: ~25 ->
~16 clocks a byte.

**The load stall.** Every load held execute one clock (`stall3` until
`datacache_readdone`), even when the next instruction does not read the loaded
register (`bench/ld_cached` 944 ticks per 1000 instructions against
`st_cached` 500). A static count over the IRIX 5.3 kernel's text (`unix.ecoff`,
409,902 instructions) says most of that is waste: **24.8 % of the instructions
are loads, and only 19.8 % of those loads are followed by an instruction that
reads the loaded register**. Requiring the next instruction to also not be a
load or store still leaves 44.8 % of loads free - about 11 % of all
instructions.

`LOAD_NO_STALL` (build 33 candidate) lets a load leave execute without holding
it when the instruction being decoded behind it neither names the loaded
register in its rs/rt fields nor is a memory instruction (primary opcode
0x20-0x3F, or LDL/LDR). Such a load goes to stage 4 and the next instruction
executes in the same clock. What it took:

* **Execute** (`cpu.vhd`, `loadMayRun`): the stall is set only when the rule
  fails. LWC1/LDC1, COP0/COP2 reads, a load that walks the TLB (the hoisted
  `TLB_dataStall` clears the flag) and a faulting load keep stalling.
* **Forwarding**: for a load that did not stall, stage 4 keys
  `writebackForwardValue1/2` to `decSource` - the instruction entering decode
  on the same clock - as for any other instruction, not to `decodeSource`.
* **The D-cache read path**, which assumed execute stayed frozen for the
  whole read. Two things moved with the next instruction: the data RAM's
  read address in the load's first stage-4 clock (it selects the word
  READWAIT returns after a store), now held by `read_ena` the way a store's
  is held by `write_ena`; and the byte offset `read_data` is shifted by when
  a read finishes outside IDLE (READWAIT, the end of a FILL), now captured
  with `ram_reqAddr` when the read is issued. For a load that stalls, both
  are what they were. Nothing else in the cache reads `RW_addr` outside IDLE,
  and requiring the next instruction not to be a memory access means nothing
  reaches stage 4 behind a load until the load is done there - one access at
  a time, as before.
* A load that is still in flight when the next instruction raises an
  exception completes first: the exception holds until the stall ends, as it
  already did behind a stalled FPU command. Stage 4 has no exceptions of its
  own: no bus error reaches the CPU (`rtl/sgi/sgi_indy.sv` logs an unclaimed
  cycle rather than faulting it). If one is ever wired as a synchronous DBE,
  an uncached load must go back to stalling.

Gates: cpuonly 728/0; the suite 2187/0; and the suite extended with
`mem/load_then_trap` (syscall, break, teq, add overflow and a reserved
instruction right behind a load), `mem/load_then_more` (an mfc0, a ddivu, a jr,
a load and a store two instructions behind, a store-then-load READWAIT) and
`fpu/trap_behind_a_load` (iris `5f0c1b2`), 2259/0 over 246 tests - on the
control that stalls every load as well, so the new tests are not written to
this core. The suite ran 61,313 fewer cycles (1.5 %; "execute held" -4.8 %) for
the same instruction count, fills and bus transactions.

## 7. Build 31 on the board

Build 31 = §2 + §3 + §5 (commit `8827ce2`), SEED=3:
`output_files/sgiindy-b31-seed3.rbf`, md5 `57e0243875dcfa8c4c519edaa284e641`,
4,458,868 bytes; 38,850 ALMs (93 %), 47,509 registers, 483 M10K; core clock
setup slack +2.482 ns (30b: +3.091), HDMI PLL +0.265 ns, every domain met.

**The card could not take it.** It is full (§8 of docs/design/cpu-speed-tlb-icache.md: ~37 GB of orphaned
exFAT clusters, 0 bytes free), and this rbf is 2,420 bytes bigger than the 34
clusters `_Unstable/SGIIndy.rbf` owns, so an in-place copy would have died
half-written and left no core. It runs from the board's RAM instead:
`scp` to `/tmp/SGIIndy.rbf`, and `MISTER_RBF_PATH=/tmp/SGIIndy.rbf` makes
`launch_unstable_core.py` - and so every board script - load it through
`/dev/MiSTer_cmd` with no reboot (`0575ee6`). A MiSTer reboot empties `/tmp`.

| | build 30b (release) | build 31 |
|---|---|---|
| cpu-tests R4600 suite, suite ROM as the PROM | 2102 / 54 (244 tests) | **2192 / 0 (248 tests)** |
| `excep/cp0_unusable_user`, `cp0_usable_cu0`, `identity/config_k0`, `mem/load_then_use` | - | PASS |
| bench: i_cached / ld_cached / ld_miss / count_rate | 500 / 944 / 13 / 49,999,991 | 500 / 945 / 13 / 49,999,981 |
| IRIX 5.3 boot to the login screen | yes | yes (135 s from the load, with fsck) |
| what IRIX says the time is | `Mon Aug 31 18:57:34 PDT 2026` at 18:17:30 UTC | `Wed Sep 16 07:35:58 PDT 2026` at 18:35:58 UTC - the MiSTer's 14:35:58 EDT, held as GMT |
| IRIX time over a host-timed gap | 313 s / 313.32 s | 103 s / 103.24 s |

Logs: `tests/out/hw/cputest-r4600-b30b.log`, `cputest-r4600-b31.log`,
`clockprobe-b30b.txt`, `clockprobe-b31.txt`.

## 8. Build 32 on the board: the DMA word batching

Build 32 = build 31 + `ca99a6b`, SEED=3: `output_files/sgiindy-b32-seed3.rbf`,
md5 `bb3f803c805e7f118aa74f9db74592b8`; 38,969 ALMs (93 %), 47,963 registers,
483 M10K; core clock setup slack +3.003 ns - but **HDMI PLL -0.094 ns**, so it
is a measurement build, not a release. The failing path is in the framework's
HDMI output, nowhere near the disk path it was built to measure.

`scripts/perfprobe.sh --tag b32 --fresh` (`tests/out/hw/perf-b32/`), against
build 31 on the same pristine image an hour earlier:

| | build 31 | build 32 |
|---|---:|---:|
| launch to the X login screen (11 s polls) | 125 s | **113 s** |
| boot window: SCSI DATA phases | 23.27 s for 42.21 MB | **12.70 s** for 42.39 MB (1.84x) |
| boot window: target wait (card, via the block cache) | 13.83 s | 10.67 s |
| login: DATA phases | 5.10 s for 9.91 MB | 2.95 s for 10.08 MB |
| `rawdisk` (dd of 9 MB off the raw device) | 5.49 s | **4.40 s** (DATA 3.30 s -> 2.20 s) |
| `bzip2 -9` of /unix | 104.5 s | 103.9 s (DATA 2.63 s -> 1.57 s) |
| fork / scroll / xterm | 5.9 / 8.7 / 1.4 s | 4.9 / 8.8 / 1.3 s |
| `perl` loop | 13.6 s | 15.3 s - see below |

DATA IN went from ~25 clocks a byte to ~15, as expected.

**The bytes are the right bytes.** A benchmark cannot say that, so
`scripts/diskcheck.sh` (new, with `tools/misterdeploy/sumcheck.py`) has IRIX
itself checksum files with `sum` and `sum -r` - reads through the WD33C93 and
the DMA engine - and `cp` the 3.2 MB kernel to a new file, then halts; on the
board, the same files are read straight out of the image with `efsread.py` and
compared. Build 32 (`tests/out/hw/diskcheck-b32.txt`): IRIX's checksums of
`/unix`, `libX11.so.1` and `libXm.so.1` (7.5 MB) match the image, and
`/root/unix.copy` is byte-identical to `/unix` - DATA IN and DATA OUT both
intact. Two things the script had to learn on the way: on the full card a new
file lands EMPTY ("No space left on device", and `python3` runs an empty
script without a word), so the checker runs from `/tmp`; and
`/usr/lib/libc.so.1` is a symlink, which `sum` follows and `efsread.py` does
not, so the list names `/lib/libc.so.1` now.

The perl loop is not the disk: it is pure CPU, and its instruction-cache fill
rate was 7.66 per 1000 instructions on build 30b, 9.87 on 31 and 15.08 on 32,
while its data-cache fills fell. The instruction cache is direct-mapped and
physically indexed, so how often perl's hot loop collides with itself depends
on which physical pages its text lands on in that particular boot. That run to
run spread (+-20 % on this benchmark) is itself an argument for the two-way
instruction cache the traces in docs/design/cpu-speed-tlb-icache.md already asked for.

## 9. Build 33 on the board: loads that do not stall

Build 33 = build 32 + `LOAD_NO_STALL` (§6), SEED=3:
`output_files/sgiindy-b33-seed3.rbf`, md5 `06d692c7e286521de6166058b10859e5`;
39,111 ALMs (93 %), 47,811 registers, 483 M10K; core clock setup slack
+2.260 ns, HDMI PLL +0.132 ns, every domain met.

* **cpu-tests, the extended suite as the PROM: 2264 / 0 (251 tests)**,
  including `mem/load_then_trap`, `mem/load_then_more` and
  `fpu/trap_behind_a_load` (`tests/out/hw/cputest-r4600-b33.log`).
* **diskcheck PASS**: `/unix`, `/lib/libc.so.1`, `libX11.so.1` and
  `libXm.so.1` (8.9 MB) as IRIX checksummed them, and the kernel copy
  byte-identical (`tests/out/hw/diskcheck-b33.txt`).
* **No SCSI notices** in either board boot's `/var/adm/SYSLOG` (the
  diskcheck boot and the perfprobe boot, read out of the image afterwards).
  That had to be looked at: the IRIX *simulator* boot of this RTL printed
  `NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus` once,
  and the control did not. It comes from `_sync_setup`, whose checks around
  `do_trinfo` and `wait_scintr` are timeouts in `us_delay` units wrapped
  around uncached status reads - a CPU that runs those reads faster moves
  them against the simulator's instant disk model. It did not reproduce on
  the board; the simulator question is left open, and the board boots stay
  checked for it.

perfprobe (`tests/out/hw/perf-b33/`), against build 32:

| | build 32 | build 33 |
|---|---:|---:|
| boot: clocks per instruction / execute held | 1.68 / 24.1 % | **1.64 / 19.7 %** |
| login: clocks per instruction / execute held | 1.85 / 25.6 % | **1.81 / 20.1 %** |
| `bzip2 -9` of /unix | 103.9 s | **99.5 s** (execute held 40.8 % -> 31.8 %) |
| xterm / fork / scroll | 1.31 / 4.86 / 8.80 s | 1.24 / 4.76 / 8.70 s |
| `perl` loop | 15.3 s | 13.2 s (I-cache fills 15.1 -> 9.6 per 1000: placement, see §8) |
| launch to the X login screen | 113 s | 113 s (same 11 s poll) |

Half of what the static count promised (§6 said 6-11 %). Execute holds
overlap the other stalls: a clock in which a line fill already holds the
pipeline gains nothing from execute being free. What is left is visible in
the same counters: line fills cost ~24 clocks each on the board against ~8 in
the simulator, and bzip2 spends ~0.56 of its 2.30 clocks per instruction on
them - which is §10.

## 10. DATA IN four bytes a settle (builds 34 and 36)

After the batching, a DATA IN byte still waits `DIN_SETTLE` + 1 = 7 clocks
before the WD33C93 model may even offer it to the DMA engine. The wait is
scsi.v's prefetch: after every advance of its byte counter the sector buffer's
read port is borrowed for up to three clocks to refresh the look-ahead
registers the MacLC's longword pseudo-DMA reads, and only then is the current
byte restored. So when the current byte is good, the three after it already
are. `wd33c93.sv` now takes them with it (`din_ahead`) and offers the next
three without settling; every byte still gets its own REQ/ACK, so the target
sees the same bus. Two guards: only if REQ held through the whole settle (REQ
can be seen before the counter advances, and an advance that finds the byte
three ahead in a block not yet off the card drops REQ while the look-ahead
registers still hold the block before - scsi.v's own `rd_ahead` comment is
that bug on the Mac), and only for a READ.

**Build 34** exported the bytes through scsi.v's existing `dout_pair` /
`dout_pair_next`, and that was the mistake: those carry every command's
answer - INQUIRY, MODE SENSE, the CD-ROM's TOC and sub-channel - computed
from the byte counter, and connecting them built all of it three bytes
further on. +2,249 ALMs, 99 % of the device (the CD-ROM target alone 1,414),
HDMI PLL -0.061 ns. Not releasable - but correct, and measured: diskcheck
PASS, no SCSI notices in SYSLOG, and per MB of DATA phases against build 33:

| | build 33 | build 34 |
|---|---:|---:|
| boot window | 0.299 s/MB | **0.252 s/MB** (-16 %) |
| login | 0.296 s/MB | 0.270 s/MB (-9 %) |
| `rawdisk` | 0.243 s/MB, 4.38 s | **0.209 s/MB, 4.05 s** |

~12.6 clocks a byte at boot, from ~15: the settle was never the only cost. A
byte still pays the REQ/ACK handshake and the hand-off to the DMA engine
(~6 clocks), and every eighth one a DDR3 write that queues behind the display
exactly as a CPU fill does (§11).

**Build 36** (§12) exports only what a READ needs: `dout_ahead_read`, the three
bytes straight from the sector buffers' look-ahead registers (the same terms
as the READ arms of `cmd_dout_pair` and `cmd_dout_pair_next`), and
`dout_ahead_ok`. Anything else settles on every byte, as before. In the
simulator `run-scsiwr` (READ(6), READ(10), descriptor chains, a CD-ROM READ)
takes exactly as many cycles as with build 34's full export, and `run-dma`
and `run-scsi` pass.

## 11. The display's sub-bursts: 4 words, not 16 (build 35)

A line fill costs ~24 clocks on the bus on the board and ~8 in the simulator,
and the simulator has no display behind `ddr3_mux`. That mux is pipelined
since docs/design/cpu-speed-tlb-icache.md: the bridge takes a new command while earlier reads are still
answering, and answers in the order it took them. The display asks for its
128-word line bursts as FBR_SUB-word sub-bursts with FBR_AHEAD = 2 outstanding,
so its stream never stops - and a CPU fill taken in the middle of that waits
for every word ahead of it, up to 2 x 16 = 32.

`FBR_SUB = 4` caps that at 8. The display's stream is still continuous, the
line cache still asks for 128 words and counts them; tb_ddr3 passes at 16, 8,
4 and 3, with the display's worst wait going from 45 clocks to 83 against
~5000 clocks of line-cache slack, and the board's line-cache miss counters
are the real check.

Build 35 = build 33 + that, SEED=3 (39,082 ALMs; HDMI PLL -0.145 ns at that
seed - build 36 with SEED=2 meets it). On the board (`tests/out/hw/perf-b35/`):

| | build 33 | build 35 |
|---|---:|---:|
| instruction / data line fill, clocks on the bus | 23.7 / 24.0 | **19.6 / 20.0** |
| boot: clocks per instruction | 1.64 | **1.58** |
| login: clocks per instruction | 1.81 | **1.70** |
| `bzip2 -9` of /unix | 99.5 s | **92.9 s** |
| fork / scroll / perl | 4.76 / 8.70 / 13.2 s | 4.37 / 8.29 / 12.8 s |
| xterm cold / warm | 1.24 / 0.49 s | 1.84 / 0.44 s - see below |
| display line-cache misses, every window | 0 | **0** |
| DDR3 port held by the display | 42 % | 66 % |

The cold xterm is not the change: its window in build 35 also carried 21
disk writes against 1, 2.5 times the instruction-cache fills and 76 % idle
against 89 % - something else ran then - and the warm start got faster.
cpu-tests as the PROM 2265 / 0, diskcheck PASS, no SCSI notices in either
boot's SYSLOG.

Fills still take 20 clocks, not 8. The display now holds the port two thirds
of the time, and a quarter as many words a command means four times as many
commands; what remains is the next thing to measure, not to guess.

## 12. Build 36, released as SGIIndy_20260916

Build 36 = build 35 + the READ-only look-ahead (§10), SEED=2 (SEED=3 had
missed the HDMI PLL on builds 32 and 35): `releases/SGIIndy_20260916.rbf`,
replacing build 30b, which had been published under that name the same
morning (md5 `aea29ae92655eb59a8fa88549f2c5f31`); this one is
md5 `91980dc9a94ab0f1a052f614e6a1cf6f`; 39,090 ALMs (93 %), 47,945 registers,
483 M10K; core clock +3.063 ns, HDMI PLL +0.182 ns, every domain met. The
look-ahead costs next to nothing where build 34's export cost 2,249 ALMs.

On the board: cpu-tests as the PROM 2264 / 0 (251 tests); diskcheck PASS; no
SCSI notices in either boot's SYSLOG; perfprobe (`tests/out/hw/perf-b36/`):

| | build 31 | build 35 | build 36 |
|---|---:|---:|---:|
| launch to the X login screen (11 s polls) | 125 s | 112 s | **102 s** |
| boot window: DATA phases | 23.27 s / 42.21 MB | 12.62 s / 42.50 MB | **11.17 s / 42.30 MB** |
| login: DATA phases | 5.10 s / 9.91 MB | 2.91 s / 10.02 MB | 2.62 s / 9.99 MB |
| `rawdisk` | 5.49 s | 4.44 s | **3.95 s** |
| boot / login clocks per instruction | 1.67 / 1.89 | 1.58 / 1.70 | 1.59 / 1.70 |
| line fill, clocks on the bus | 23.8 | 19.6 | 19.6 |
| `bzip2 -9` / `perl` | 104.5 / 13.6 s | 92.9 / 12.8 s | 94.4 / 12.2 s |
| scroll / fork / xterm cold / warm | 8.72 / 5.92 / 1.40 / 0.49 s | 8.29 / 4.37 / 1.84 / 0.44 s | 8.12 / 4.98 / 1.22 / 0.49 s |
| display line-cache misses | 0 | 0 | 0 |

The DATA-phase cost per MB fell 11 % from build 35 to 36, a little under
build 34's 16 % - the cheap export takes no bytes ahead for the few non-READ
commands, and the rest is run-to-run spread.

**What is left, by the counters.** Fills cost 20 clocks each on the board
against 8 in the simulator (§11); a dirty data line is still written back as
four single-word transactions, 13.7 million lines in bzip2's window; a
DATA IN byte still pays ~6 clocks of REQ/ACK and hand-off plus a DDR3 write
every eighth byte; a load followed by a store still stalls (a store behind a
no-stall load looks safe - its tag, address and data are its own - and a load
behind one does not, because the data RAM's output was held for the first).
And login-to-settled on this core is ~29 s against ~3 s on IRIS.
