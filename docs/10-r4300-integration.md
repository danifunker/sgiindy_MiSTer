# The CPU in this core

An R4300i made to present as the R4400 an Indy actually shipped with. What was
built, what had to change, and what is measured. This is the document to read
before touching `rtl/cpu/`.

Status: **M1 complete.** The `cpu-tests` suite runs to completion under
Verilator against full R4400 expectations and reports **2155 checks passed, 9
failed across 240 tests**, against **2101 / 61** for IRIS's own R4400. Three
tests fail; fifteen that IRIS fails now pass. See [Results](#results).

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
LDR with the caches off) as a likely gap, because `cpu.vhd` aligns the address
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

Both errors are on the safe side, which is what makes this defensible while the
caches are switched off entirely. It stops being defensible the moment they are
turned on: at that point either the geometry becomes real or the report goes
back to the truth. `cpu_cop0.vhd` says so at the constant.

### Going back

`PRESENT_AS_R4400` appears in three places — `cpu_cop0.vhd` (identity, TLB
size, `Config`), `cpu.vhd` (COP2 and the MIPS IV COP1 codes) and one nibble in
`cpu_FPU.vhd`'s `FIR`. Setting them false restores the R4300 the core is built
from, and `TLB_ENTRIES` follows automatically so the part stays self-consistent.
Both settings are tested: 2155/9 as an R4400, 2114/9 as an R4300, the same
three tests failing either way. That is why the suite's `CPU_R4300` cell is
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
| **this core, as R4400** | **2155** | **9** | **3** |
| this core, as R4300 | 2114 | 9 | 3 |

Still failing — the same three in both modes:

| Test | Why | What to do |
|---|---|---|
| `cache/index_tag_rt`, `cache/hit_inv_discards` | Both caches are off. `cpu_instrcache`/`cpu_datacache` fill from the N64's RDRAM/DDR3 port, which has nothing behind it here | Revisit when the fill path is wired to SGI memory (M8). Leaving them failing keeps that visible |
| `fpu/vec_cvt_from_l` | `cvt.s.l` / `cvt.d.l` truncate the source to its low 56 bits, so any \|value\| ≥ 2⁵⁶ converts wrongly | Diagnosed at `cpu_FPU.vhd`'s CIS/CID stage 0 and commented there. Fixing it means widening the normalise-and-round datapath from 57 bits and re-deriving the sticky bit, since the suite checks Inexact as well as the value |

Fifteen tests pass here that IRIS fails — mostly FPU trap and flag semantics,
which `cpu-tests/docs/findings.md` already records as IRIS's own deviations
from the manual. The core should be aiming to pass those, and it does.

## Caches

Off. `INSTRCACHEON` and `DATACACHEON` are tied low in `sgi_indy.sv` because the
cache fill path talks to the N64's RDRAM/DDR3 controller directly rather than
through `mem_*`, and that port is tied off in the wrapper. Everything runs
uncached, single word or doubleword at a time, which costs about nine clocks
per access and does not matter during bring-up.

Turning them on is an M8-era job and needs three things: the fill path pointed
at SGI memory, the mixed-width `dpram_dif` sub-word ordering re-derived against
a cache test (`rtl/cpu/prim/dpram.vhd` documents the assumption), and the two
cache tests above.
