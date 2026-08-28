# The CPU in this core

An R4300i made to present as the R4400 an Indy actually shipped with. What was
built, what had to change, and what is measured. This is the document to read
before touching `rtl/cpu/`.

Status: **M1 complete, and both primary caches are on.** The `cpu-tests` suite
runs to completion under Verilator against full R4400 expectations and reports
**2161 checks passed, 3 failed across 240 tests**, against **2101 / 61** for
IRIS's own R4400. One test fails; fifteen that IRIS fails now pass. See
[Results](#results) and [Caches](#caches).

## Getting the VHDL into Verilator

Quartus compiles VHDL, Verilator does not. The prior sandbox solved this with a
5.3 MB Yosys flatten checked into the repo, which the port plan rightly refuses
to carry forward.

The answer here is **GHDL's own synthesis backend**, which emits Verilog
directly:

```sh
tools/gen_r4300_verilog.sh        # -> rtl/cpu/generated/r4300_wrap.v
```

51 000 lines, about eight seconds, regenerated from the vendored VHDL on every
build (`verilator/Makefile` has the dependency). No Yosys, no
`ghdl-yosys-plugin`, nothing checked in — `rtl/cpu/generated/` is gitignored.
Verilator lints the result with two harmless `UNSIGNED` warnings.

Three things were in the way:

1. **The Altera megafunctions.** `cpu.vhd` and friends instantiate `altdpram`,
   `altsyncram` and `altera_mult_add` out of `altera_mf`. `rtl/cpu/prim/` holds
   behavioural VHDL with byte-identical port lists. Two details matter: the
   `altsyncram` instances are configured `NEW_DATA_NO_NBE_READ`, so a port that
   reads and writes the same address in one cycle must see the **new** data —
   modelling it as read-old is a silent one-cycle-stale bug in the cache tag
   path — and `cpu_mul` needs the megafunction's two-stage latency, which
   `cpu.vhd` gives four cycles for anyway (`hiloWait <= 4`).

2. **A GHDL bug.** GHDL 6.0.0's synthesis backend raises
   `TYPES.INTERNAL_ERROR : netlists-utils.adb:166` on a `numeric_std`
   comparison whose operands differ in width. `cpu.vhd` has exactly one, in the
   64-bit supervisor-mode region decode:
   `if (value1 <= x"FFFFFFFFFF")` against an `unsigned(63 downto 0)`. Legal
   VHDL — numeric_std zero-extends — and it takes the whole CPU down. The
   generator widens the literal in its working copy; a one-line
   reproducer is in the script's comment.

3. **A record-typed top-level port.** `cpu.vhd`'s `cpu_export` output cannot be
   the top of a synthesised design, and `mem_address` is `buffer` mode. Both
   disappear one level down, which is one of the two reasons
   `rtl/cpu/r4300_wrap.vhd` exists.

## The wrapper

`rtl/cpu/r4300_wrap.vhd` flattens the port list and sequences reset.

The reset PC is the non-obvious part. `cpu.vhd` does not reset to a constant:
`SS_reset` loads a savestate shadow register `ss_in(0)` with
`0xFFFFFFFF_BFC00000`, and `reset_93` then copies `ss_in(0)` into PC. Leave
`SS_reset` low and the CPU resets to zero. The wrapper pulses `SS_reset`, then
— because `ss_in(0)` is also writable through `SS_wren_CPU` — optionally
overwrites it with a `boot_pc` input before releasing reset.

That is what lets the bare-metal suite run with **no PROM at all**: the harness
loads the ELF and starts the CPU at its entry point, the way IRIS's
`--load-elf` does. On hardware `boot_pc` is `0xBFC00000`, which is both the
MIPS reset vector and where the IP24 PROM lives.

## The byte-lane contract

This is the part that repays care. `rtl/cpu/r4300_bus.sv` has the full
derivation; the summary is that the CPU-side `mem_*` port is **not symmetric**
between reads and writes.

**Reads.** `cpu.vhd` wants the addressed data at the *bottom* of
`mem_dataRead`: the aligned doubleword shifted right by the address's byte
offset. Not a guess — `cpu_datacache.vhd:296-303` spells out the same rule for
the cached path (`read_data = cache_q_b >> (8 * RW_addr(2:0))`), and every
entry in `cpu.vhd`'s load-type writeback table agrees with it.

**Writes.** The halves swap. `cpu.vhd` presents the low-address word in bits
`[63:32]` whenever the access is 64-bit or lands in the upper half of the
doubleword, and both `memorymux.vhd:307-314` and `cpu_datacache.vhd:275-277`
undo it identically. The case that pins it down is SDR at offset 0: write mask
`"00010000"` (lane 4) carrying the register's least-significant byte in bits
`[39:32]`, for a one-byte store to doubleword offset 0.

**Byte enables are meaningless on a read.** `mem_writeMask` holds whatever the
last write left there, so a device with more than one register per doubleword
cannot select on it. `r4300_bus` therefore carries a `bus_aoff` sideband — the
access's byte offset — which is what the SCC's four stride-4 ports select on.

The adapter's comment header flagged the unaligned-load family (LWL/LWR/LDL/
LDR on the uncached path) as a likely gap, because `cpu.vhd` aligns the address
it hands the *cache* for those but not the address it puts on `mem_*`. The
suite settled it: all eighteen `mem/` tests pass, including the whole unaligned
family at every offset and every alignment-fault case. The concern was real and
the answer is that it works; the comment records both.

