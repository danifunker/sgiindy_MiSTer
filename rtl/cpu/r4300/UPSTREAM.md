# Vendored MIPS CPU — the Killer Instinct R4600

These files come from **`MiSTer-devel/Arcade-KillerInstinct_MiSTer`**, `rtl/cpu/`,
at commit `5c443bd` (2026-09-05). That CPU is itself a fork of the MiSTer N64
project's R4300i (`MiSTer-devel/N64_MiSTer`, `rtl/`), which was this core's base
until 2026-09-07 (at `adbf9b5d41bcc8b6dc3ad00821e2cd062847ab4f`); every local
change made on the N64 base was carried across (docs/43-44). Licence: GPL-3.0,
which is why this repository is GPL-3.0 — see `LICENSE`. The directory is still
called `r4300/` because nothing outside it cares what the part calls itself.

VHDL is vendored, not a netlist: Quartus compiles VHDL directly, and
`tools/gen_r4300_verilog.sh` lowers the same sources to Verilog for Verilator
with GHDL's synthesis backend. There is deliberately no checked-in Yosys
flatten to drift out of sync.

## Files

| File | Role |
|---|---|
| `cpu.vhd` | pipeline, decode, register files, the `mem_*` port |
| `cpu_cop0.vhd` | CP0, exceptions, TLB registers |
| `cpu_TLB_instr.vhd`, `cpu_TLB_data.vhd` | the two TLB lookup engines |
| `cpu_FPU.vhd`, `cpu_FPU_sqrt.vhd` | the FPU |
| `cpu_instrcache.vhd`, `cpu_datacache.vhd` | primary caches, 32-byte lines: the D-cache 16 KB physically indexed, the I-cache 8 KB (one R4600 way - see "The instruction cache") |
| `divider.vhd` | integer divider |
| `functions.vhd`, `export.vhd` | `pFunctions` / `pexport` packages |
| `SyncFifoFallThroughMLAB.vhd` | the CPU's write FIFO (KI's, with its accept handshake) |

`rtl/cpu/prim/` holds behavioural replacements for the Altera megafunctions
these files instantiate (`altdpram`, `altsyncram`, `altera_mult_add`), so the
CPU builds without `altera_mf`. KI ships its own `dpram.vhd` / `RamMLAB.vhd`
(altera_mf) and a separate 29-line `cpu_mul.vhd` (a one-stage behavioural
64x64 multiply); none of the three is vendored — `prim/cpu_mul.vhd` is the
two-stage stand-in for the N64's `altera_mult_add`, which is what has been
fitted and timed, and `cpu.vhd` waits four clocks for the product either way.

## What the Killer Instinct base brings

Relative to the N64 R4300i it was forked from (`tools/diff_upstream.sh` run
against an N64 checkout shows all of it), the parts that matter here:

* **Timing work for 100 MHz**: the I-cache index is produced by one flattened
  mux (`FetchIndex1/2`, `read_index1/2`) with two fetch-address paths
  (`FetchAddr1/2`, `fetchCache1/2`), and the 64-bit region decode is behind a
  `region64` signal that `ADDR32_ONLY` can constant-fold.
* **A 16 KB / 32-byte data cache** with a four-beat writeback (and the
  registered-read-address fix that made beat 4 right), plus a fill consumer in
  the clk1x domain in both caches.
* **CP0 corrections**: EXL or ERL forces kernel mode (the N64 exported raw
  KSU — this core needed that first, docs/09), `kusegUnmapped` while ERL is set
  (MIPS III), and `chainedDelaySlot`, so an exception in the delay slot of a
  branch that is itself in a delay slot does not back EPC up twice.
* **Native R4600 identity**: `COP0_PRID_R4600` = `0x2020`.
* **Generics** `LITTLE_ENDIAN`, `ADDR32_ONLY`, `NO_TRAP_INSTR`,
  `INSTR_KSEG_ONLY`, `FRAMEBUFFER_UNCACHED`, `BOOT_QUIET_BITS` — all left at
  their defaults here (the KI wrapper turns most of them on for its two games;
  IRIX uses trap instructions, 64-bit region decode and mapped fetches).
