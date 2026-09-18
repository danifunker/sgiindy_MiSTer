# CPU validation: the IRIS cpu-tests suite

The CPU is held to `cpu-tests`, the bare-metal MIPS III/IV test suite of
IRIS - an SGI Indy emulator written in Rust, and a separate project
(`techomancer/iris` on GitHub, BSD-3-Clause). It is the most valuable single
tool this project has: CPU correctness measured test by test, against
expectations that have been checked on real Indys, with the same binary
running in the simulator and on the board.

This document is the suite - what it is, what it covers, why it can be
trusted and how the core is held to it - and the two CPU bugs it could not
see, which only booting IRIX found. [cpu.md](cpu.md) is the CPU itself;
[cpu-tests-on-hardware.md](cpu-tests-on-hardware.md) is running the suite on
the board and on a real SGI.

## The suite

It is not forked into this repository. It lives in `cpu-tests/` in the IRIS
repository, and the scripts here find a checkout through `CPUTESTS` (default
`~/repos/iris/cpu-tests`). Keeping it upstream is what keeps it honest: it is
a general MIPS suite whose expectations come from the R4000 manual and from
silicon, not from this core.

One binary covers every CPU it knows. At startup it reads `PRId` and picks its
expectations:

| `PRId` implementation | Part | ISA | Expectations |
|---|---|---|---|
| 0x04 | R4400 (an R4000 is taken for one) | MIPS III | measured: an Indy R4400 rev 6.0 passes every test of the oracle build, 2164 checks |
| 0x23 | R5000 | MIPS IV | measured: an Indy R5000 rev 1.0 passes every test, 2135 checks |
| 0x20 | R4600 | MIPS III | inferred - no R4600 has run the suite |
| anything else | | | `UNKNOWN CPU - refusing to run`, `rc=127` |