## What was fixed in the CPU

Eight changes, all in the vendored VHDL, all marked `-- SGI:` and listed in
`rtl/cpu/r4300/UPSTREAM.md`. `tools/diff_upstream.sh` prints the delta. These
are bugs relative to the R4000 manual, distinct from the deliberate
R4300-to-R4400 changes in the next section.

| What | Why it matters here and not on an N64 |
|---|---|
| An exception with `Status.EXL` already set no longer overwrites `EPC` or `Cause.BD` | The N64 never nests exceptions. IRIX nests one on every TLB miss taken inside a handler, and losing the outer `EPC` there means the handler returns into hyperspace |
| LWC1/LDC1/SWC1/SDC1 raise AdEL/AdES when misaligned | Upstream never set `decodeExcType` for them, so an unaligned FP access silently read the wrong bytes |
| Opcode 0x33 raises Reserved Instruction instead of decoding as a NOP | 0x33 is LWC3, removed in MIPS III; MIPS IV reuses it for PREF, and software probes for MIPS IV by executing it and catching the trap |
| `C.cond.fmt` signals Invalid on a *signalling* NaN, not a quiet one | The mantissa MSB marks a **quiet** NaN; upstream tested it the wrong way round, so comparisons signalled on qNaN and stayed silent on sNaN — the exact opposite of the rule |
| Arithmetic on an sNaN raises Invalid; a qNaN raises Unimplemented | The other side of the same polarity, R4000 manual Table 7-2 |
| The default Invalid result is a quiet NaN | Upstream delivered `0x7FBFFFFF`, whose quiet bit is clear |
| An exactly-zero sum keeps the operands' sign when they agree | `(-0) + (-0)` came out `+0`. IEEE 754 §6.3 |
| Divide-by-zero is not raised for `inf / 0` | It is only for a finite dividend. IRIS gets this wrong too |

The NaN polarity was worth checking rather than assuming, because MIPS is
famous for having reversed the quiet-NaN convention in its legacy encoding.
Both oracles agree it is the standard one here: the suite's constants are
`F_QNAN = 0x7FC00000` / `F_SNAN = 0x7FA00000`, and IRIS's `is_snan_s`
(`src/mips_exec.rs:99`) tests the mantissa MSB clear. Three independent
sources, one answer.

`Random` is deliberately **not** in that list. It wrapped at 31, correct for
the 32-entry TLB it had at the time; the test failed because it set
`Wired = 40`, an entry that part did not have. That was fixed in the test, not
the core — and the TLB has since grown to 48 for a different reason, below.

## Presenting as an R4400

An Indy shipped with an R4000, R4400, R4600 or R5000. It never shipped with an
R4300, and the R4300 is not a part any SGI software has ever been asked to
drive. So the core reports itself as an R4400PC.

The load-bearing fact is that **there is no architectural register that says
how many TLB entries a part has.** On an R4000-family CPU, software takes that
from `PRId` and nothing else. So `PRId` is not a label that can be changed on
its own: reporting `0x0440` while the TLB has 32 entries gives you a machine
that IRIX will drive as if it had 48, and the first time the kernel writes a
high index it silently corrupts a low one. Identity and TLB size are one
decision, and `PRESENT_AS_R4400` in `cpu_cop0.vhd` is that decision.