* **Arcade diagnostics**: a 896-bit execution-trace bus, boot-ROM/FMV restart
  watchers, a CP0 exception census and eret capture. `r4300_wrap.vhd` sets
  `DEBUG_TRACE => false` and leaves every `debug_*` port open; what remains is
  dead logic that synthesis removes. Kept in the source so the next KI merge
  is a merge and not a rewrite.

One thing it brings that this core does **not** take: a clock-domain-crossing
mailbox on the memory path. See "The memory path" below.

## Local changes

Every deviation from upstream is marked with an `-- SGI:` comment giving the
reason. `tools/diff_upstream.sh` prints the full delta against the KI checkout,
so the list below can always be verified rather than trusted.

`Random` is deliberately *not* in the list. It already wraps at 31, which is
correct for a 32-entry TLB; `cp0/random_respects_wired` failed because it set
`Wired = 40`, an entry this part does not have. That was fixed in the test.

Changes are made in place rather than as a patch series because both Quartus
and the GHDL lowering have to consume the same files, and a build-time patch
step would put a generated copy in the synthesis path.

### Corrections — bugs relative to the R4000 manual

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd` | An exception taken with `Status.EXL` already set no longer overwrites `EPC` or `Cause.BD` — except a provisional fetch-side fault reported for a user-mode instruction, which must | R4000 manual §5; `excep/exl_preserves_epc`. The N64 never nests exceptions, IRIX does it on every TLB miss inside a handler. The exception to the rule is docs/25: the fetch stage runs ahead and can accept a younger instruction's I-TLB fault before the older instruction's D-TLB fault arrives |
| `cpu.vhd` | LWC1/LDC1/SWC1/SDC1 raise AdEL/AdES on a misaligned effective address | Upstream never set `decodeExcType` for them, so an unaligned FP access silently read the wrong bytes. `fpu/unaligned_access`, `fpu/unaligned_badvaddr` |
| `cpu.vhd` | A memory fault that is not an alignment fault reports AdEL/AdES by the DIRECTION of the access, not by the alignment rule attached to the opcode | `EXEExceptionMem` has three arms - the two 64-bit sign-extension checks and `region_unused` - that do not test `decodeExcType`, so they fire for `sb`, `lb` and `lbu` too. Those carry `decodeExcCode = 0` from the decoding default, and 0 is **Int**: a byte store through a pointer whose upper word is not the sign extension of bit 31 was handed to software as an INTERRUPT, with `BadVAddr` left unwritten. `verilator/tb_cpuonly.cpp` |
| `cpu.vhd` | opcode 0x33 raises Reserved Instruction instead of decoding as a NOP | 0x33 is LWC3, removed in MIPS III; MIPS IV reuses it for PREF. Software probes for MIPS IV by executing it and catching the trap. `mips4/pref` |
| `cpu.vhd` | A `cache` op this core does not implement stops at decode instead of being sent to the caches with an unknown code | `cpu_datacache.vhd` answers ANY `CacheCommandEna` by entering COMMANDPROCESS while its stall only covers the seven codes it knows. The IP22 kernel executes about a thousand secondary-cache and I-cache ops per boot; each is safely nothing here, but only if it stops at decode. `error_instr` still counts them (the sim's `instr(unimpl-cache-op)`, informational) |
| `cpu_instrcache.vhd` | A `cache` command that arrives while the cache is FILLING is latched and retired when the fill ends | It used to be dropped: IRIX's flush loop's own fetches start fills, a fraction of every flush was lost, and the dynamic linker executed a page it had just relocated with the bytes that were there before — `init` died with signal 11 |
| `cpu_FPU.vhd` | `C.cond.fmt` signals Invalid on a *signalling* NaN, not a quiet one | The mantissa MSB marks a QUIET NaN; upstream tested it the wrong way round. `fpu/compare_nan`, `fpu/cmp_signalling_qnan`, `fpu/cmp_snan_any_pred`, `fpu/cmp_trap_on_signal` |
| `cpu_FPU.vhd` | Arithmetic on a signalling NaN raises Invalid; a quiet NaN raises Unimplemented | Same polarity, the other side of it. R4000 manual Table 7-2. `fpu/snan_operands` |
| `cpu_FPU.vhd` | The default Invalid result is a quiet NaN (`0x7FFFFFFF` / `0x7FFF...`) | Upstream delivered `0x7FBFFFFF`, whose quiet bit is clear. `fpu/snan_operands` |
| `cpu_FPU.vhd` | An exactly-zero sum keeps the operands' sign when they agree | `(-0) + (-0)` was `+0`. IEEE 754 §6.3. `fpu/signed_zero`, `fpu/double_signed_zero` |
| `cpu_FPU.vhd` | Divide-by-zero is not raised for `inf / 0` | It is only for a finite dividend. `fpu/vec_arith_single`, `fpu/vec_arith_double` - IRIS fails these too |
| `cpu_FPU.vhd` | comment only: the `cvt.s.l` / `cvt.d.l` 56-bit truncation | Known limitation, diagnosed but not fixed. `fpu/vec_cvt_from_l` |

### Presentation — an R4600, all the way down

An Indy shipped with an R4000, R4400, R4600 or R5000, never an R4300, and
software takes the TLB entry count and the cache line size from `PRId` because
no register reports the first and IRIX never reads `Config` for the second.
The KI base already reports an R4600; `PRESENT_AS_R4600` in `cpu_cop0.vhd`
selects everything that has to go with that, and `cpu.vhd` and `cpu_FPU.vhd`
carry copies. `docs/10-r4300-integration.md` has the original reasoning (for the
R4400 presentation this core used until docs/43) and the safety argument for
the cache-geometry report; docs/43-44 the move to R4600.

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd` | `PRId` reports KI's `COP0_PRID_R4600` (`0x2020`) under `PRESENT_AS_R4600`, `0x0B22` (the R4300) otherwise | IRIX 5.3 keys its R4600 code paths off imp 0x20 — including a **32-byte data-cache line hard-coded** in `__dcache_inval` / `__dcache_wb_inval` (it never reads `Config.DB`), which is exactly the geometry KI's data cache has. Under an R4400 PRId it hard-codes 16 bytes, so the R4400 presentation and this cache cannot coexist (docs/39) |
| `cpu_FPU.vhd` | `FIR` reports `0x2020` | imp 0x20, revision 2.0 — matches PRId, and is what `hinv` names the FPU from |
| `cpu_cop0.vhd`, `cpu_TLB_instr.vhd`, `cpu_TLB_data.vhd` | **48 TLB entries** instead of KI's 32 | An R4600 has 48. Not optional once `PRId` says so: IRIX writes indices up to 47, and a 32-entry part aliases those onto 0..15 and corrupts its own page tables. The search is sequential, so the cost is one address bit and 16 more cycles worst case |
| `cpu_cop0.vhd` | `Config` reports 16 KB / 32-byte lines for both caches | TRUE for both since docs/44 (the N64 base's report was under-reported on purpose; see docs/10) |
| `cpu.vhd` | COP2 is always unusable, `Cause.CE = 2` | An R4600 has no coprocessor 2; the R4300's data latch made `mfc2` succeed |
| `cpu.vhd` | MIPS IV COP1 function codes 0x11/0x12/0x13/0x15/0x16 raise Reserved Instruction | They reached the FPU and came back as Unimplemented Operation, which makes an R4600 look like an R5000 to software probing for MIPS IV |

The cpu-tests suite (`iris/cpu-tests`) selects its expectations by `PRId` and
had no case for imp 0x20; the build copy used here (`~/cputests`) treats an
R4600 as R4000-class and expects `0x2020` / 32-byte lines in `identity/` and
`cache/geometry`. Everything else it tests is the same on both parts.

### Machine size — N64 assumptions that an IP24 breaks

The N64's whole physical address space is 512 MB, so upstream truncates
physical addresses to 29 bits in several places and nothing there can notice.
An Indy puts **high local memory at physical `0x20000000`–`0x2FFFFFFF`**, and
the PROM's memory sizing runs entirely in it: `map_high_memory`
(`0xBFC01A00`) installs four 16 MB TLB pages there and `szmem` probes through
them. With the truncation in place every one of those accesses came out at
`0x00000000`, POST reported "No usable memory found. Make sure you have a full
bank (4 SIMMs)", and no amount of work on the memory controller could have
fixed it.

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd` | `TLB_fetchAddrOutMasked` passes the TLB's translation through instead of `"000" & …(28 downto 0)` | A real R4000-family part builds a 36-bit physical address out of the PFN and truncates nothing. KI does the same only when its `ALECK64` input is set; here it is unconditional and the port is tied low |
| `cpu.vhd` | the kseg0/kseg1 strip moved off the write FIFO and onto the *unmapped* fetch path, and onto the reset PC; the retained (latched) stage-1 request carries all 32 bits | `mem1_address` now carries a physical address in every case. Stripping the top three bits in the FIFO was correct only because every fetch there was unmapped; it silently undid the TLB fix above |

Data accesses never needed this: `executeMemAddress` already takes the TLB
output unchanged and only strips the address on the unmapped path.

### Caches — what turning them on needed

`rtl/cpu/r4300_bus.sv` answers a fill out of ordinary SGI bus reads; these are
the changes inside the vendored files that had to go with it.

| File | Change | Why |
|---|---|---|
| `cpu.vhd` | the instruction cache tags a line with a new `mem1_addrCompare` instead of with `mem1_address` | Fallout from the strip above, and invisible until the cache was switched on. Upstream's tag is "the TLB output when mapped, the virtual address when not", which is exactly what `read_addrCompare` compares against — and upstream got the unmapped half for free because `mem1_address` *was* the virtual address there. Once the strip moved, the tag went physical while the compare stayed virtual and **every fetch missed** |
| `cpu_cop0.vhd` | `Config.K0` is exported as `CONFIG_K0` | It was stored and read back but never acted on. Reassembled from the two fields upstream splits it across — `cacheAlgoKSEG0` is K0(1:0) and the low bit of `cu` is K0(2), because `cu` is really `Config(3:2)` |
| `cpu.vhd` | KSEG0 is cacheable only when `Config.K0 /= 2`, for both fetch paths (`fetchCache1/2`) and data | An N64 never writes `Config`, so upstream hardcodes KSEG0 as cached. The IP24 PROM comes out of reset with K0 = 2 (uncached) and has a pair of routines at `0xBFC04798` and `0xBFC047D8` whose only job is to switch it to 3 and back. Only the encoding 2 means uncached, so every other value — including the reserved 0 this core resets to, which is what the cpu-tests suite runs with — stays cacheable |

### Interrupts — five lines instead of two

An N64 has two interrupt sources and a reset button; an IP24 has one interrupt
controller with five lines into the CPU. `irqRequest` is replaced by a single
`irqLines`, `std_logic_vector(4 downto 0)`, carrying `Cause.IP[6:2]` — LOCAL0,
LOCAL1, 8254 counter 0, 8254 counter 1, bus error, in that order (IRIS's
`Ioc::update_interrupts`). `rtl/sgi/sgi_ioc.sv` drives it.

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd`, `cpu.vhd` | `irqRequest(1 downto 0)` → `irqLines(4 downto 0)` | Five sources, not two |
| `cpu_cop0.vhd` | `Cause.IP(6 downto 2)` is assigned from it every cycle | All five are ordinary levels. Upstream *sets* IP4 from `preNMI` and never clears it, which is right for a reset button and wrong for a timer. `preNMI` is tied low here and its port is left in place so the entity still matches upstream's |

`Cause.IP7` (the Count/Compare timer) and `IP1:0` (the two software interrupts)
are untouched and remain CP0's own. `tests/run-int.sh` exercises the whole path
from an 8254 counter to an Interrupt exception, both directly on IP4 and
through INT2's mappable summary on IP2, and checks that masking at either end
stops it.

### The data cache — KI's 16 KB of 32-byte lines, physically indexed

KI's `cpu_datacache.vhd` is 512 lines of 32 bytes, direct-mapped, and — as
KI ships it — **virtually indexed** on address bits 13:5 with a physical tag
compared on bits 31:14. That exact cache was tried here on 2026-09-02 (docs/39)
and **killed IRIX init** on the board and in the simulator, deterministically:
a RAM dump at the panic showed one page of `/sbin/init`'s text holding zeros —
dirty zero lines from the kernel's page clearing, written back over the DMA'd
page after an invalidate that had looked in the wrong lines. Bits 13:12 of a
16 KB direct-mapped index are virtual page-colour bits; IRIX colours pages for
it but not on that zero-then-map path, and a real R4600 catches the alias in
ways this core does not have. A 16 KB / 16-byte variant of the N64 cache died
the same way. KI's games never hit the alias; IRIX does.

So the cache is **physically indexed** (docs/40-42, first done on the N64 base
with 16-byte lines and carried onto KI's 32-byte geometry in docs/44):

| File | Change | Why |
|---|---|---|
| `cpu.vhd` | `EXECacheAddr(13 downto 12)` comes from the data mini-TLB's translation (`TLB_dataAddrOutFound`, or `TLB_dataAddrOutLookup` on the unstall clock), and `EXECacheAddr(11 downto 3)` from `TLB_dataAddrOutLookup` on `TLB_dataUnStall` | The index never carries a virtual colour. The page offset is identical virtual and physical, so the 11:3 override is always correct; it exists because `calcMemAddr` has already advanced past the access by the unstall clock (docs/41) |
| `cpu_datacache.vhd` | a `tlb_unstall` port folded into `ce_fetch` | On a mini-TLB MISS the combinational translation is stale, so the tag is re-read with the resolved address on the unstall clock while the pipeline is still stalled |
| `r4300_wrap.vhd` | `SETTLE_CLOCKS` stays 2048 | Each cache's reset clear walks its 512 entries with no handshake; the settle has to outlast it |

Everything else in the file is KI's. Gates: cpu-tests `tlb/translation_works`
and `tlb/readonly_page_mod`, `make -C verilator cpuonly`, and the IRIX boot in
the simulator — init must survive past ~190M cycles (docs/42; the post-init
livelock at ~192.6M is a pre-existing sim-only issue, not a cache regression).

`DATACACHETLBON` is 1 in `r4300_wrap.vhd` (upstream default 0), which is a
port value rather than a source change but belongs with them: with KSEG0 cached
and mapped pages not, the two views of one physical page disagree, and
`tlb/translation_works` writes through KSEG0 and reads back through a mapping.

### The instruction cache — one R4600 way, not KI's 16 KB

Build 23 put KI's I-cache on the board unchanged: 16 KB direct-mapped,
**virtually** indexed on bits 13:5, tag compared on bits 31:14 only (KI
narrowed the N64 base's 31:12 compare for timing). IRIX booted into a storm of
bus errors, segmentation faults and illegal instructions, while the same boot
was clean in the simulator. The kernel's own data explains it: IRIX sets
`cachecolormask` from `PRId` — 3 as an R4400 (virtual and physical bits 13:12
kept equal, which is what made a virtually indexed 16 KB cache survive on
builds 21-22), **1 as an R4600** (only bit 12, because a real R4600's ways are
8 KB). Read at `0x881B9680` in the RAM dumps of both simulator boots (docs/45).
So under the R4600 identity half of all user text pages have virtual bit 13 ≠
physical bit 13: a fetch could hit another 4 KB page's line, and the kernel's
invalidates by physical address looked in the wrong set. The data cache was
fine because it is physically indexed.

| File | Change | Why |
|---|---|---|
| `cpu_instrcache.vhd` | 256 lines of 32 bytes (8 KB), index bits 12:5, tag bits 31:12 (20 bits + valid, the N64 base's width) | The one virtual index bit is the one IRIX colours for an R4600 — the same exposure a real R4600 way has, which IRIX is built to handle — and the full tag makes a wrong hit impossible for any mapping |
| `cpu_cop0.vhd` | `Config` still reports a 16 KB I-cache | What an R4600 reports; an index flush sized from it walks ours twice, the safe direction. IRIX sizes its flushes from `PRId` regardless |
| `cpu.vhd`, `cpu_instrcache.vhd` | **The index is PHYSICAL** (docs/47): `read_index1/2` bit 12 comes from `FetchAddrTLBMuxed1/2(12)` (the instruction mini-TLB's translation when mapped, the equal virtual bit when not — `FetchIndexPhys1/2`), bits 11:2 stay on KI's flattened `FetchIndex` mux; the fill index (`fill_addrTag`) is `mem1_addrCompare`, the same physical address the tag is taken from, so the `fill_addrTag` register is gone; and cache op 0x10 `Hit_Invalidate_I` is TRANSLATED like the D-cache's hit ops (it was in the untranslated list only because the cache was virtually indexed) | Build 24 (8 KB, virtual bit 12 — "the one bit IRIX colours") still lost init to SIGSEGV about one boot in three on the board: IRIX does not colour every mapping, a page mapped with virtual bit 12 ≠ physical bit 12 left its lines in set(V), and the kernel's `Hit_Invalidate_I` by the page's K0 address looked in set(P). A real R4600's hit ops search both ways of a set; this cache has one. Physically indexed on both the fetch and the fill side, a line lives in exactly one set for every mapping. Timing: the mini-TLB's physical bits 31:12 are a plain register (`mini_physical`), so the physical bit is one 2:1 mux on `TLB_instrMapped`, not a TLB compare; on a mini-TLB miss the stale bit is a harmless false miss (that fetch is re-issued as a fill after the walk) and the full tag makes a false hit impossible |

The proper follow-up is 16 KB as two 8 KB ways with the way selected by
physical bit 13 (no replacement policy needed, no alias possible); it costs a
second data-RAM read and a mux on the fetch data path, which is exactly the
path KI's `FetchIndex` work shortened.

### The memory path — no clock-domain crossing

KI runs `cpu.vhd`'s clk93 at 75 MHz against a 50 MHz clk1x bridge and moved
every transaction through a bundled-data request/acknowledge mailbox in each
direction: two synchroniser flops per direction, a read-response mailbox that
registers the raw word and then the load-aligned copy before pulsing
completion, an 8-bit sequence tag on every FIFO entry, and a 16-entry
read-ownership scoreboard that checks responses against it.
`rtl/cpu/r4300_wrap.vhd` ties clk1x, clk2x and clk93 to the ONE system clock,
where all of that is ~7 dead clocks on every uncached access and every cache
miss — and the L1 miss cost IS this machine's sluggishness (docs/39).

| File | Change | Why |
|---|---|---|
| `cpu.vhd` | The mailboxes, sequence tag and scoreboard are removed. The clk1x side reads the fall-through FIFO directly and pulses `writefifo_rd_1x`; the clk93 side edge-detects that into the pop; a completed read is delivered one clock after `mem_done` straight off `mem_dataRead` | The N64 base's consumer, which build 22 fitted and ran. `rtl/cpu/r4300_bus.sv` already presents read data shifted by the address's byte offset, so KI's `read4_uncachedRot` (which did the same shift in the CPU) is gone too, or it would have shifted twice |
| `cpu.vhd` | KI's scheduler above the FIFO is kept as is | The held payload (`writefifo_issue_pending`), the four-entry writeback staging queue, the retained refill and stage-1 requests and the stage-4 ready/valid handshake are what make a 32-byte line's four-beat writeback safe against FIFO pressure; the N64 base's blocking rule only guaranteed room for two beats |

The `mem_*` port itself is unchanged from the N64's; a fill is one burst on
the SGI bus (`rtl/cpu/r4300_bus.sv`, `ram_arb.sv`, `ddr3_mux.sv`) and its data
comes back on `ddr3_DOUT` / `ddr3_DOUT_READY`, armed by `rdram_granted2x`, in
the order that file documents. Both caches now consume those beats in KI's
clk1x fill logic, which latches the line index at the grant rather than
through a two-register pipeline — the hazard the N64 base's I-cache had (docs/
21) does not exist in it.

## Results

`make -C verilator cpuonly`: 728 runs, 0 against expectation (78 of 182
data-cache runs streamed as bursts — the same as build 22). The cpu-tests suite:
**2161 checks passed / 3 failed**, and the only failing test is
`fpu/vec_cvt_from_l`. The IRIX 5.3 simulator boot: init survives, the exit
device table is identical to build 22's, reached ~11M cycles sooner.

**Build 23** (SEED=2, 2026-09-07, `output_files/sgiindy-b23-seed2.rbf`):
34,743 ALMs (83 %), 42,770 registers, 2.99 Mbit of block memory — all within
1 % of build 22 — and the CORE clock's setup slack went from +2.459 ns to
**+2.904 ns**, which is what the swap was for. On the board its hardware
cpu-tests were 2165/3 with PRId/FIR 0x2020 and every bench number identical
to build 22's to within a tick, except `ld_miss`: 114,418 vs 106,790 ticks
for 8192 missing loads (+7 %, still 13 ticks per load — a 32-byte fill is two
more DDR3 beats). Its IRIX boot failed in rc2 with the I-cache aliasing
described above; build 24 carries the 8 KB I-cache.