**The R4600 case exists because of this core**, which has to present as an
R4600 ([cpu.md](cpu.md#what-it-tells-software-it-is)); before it, the suite
refused implementation 0x20. It was written on IRIS branch
`claude/r4600-cputests`, and IRIS's main branch carries it too: 246 tests. The
core's recorded runs use the branch's head, `1be0c05`, which adds four more -
`mem/load_then_load`, `mem/load_then_load_evict`, `mem/load_then_store` and
`tlb/load_then_mapped_load` - for 250. At the time of writing, the branch as
published ends one commit earlier, at `5f0c1b2`, with the 246.

With no R4600 to measure, `cpu-tests/docs/r4600.md` records where each R4600
expectation comes from:

- **documented** - `PRId` and `FIR` implementation 0x20, 16 KB instruction and
  data caches with 32-byte lines, 48 TLB entries (the IDT data sheet, and what
  `hinv` names the FPU from);
- **both oracles agree** - every test that applies to all CPUs with no CPU
  branch, the NaN rules included: the R4400 and the R5000 give the same answer,
  so an R4600 is held to it;
- **ISA level** - the `mips4/` refusals, as on the R4400;
- **unknown** - a partial `LWR`, where the R4400 keeps the upper half of `rt`
  and the R5000 sign-extends. Either passes and the log names which; this core
  sign-extends.

The same file lists what the suite does not cover on an R4600: the Watch
registers, the secondary-cache and VCE exceptions, how many ways a cache has -
a direct-mapped cache reporting R4600 geometry passes, which is exactly this
core - and `Config.EC`.

## What it needs from the machine

Almost nothing, which made it the CPU's first bring-up target, ahead of the
PROM:

| | |
|---|---|
| RAM at physical `0x08000000` | It links at KSEG0 `0x88200000` - physical `0x08200000`, 2 MB in, clear of the 512 KB window at physical 0 that aliases the bottom of RAM and holds the exception vectors - and copies itself there from wherever it was loaded |
| A console | SCC channel B through IOC2, `0x1FBD9830` (command) and `0x1FBD9834` (data), polled and never programmed: `con_init()` expects the PROM to have done that. Booted by a PROM, it also writes through the PROM's ARCS console |
| *(optional)* IRIS's test device | GIO64 slot 0, `0xBF400000`: a second console, and the exit code. Probed rather than assumed, after the suite has installed its exception handlers, because on a real Indy an empty slot takes a bus error |
| *(optional)* a disk at SCSI ID 2 | after the result, the suite writes its whole log to a fixed place on it - through the PROM's ARCS firmware if a PROM booted it, otherwise through HPC3 and the WD33C93 itself |

Nothing else: no MC programming, no NVRAM, no interrupts, no graphics.

## What it covers

At `1be0c05`, the version the core's recorded runs use:

| Group | Tests | What it covers |
|---|---:|---|
| `identity` | 5 | `PRId`, `FIR`, cache geometry, `Config.K0`, TLB size |
| `alu` | 29 | sign extension across the 32/64-bit boundary, overflow traps, shifts, logic, SLT |
| `muldiv` | 18 | multiply and divide in both widths, HI/LO, and the architecturally unpredictable cases - reported, not asserted |
| `mem` | 24 | load and store widths, the whole unaligned family at every offset, alignment faults, the KSEG0/KSEG1 alias, and what runs right behind a load: uses, traps, loads, stores and evictions |
| `branch` | 15 | every conditional, likely nullification, links, delay slots, faults in delay slots |
| `excep` | 17 | traps, Reserved Instruction, coprocessor usability - CP0 from User and Supervisor mode included - EXL and ERET, vector selection |
| `cp0` | 21 | read-only registers, reserved-bit masks, 64-bit access, `Random` and `Wired`, Count/Compare, LL/SC |
| `tlb` | 11 | round trip over every entry, TLBP, every page size, real translation, V and D bits, ASIDs, the refill vector and Context, a load behind a load through a mapping |
| `fpu` | 89 | both formats, rounding modes, traps, denormals, all 16 compare predicates, FR=0 pairing, generated IEEE-754 vectors, an FP trap behind a load |
| `cache` | 8 | geometry, index and tag round trip, cached and uncached views, hit invalidate, set conflict, self-modifying code |
| `mips4` | 13 | every MIPS IV addition: computes on the R5000, refused on the MIPS III parts |
| **total** | **250** | |

## Why it can be trusted

`cpu-tests/docs/oracle.md` is the standing rule for where an expected value
may come from, in priority order: the R4000 manual, quoted in the tests;
nothing at all where the manual is silent - those cases *report* rather than
assert; IEEE-754 vectors computed on the host in exact rational arithmetic
(`gen/fpvectors.py`); MAME and QEMU as tiebreakers; real hardware; and only as
a last resort a recording of what IRIS does, which must say so in the test.

Real hardware has since done its part. The suite ran on an Indy R4400 and an
Indy R5000 (the logs are in `cpu-tests/oracle/`). Of the 31 tests that
disagreed with IRIS on the first R4400 run, 15 were IRIS bugs and 16 were
expectations that IRIS and the suite had shared and the silicon proved wrong;
`cpu-tests/docs/gotchas.md` has them, with the other times the test rather
than the implementation was wrong.

It also tests differentially, which needs no oracle at all: every `mips4/`
test runs on every part and branches on the ISA - the instruction must compute
on the R5000 and be refused on the MIPS III parts (Reserved Instruction for
the SPECIAL, REGIMM and COP1X encodings, Unimplemented Operation for a COP1
function code) - with `mips4/mips3_control` as the negative control, so a CPU
that refused everything could not pass.

### What the silicon changed in this core

Four of this core's changes to the vendored CPU had been made to fit those
wrong expectations. Three were reverted to what upstream already did: the NaN
polarity (the R4000 family uses the legacy MIPS encoding, in which a set
fraction MSB marks a *signalling* NaN - the suite's `F_QNAN` / `F_SNAN` macro
names follow IEEE 754-2008 and invert that, so read the bit patterns, not the
names), Reserved Instruction for the MIPS IV COP1 function codes (the FPU
answers Unimplemented Operation), and COP2 unusable whatever `Status.CU2` says
(with CU2 set, `mfc2` takes no exception). The fourth was corrected to what the
silicon does: `cvt.s.l` / `cvt.d.l` refuse a source beyond ±2^53, not the
R4300's ±2^55.

The R4600 work also added tests no Indy has run yet - derived from the manual,
and listed in the suite's README as such - and two of them failed on this core
before it was fixed: `excep/cp0_unusable_user` showed the CP0 instructions
executing in User mode, and `mem/load_then_load` caught a stalled load being
released on the completion of the load ahead of it. The whole account is
[design/r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md)
§1-4 and UPSTREAM.md.

## How the core is held to it

**In the simulator**, `tests/run-cputest.sh`:

```sh
CPUTESTS=/path/to/iris/cpu-tests CROSS=mips-linux-gnu- tests/run-cputest.sh
```

builds the suite in the checkout, builds the simulator
(`make -C verilator cputest`), loads `build/cputest.elf` straight into the
harness's RAM model and starts the CPU at its entry point, with the test
device fitted and no graphics board (`--elf --testdev --no-gfx`), and writes
the console to `tests/out/r4300.log`. Its no-progress detector is set
generously, `--stuck 20000000`, on purpose: with no PROM to have programmed
the SCC, the suite's first console write spends its whole transmit-empty
budget before it gives up on the port. Extra arguments go to the simulator, so
`--no-icache` and `--no-dcache` bisect a failure onto one cache without a
rebuild.

`CROSS` defaults to `mipsel-linux-gnu-`; any MIPS GCC works, because the
suite passes `-EB -march=mips3 -mabi=n32` itself. A checkout with CRLF line
endings breaks GNU make's recipes - every line gains a carriage return the
shell then tries to run - so strip them first (`tests/hw-cputest/build.sh`
does that in its own scratch copy).

The gate is the suite's own count: `RESULT: N checks passed, 0 failed` and
`IRIS-CPUTEST-DONE rc=0`. The simulator exits with the suite's failure count,
saturated at 100, or 127 if the suite refused the CPU, and the script prints
it. The script's own exit status is `tests/compare.py`'s, which diffs the run
test by test against a reference log, `REF`, and fails if a test that passes
there does not pass here or was never reached. `REF` defaults to
`tests/baseline/iris-r4400.log`, which is not in the repository (`*.log` is
gitignored): point it at a saved run.

**On the board**, `tests/run-cputest-hw.sh` runs the same suite as the
machine's PROM and reads the log out of main memory
([cpu-tests-on-hardware.md](cpu-tests-on-hardware.md)).

| Run | Result |
|---|---|
| board, build 44 (release SGIIndy_20260918) | **2415 checks passed, 0 failed**, 255 tests |
| simulator, the current CPU RTL (2026-09-17) | **2409 checks passed, 0 failed**, 250 tests |

The board image carries five more tests, `bench/i_cached`, `bench/i_uncached`,
`bench/ld_st`, `bench/ld_miss` and `bench/count_rate`, from
`tests/hw-cputest/bench.patch`: throughput figures in `Count` ticks, one check
each, always passing. Check totals also vary between runs of the same build:
`cp0/compare_sets_ip7` makes two checks when its timer fires and one when its
bounded wait ends first, which depends on how fast the loop runs, and it
reports the second case ("timer did not fire") rather than failing it.

For scale: IRIS itself, against the same R4400 expectations, fails 124 checks
in 27 tests - every one a known IRIS finding (`cpu-tests/README.md`,
`docs/findings.md`). The emulator is not the target; silicon is.

## What the suite cannot see

It runs in Kernel mode, almost entirely in KSEG0 and KSEG1, through exception
handlers it installed itself - and the PROM is no better, since it never takes
a TLB exception. Two CPU bugs that stopped the IRIX 5.3 kernel dead passed
every test the suite had. Both were in `cpu_cop0.vhd`, and the suite still has
no test for either: `tlb/refill_context` checks the vector of a refill taken
with `EXL` clear, not one taken inside a handler. `tests/run-irix.sh` - an
installed IRIX 5.3 root booted in the simulator until the kernel prints its
banner, some two and a half million TLB refills in - is the ratchet for both,
and the board's IRIX boots are the rest.

### A TLB refill taken with EXL set

Upstream chose the refill vector by testing `Status.ERL`. The R4000 rule is
`EXL`: offset `0x000` (`0x080` for an XTLB refill) is used for a TLB refill
only when `EXL` = 0, and with `EXL` = 1 every exception, a refill included,
takes offset `0x180`. ERL is a different bit, set only by Reset, NMI and Cache
Error.

Nothing on an N64 nests a TLB miss. IRIX does it on every boot: its refill
handler at `0x80000000` reads the page table with `lw k1, 0(k0)` and
`lw k0, 4(k0)`, the page table is itself mapped, and the second load takes a
miss of its own with `EXL` already set. The kernel expects to land in the
general handler, which has the path that recovers the page table. Instead it
landed back at `0x80000000` with `EPC` untouched and ran the same two loads
forever - a loop small enough to sit in the primary caches, so no bus cycles
at all, indistinguishable from a halted machine.

The fix is one term, `excSavedEXL = '0'`, in `tlbRefillVector`. Not the live
`EXL`: the vector logic sees the exception a clock after it was accepted, and
accepting it has already set `EXL`, so the live bit sends *every* refill to
the general vector. `excSavedEXL` is `EXL` as it was before the exception,
saved on the clock `EXL` was set - the value the EPC-suppression rules in the
same file already use. `tlb/refill_context` catches the live-bit mistake at
once, reporting `refill vector = 3` where it wants 1 or 2.

### Kernel mode is EXL or ERL, not just KSU

With the refill vector fixed the kernel booted, printed its banner and started
`init` - and then wedged in its own general exception handler, re-entering it
about five million times before the run gave up.

The N64 core exported the privilege mode as the raw `Status.KSU` field. The
MIPS rule is that the processor is in Kernel mode when `KSU` = 00 **or**
`EXL` = 1 **or** `ERL` = 1. `privilegeMode` is what `cpu.vhd`'s address-region
decode uses to choose between "through the TLB" and "strip the top three bits
and go straight to the bus", and getting that choice wrong is silent: the
access completes, at the wrong physical address.

So every exception taken from user code decoded its handler's addresses with
the user table. IRIX's general exception handler keeps its scratch area in
KSEG3, reached at a fixed offset from `$zero` (`sd at, 0xa038(zero)`). With
`KSU` still User, the decode called KSEG3 unmapped and stripped the top three
bits, and the save area landed at physical `0x1FFFA000`, where nothing
answers: writes vanished, reads came back
`0xFFFFFFFF`, the handler loaded its own stack pointer as `0xFFFFFFFF`,
faulted on the first push and re-entered itself. Nothing on an N64 notices:
its handlers live in KSEG0, which the user table calls unused and which
upstream's strip then maps correctly anyway.

The fix was the correction the same file already made for `bit64mode`, moved
to where `privilegeMode` is exported. The Killer Instinct base the core is now
built on applies the same rule itself: `privilegeMode` is Kernel whenever
`EXL` or `ERL` is set.

### How they were found

Both failures produced nothing - no console output, no panic, and for the
first no bus cycles either. What turned each into a one-line fix was
reproducing it in the simulator from an installed IRIX disk rather than from
the installer: deterministic, at the same cycle every run, with no board in
the loop (`tests/run-irix.sh` is that run) - and the instruments added to find
them, which the harness keeps ([simulation.md](simulation.md)):

- **the PC entering decode** (`dbg_pc`; `--pc`, and the last 64 on every
  exit). Sixty-four PCs named the first bug outright:
  `80000000 → 80000004 → 80000008 → 8000000c → 80000010 → 80000000 → …`, the
  refill vector re-entering itself;
- **the mode each instruction decoded in** (`dbg_mode`, printed by `--pc`).
  The second bug was one line: `PC 880101a8  ksu=2 32 unmapped`, the handler's
  store into its save area decoded in User mode;
- **one line per accepted exception** (`--exc`: `Cause.ExcCode`, `BadVAddr`,
  `EPC`), and guest memory out to a file for disassembly (`--ramdump`).

Anything an instrument reads has to be assigned outside
`-- synthesis translate_off`: GHDL's synthesis drops that code, so a signal
assigned there reads as a constant in Verilator. The first `--exc` read zero
for exactly that reason, and it is why the PC tap is at decode - `pcOld2..4`
live inside the savestate export's `translate_off` block.

Diffing the PC streams of a good run and a bad one is the obvious way into a
fault like these, and `--pc-user` records every user-mode PC for it. It is the decode tap, and
the decode tap presents an instruction again on every pipeline replay; two
configurations replay in different places, so collapse consecutive repeats in
both streams before comparing. `dbg_rpc` / `dbg_retire` carry a retire-side PC
instead. The harness counts retirements with them, but `--pc-user` stays on
the decode tap, because the retire-side stream came back interleaved rather
than sequential when it was tried (`verilator/sim_cputest.cpp` says so where
they are read).

## IRIS as the behavioural oracle

IRIS is the reference for the rest of the machine as well. It is a working
Indy that boots IRIX 5.3 and 6.5 to a desktop with networking, so its device
behaviour has passed the most demanding test there is, and it has readable
models of every device this core needs - `mc.rs`, `hpc3.rs`, `ioc.rs`,
`hal2.rs`, `ds1x86.rs`, `eeprom_93c56.rs`, `pit8254.rs`, `z85c30.rs`,
`wd33c93a.rs`, `rex3.rs`, `vc2.rs`, `xmap9.rs`, `cmap.rs`, `bt445.rs`,
`mips_tlb.rs`, `mips_cache_v2.rs` - with a monitor and a GDB stub
(`gdb_stub.rs`) for stepping it alongside the core.
`cpu-tests/docs/memory-map.md` documents the physical map, including the
trap that the only RAM below `0x08000000` is a 512 KB alias of
`0x08000000`-`0x0807FFFF`, and that IRIS's unmapped space takes writes
silently, which is why its ELF loader probes both ends of every segment
before trusting a load - as this core's harness does.

Two limits are worth knowing before reaching for it. It is a functional model:
it answers what a device does, not in which clock, so it says nothing about
clock domains or bus timing. And it models the R4400 and the R5000, not the
R4600, so the paths only an R4600 identity takes - the PROM's per-family
`Config.EC` table, IRIX's hard-coded 32-byte data-cache line and its
`cachecolormask` - are beyond it; those came from disassembling the PROM and
the kernel, and from RAM dumps of the core's own IRIX boots.

## Running the suite under IRIS

```sh
cd iris/cpu-tests
make                              # build/cputest.elf
cd .. && cargo build --release
cd cpu-tests && make run          # loads the ELF straight into IRIS's RAM
```

The Makefile finds a cross toolchain as `CROSS` if set, then
`mips-linux-gnu-` (Debian and Ubuntu's `gcc-mips-linux-gnu`),
`mips-unknown-linux-gnu-`, `mips64-unknown-linux-gnu-`, and finally a rootless
install that `make toolchain-local` unpacks into `~/.local/opt`. The link is
checked: a `.got` or `.dynamic` section means the `-mno-abicalls` contract
broke, and fails the build, because the binary would fault the moment it ran
unrelocated.

Each test prints one line, and a run ends with `RESULT: N checks passed, M
failed` and `IRIS-CPUTEST-DONE rc=<failures>`, the token to match on when
scripting. IRIS's `--cpu r5000` selects the R5000. `make image` and
`run/run-prom.sh` boot the suite through the real PROM from a volume-header
disk image instead of loading it directly.

The suite is MIPS III and n32, so it will not run on an R3000; which SGI
machines it does run on is in
[cpu-tests-on-hardware.md](cpu-tests-on-hardware.md#which-machines).