| What | Was (R4300) | Now (R4400PC) | Cost |
|---|---|---|---|
| `PRId` | `0x0B22` | `0x0440` — imp 4, revision 4.0, which is the rule IRIX and Linux use to tell an R4400 from an R4000 | one mux arm |
| `FIR` | `0x0A00` | `0x0500` | one nibble in `cpu_FPU.vhd` |
| TLB entries | 32 | **48** | one more address bit on the entry RAM (32→64 deep × 101 bits), and a worst-case sequential search of 48 rather than 32 |
| `Config` cache geometry | 16 KB/32 B I$, 8 KB/16 B D$ | 16 KB/16 B both, what an R4400 reports | one constant |
| Coprocessor 2 | a real 64-bit data latch, so `mfc2` completes | Coprocessor Unusable, `Cause.CE = 2`, whatever `Status.CU2` says | one condition |
| MIPS IV COP1 functions | Floating-Point exception, `FCSR.Cause.E` | Reserved Instruction | a five-way case in the COP1 decode |

The TLB widening was the only one with real work in it, and it was tractable
because **the TLB is searched sequentially, not associatively** — the
`TLBPROBE`/`TLBINSTR`/`TLBDATA` states walk `TLB_readAddr` through the entry
RAM. There is no bank of 32 comparators to grow into 48. What it did need was
care in three places where the old five-bit counter's natural wrap at 31 *was*
the entry count: the circular search from `TLB_fetchSource` round to
`TLB_fetchSource - 1`, the `TLB_compareEnd` that terminates it, and the
clear-all loop that starts one past the end. At six bits those wrap at 63, so
each is now explicit against `TLB_LAST`. `Random` gained a `= 0` arm as well,
so a `Wired` the part does not have bounds the counter instead of sending it
through 63..48.

Resource cost is not measured — nothing here has run through Quartus yet. The
entry RAM doubling is 3.2 kbit more LUTRAM, and the search is deeper by 16
cycles worst case, mostly hidden by the mini-TLB in `cpu_TLB_instr`/`_data`.

### The one that is a lie, and why it is a safe one

`Config`'s cache geometry now says 16 KB/16-byte for both caches while the
hardware has 16 KB with 32-byte lines and 8 KB with 16-byte lines. That is
deliberate and it is safe in the direction that matters:

- **Over-reporting a cache size** makes an index-based flush loop run over
  indices that alias onto real lines. Every line still gets flushed, some
  twice. Harmless.
- **Under-reporting a line size** makes the loop step finer than a line, so it
  issues two operations per line instead of one. Also harmless. The dangerous
  direction is a step *coarser* than a line, which skips lines — and reporting
  16 bytes against 32-byte hardware cannot do that.

Both errors are on the safe side. That argument was made with the caches off and
carried an explicit warning that it stopped being defensible the moment they
were turned on. They are on now, so it has been re-checked — and it holds, for
the reason above rather than by luck:

- The **instruction** cache is 16 KB with 32-byte lines, indexed on address
  bits 13:5. Reporting 16-byte lines makes a range flush issue two operations
  per line. `cache/icache_coherency` patches an instruction and re-runs it
  through exactly that path, and passes.
- The **data** cache is 8 KB with 16-byte lines, indexed on bits 12:4.
  Reporting 16 KB makes an index sweep run indices 512..1023, which alias onto
  0..511; every real line is flushed, some of them twice.
  `cache/index_tag_rt` and `cache/hit_inv_discards` both pass.

Making the report truthful is not free, either: `cache/geometry` asserts the
R4400's 16 KB/16-byte for both caches, so honest geometry would fail a test
that is right about the part this core claims to be. The lie is the R4400's
geometry; the truth is the R4300's. `cpu_cop0.vhd` carries this note at the
constant.

### No secondary cache — the PC in R4400PC

`Config.SC` (bit 17) is `1`, from `readValue(23 downto 16) <= "00000110"` in
`cpu_cop0.vhd`. On an R4000-family part `SC = 1` means **no secondary cache**,
which is what makes this an R4400**PC** rather than an SC.

That is a deliberate decision, not an oversight, and it is worth stating because
nothing else in the RTL says so:

- **Nothing needs building.** An L2 model is a large amount of work — tags, a
  fill path, a writeback path, and a second set of `cache` operations — for no
  benefit that any of the milestones through M6 can observe.
- **The suite already adapts.** `cache_detect()` sets `have_l2` from this bit
  (`harness/testlib.c:115`), and every `CACHE_SD` secondary-cache operation in
  the harness is gated on it (`testlib.c:121,129,140`), as is the secondary
  test in `cache.c:278`. Reporting no L2 removes those tests rather than
  failing them.
- **The dangerous direction is the other one.** `SC = 0` would advertise a
  secondary cache that does not exist, and both IRIX and the suite would then
  issue `CACHE_SD` operations against nothing.

The residual question is whether IRIX on IP24 ever infers a secondary cache
from `PRId` rather than honouring `Config.SC` — the Indy's R4400 options were
secondary-cache parts. `Config.SC` is the architectural way to answer this and
a correct kernel honours it, so the risk is low, but it is the one assumption
here that has not been tested against IRIX.

### Physical address width: 36 bits architecturally, 32 in this core

An R4000/R4400 has a **36-bit** physical address: `EntryLo`'s PFN field is 24
bits wide at `[29:6]`, which with a 4 KB page gives 24 + 12 = 36. The R4300i
is a 32-bit-physical part, and the vendored core is built that way in a place
that is easy to miss, because the CP0 register is the right width and only the
TLB behind it is not:

- `cpu_cop0.vhd:434` reads and `:775` writes `EntryLo0.PFN` as the full 24 bits,
  so a write/read round-trip **through the register** keeps every bit;
- but `:1232` stores only `phyAdr(19 downto 0)` into the TLB entry, and `:1026`
  zero-extends it back on `tlbr`. So a round-trip **through the TLB** silently
  drops PFN bits 23:20;
- and `cpu.vhd:43` declares `mem_address` as 32 bits, so even a full-width TLB
  could not put a >32-bit address on the bus.

Nothing on an Indy needs it. The IP24 physical map ends below `0x30000000`,
and no amount of memory this machine can hold reaches 4 GB. **But the
`cpu-tests` suite does not catch it either**: `tests/tlb/tlb.c` builds every
`EntryLo` from `scratch_phys()`, a real RAM address around `0x08xxxxxx`, so
the top four PFN bits are never set and the truncation is invisible. All ten
TLB tests pass over a defect they cannot see.

That combination — architecturally wrong, unexercised by the suite, and
harmless on this machine — is the shape of a bug that surfaces years later as
something inexplicable. Recorded here rather than fixed: widening it means
carrying four more bits through the entry RAM, the mini-TLBs and the bus, for
a case no Indy generates. A test that maps a PFN above 2^32 and reads it back
would at least make the limit assert itself, and is the cheap half of the fix.

### Going back

`PRESENT_AS_R4400` appears in three places — `cpu_cop0.vhd` (identity, TLB
size, `Config`), `cpu.vhd` (COP2 and the MIPS IV COP1 codes) and one nibble in
`cpu_FPU.vhd`'s `FIR`. Setting them false restores the R4300 the core is built
from, and `TLB_ENTRIES` follows automatically so the part stays self-consistent.
Both settings were tested when the presentation was written: 2155/9 as an
R4400 and 2114/9 as an R4300, the same three tests failing either way. The
R4400 figure is now 2161/3; the R4300 build has not been re-measured since the
caches came on. That is why the suite's `CPU_R4300` cell is
still worth having even though the default build never uses it.

## The suite's third CPU

*(This was the state before the R4400 presentation above; the `CPU_R4300`
support it describes is still what the `PRESENT_AS_R4400 = false` build is
tested with.)*

The suite reads `PRId` at startup and refuses to run on anything it does not
recognise — the R4300's `0x0B22` is neither R4400 nor R5000, so the very first
run printed a banner and `rc=127`. That banner was still worth having: correct
ASCII over the SCC proved the CPU, the RAM model, the byte order and the
console tap all worked before a single test had run.

`CPU_R4300` was then added to the suite, which is its documented extension
point. The additions are small and honest:

- `identity/` asserts `PRId` implementation `0x0B` (the revision is
  part-specific), `FIR = 0x00000A00`, and 16 KB/32-byte I-cache with
  8 KB/16-byte D-cache — asymmetric, unlike either SGI part.
- `tlb_entries` is a runtime value, 32 rather than 48, and everything that
  walks or bounds the TLB uses it.
- `is_r4400()` in `mips4/` became `!has_mips4()`, which is what those sites
  always meant.
- Two places accept a second answer and report which was seen, rather than
  asserting: an unimplemented COP1 *function* may raise Reserved Instruction or
  Unimplemented Operation, and the R4300's real COP2 data latch means `mfc2`
  simply works.

None of that weakens an R4400 or R5000 expectation.

**The `Config` cache-geometry fields are driven after all.** `docs/04-cpu.md`
and `docs/09-cpu-validation.md` both said the R4300i does not model them and
that geometry would read as 4 KB. It reads `0x7006E460`: IC = 2, DC = 1,
IB = 1, DB = 0, and `BE = 1`. That is 16 KB/32 B and 8 KB/16 B, the real R4300i
geometry, and it removes the concern that `realstart` would derive nonsense
refresh timing from it.

## Results

```
tests/run-cputest.sh
```

| | checks passed | failed | tests failing |
|---|---:|---:|---:|
| IRIS, R4400 expectations | 2101 | 61 | 25 |
| **this core, as R4400, caches on** | **2161** | **3** | **1** |
| this core, as R4400, caches off | 2155 | 9 | 3 |
| this core, as R4300, caches off | 2114 | 9 | 3 |

Still failing — one test:

| Test | Why | What to do |
|---|---|---|
| `fpu/vec_cvt_from_l` | `cvt.s.l` / `cvt.d.l` truncate the source to its low 56 bits, so any \|value\| ≥ 2⁵⁶ converts wrongly | Diagnosed at `cpu_FPU.vhd`'s CIS/CID stage 0 and commented there. Fixing it means widening the normalise-and-round datapath from 57 bits and re-deriving the sticky bit, since the suite checks Inexact as well as the value |

Fifteen tests pass here that IRIS fails — mostly FPU trap and flag semantics,
which `cpu-tests/docs/findings.md` already records as IRIS's own deviations
from the manual. The core should be aiming to pass those, and it does.

## Caches

**On.** 16 KB direct-mapped instruction cache with 32-byte lines, 8 KB
direct-mapped data cache with 16-byte lines, both virtually indexed and
physically tagged, and both filled over the ordinary SGI bus.

### How a fill happens

The request side was already there. `cpu.vhd` puts a fill into the same write
FIFO as any other access and tags it with `mem_size`: `"010"` is a data-cache
line, `"100"` an instruction-cache line, and the FIFO has already aligned the
address to the line. What was missing was the answer, because the caches do
not read `mem_dataRead` — they take beats on `ddr3_DOUT`/`ddr3_DOUT_READY`,
which is upstream's connection to the N64's RDRAM controller.

`rtl/cpu/r4300_bus.sv` now supplies that from ordinary bus reads: one clock of
`fill_grant`, then two or four consecutive doubleword reads issued back to
back, then `mem_done`. Each beat goes through the same address decode as
everything else, so a line that ran off the end of a MEMCFG bank or out of the
PROM gets whatever those devices answer, beat by beat, and needs no rule of its
own.

Three ordering facts are load-bearing, and two of them cost a debugging session
each:

- **`fill_grant` must not overlap a data beat.** Grant takes priority over the
  cache's beat counter, so a beat that arrives with it is dropped.
- **`mem_done` must come at least one clock after the last beat.** The data
  cache answers the access out of the line in the very cycle it sees
  `ram_done`, reading port B of a RAM whose port A is writing that last beat on
  the same edge — and for a store it merges the write in on port B on that same
  edge. Read-during-write across ports is undefined, so overlapping them makes
  the answer depend on process order. The symptom was a load of the second
  doubleword of a line coming back stale, which presented as the test suite
  jumping through a garbage pointer and taking 82,000 exceptions.
- **The tag must be the address the cache will compare against.** See
  `UPSTREAM.md`: moving the kseg0/kseg1 strip onto `mem1_address` had silently
  made the instruction cache's tag physical while its compare stayed virtual.
  Every fetch missed. It still returned correct instructions — it just read a
  whole line to answer each one, for 3.5x the bus traffic of no cache at all.

And one reset fact: **the CPU has to stay in reset until the tags are clear.**
Each cache answers `SS_reset` by walking 512 tag entries one per clock, and
neither looks at `reset_93`. The old four-clock settle in `r4300_wrap.vhd` let
the first cached access land while the data cache was still clearing, where
nothing latches it; `error_stall` fired 4096 clocks later. `SETTLE_CLOCKS` is
1024 now.

### Config.K0

KSEG0 is cacheable only when `Config.K0 /= 2`. Upstream stores the field and
lets software read it back, but nothing acts on it — an N64 never writes
`Config`. The IP24 PROM writes it constantly: it comes out of reset with K0 = 2
(uncached) and has a routine at `0xBFC04798` to switch it to 3 and one at
`0xBFC047D8` to switch it back, bracketing everything that wants the caches.

Only the encoding 2 means uncached, so every other value stays cacheable —
including the reserved 0 this core resets to, which is what the cpu-tests suite
runs with and the reason the suite is unaffected.

Measured on the PROM boot to `hinv`, four builds of the same tree:

| KSEG0 rule | bus transactions |
|---|---:|
| data cache off entirely | 3,612,073 |
| **honouring K0** | **2,945,935** |
| K0 ignored, KSEG0 always cacheable | 2,945,935 |
| KSEG0 forced uncacheable | 4,429,560 |

The last row is the control that says the gate is live at all — force it and
the machine's traffic changes completely. The middle two being *identical*
says the PROM asks for caching wherever it actually uses KSEG0, which is
exactly what those two routines are for. So honouring K0 costs this boot
nothing; it is there for the software that does not ask, which means IRIX's
early boot and any diagnostic that wants a genuinely uncached view.

(Do not read the last row as "the same as the data cache off". It is not, in
either direction: mapped pages stay cached there, and the PROM's own cache
diagnostics do a different amount of work when KSEG0 does not behave as it
asked. Treat it as "clearly different", not as a clean delta.)

### DATACACHETLBON

1, against upstream's 0, so TLB-mapped data accesses go through the data cache
too and honour the entry's coherency field. This is not optional here. With
KSEG0 cached and mapped pages bypassing the cache, the two views of one
physical page disagree: `tlb/translation_works` writes through KSEG0 and reads
back through a mapping, and failed exactly that way.

### What it bought

The suite, run four ways:

| | cycles | bus transactions | checks |
|---|---:|---:|---|
| both off | 17,138,359 | 1,977,165 | 2155 / 9 |
| I-cache only | 3,815,305 | 368,415 | 2154 / 9 |
| D-cache only | 16,125,846 | 1,813,951 | 2161 / 3 |
| **both on** | **3,497,582** | **224,774** | **2161 / 3** |

**4.9x fewer cycles and 8.8x fewer bus transactions.** The split is clean: the
instruction cache is where the speed is, and the data cache is where the
correctness is — it is what makes `cache/index_tag_rt` and
`cache/hit_inv_discards` pass, because both are D-cache tests that could not
run at all while `DATACACHEON` was low.

(The I-cache-only column is one check short because `cp0/compare_sets_ip7`
gives up after a fixed iteration count: run the loop faster and `Count` has not
reached the deadline yet, so the test reports "timer did not fire" and skips a
check. It still passes, and the shipping configuration does not hit it.)

The mixed-width `dpram_dif` sub-word ordering that `rtl/cpu/prim/dpram.vhd`
flagged as an assumption worth re-deriving against a cache test is now
confirmed by those tests: narrow word `2k` is bits 31:0 of wide word `k`.

### What it did not buy

`hinv` still reports **16 Mhz**, and that is correct rather than disappointing.
The figure comes from `FUN_bfc31594`, a 512-iteration two-instruction loop
timed with CP0 `Count`, and that loop lives at `0xBFC3159C` — KSEG1, which the
architecture defines as uncached and `fetchCache` therefore refuses to cache.
The whole PROM runs from KSEG1, so **the instruction cache does nothing for a
PROM boot at all**; the 34% drop in bus transactions above is entirely the data
cache on KSEG0.

The figure is not a clock rate and not an artefact of the simulation's fast
timebases either. Doubling `RTC_TICK_DIV` and doubling `PIT_TICK_DIV` each
leave it at 16, which rules out both the RTC and the 8254. It is a measurement
of uncached instruction throughput and nothing else.
