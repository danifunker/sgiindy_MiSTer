# Vendored R4300i CPU

These files come from the **MiSTer N64 project**, `MiSTer-devel/N64_MiSTer`,
`rtl/`, at commit `adbf9b5d41bcc8b6dc3ad00821e2cd062847ab4f` (2026-08-15).
Licence: GPL-3.0, which is why this repository is GPL-3.0 — see `LICENSE`.

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
| `cpu_instrcache.vhd`, `cpu_datacache.vhd` | primary caches |
| `divider.vhd` | integer divider |
| `functions.vhd`, `export.vhd` | `pFunctions` / `pexport` packages |
| `SyncFifoFallThroughMLAB.vhd` | the CPU's write FIFO |

`rtl/cpu/prim/` holds behavioural replacements for the Altera megafunctions
these files instantiate (`altdpram`, `altsyncram`, `altera_mult_add`), so the
CPU builds without `altera_mf`.

## Local changes

Every deviation from upstream is marked with an `-- SGI:` comment giving the
reason. `tools/diff_upstream.sh` prints the full delta against a checkout of
the upstream repo, so the list below can always be verified rather than
trusted.

`Random` is deliberately *not* in the list. It already wraps at 31, which is
correct for a 32-entry TLB; `cp0/random_respects_wired` failed because it set
`Wired = 40`, an entry this part does not have. That was fixed in the test.

Changes are made in place rather than as a patch series because both Quartus
and the GHDL lowering have to consume the same files, and a build-time patch
step would put a generated copy in the synthesis path.

### Corrections — bugs relative to the R4000 manual

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd` | An exception taken with `Status.EXL` already set no longer overwrites `EPC` or `Cause.BD` | R4000 manual §5; `excep/exl_preserves_epc`. The N64 never nests exceptions, IRIX does it on every TLB miss inside a handler |
| `cpu.vhd` | LWC1/LDC1/SWC1/SDC1 raise AdEL/AdES on a misaligned effective address | Upstream never set `decodeExcType` for them, so an unaligned FP access silently read the wrong bytes. `fpu/unaligned_access`, `fpu/unaligned_badvaddr` |
| `cpu.vhd` | A memory fault that is not an alignment fault reports AdEL/AdES by the DIRECTION of the access, not by the alignment rule attached to the opcode | `EXEExceptionMem` has three arms - the two 64-bit sign-extension checks and `region_unused` - that do not test `decodeExcType`, so they fire for `sb`, `lb` and `lbu` too. Those carry `decodeExcCode = 0` from the decoding default, and 0 is **Int**: a byte store through a pointer whose upper word is not the sign extension of bit 31 was handed to software as an INTERRUPT, with `BadVAddr` left unwritten. The guest goes off to poll an interrupt controller with nothing to say while the real fault is never reported. `verilator/tb_cpuonly.cpp` |
| `cpu.vhd` | opcode 0x33 raises Reserved Instruction instead of decoding as a NOP | 0x33 is LWC3, removed in MIPS III; MIPS IV reuses it for PREF. Software probes for MIPS IV by executing it and catching the trap. `mips4/pref` |
| `cpu_FPU.vhd` | `C.cond.fmt` signals Invalid on a *signalling* NaN, not a quiet one | The mantissa MSB marks a QUIET NaN; upstream tested it the wrong way round, so compares signalled on qNaN and stayed silent on sNaN. `fpu/compare_nan`, `fpu/cmp_signalling_qnan`, `fpu/cmp_snan_any_pred`, `fpu/cmp_trap_on_signal` |
| `cpu_FPU.vhd` | Arithmetic on a signalling NaN raises Invalid; a quiet NaN raises Unimplemented | Same polarity, the other side of it. R4000 manual Table 7-2. `fpu/snan_operands` |
| `cpu_FPU.vhd` | The default Invalid result is a quiet NaN (`0x7FFFFFFF` / `0x7FFF...`) | Upstream delivered `0x7FBFFFFF`, whose quiet bit is clear. `fpu/snan_operands` |
| `cpu_FPU.vhd` | An exactly-zero sum keeps the operands' sign when they agree | `(-0) + (-0)` was `+0`. IEEE 754 §6.3. `fpu/signed_zero`, `fpu/double_signed_zero` |
| `cpu_FPU.vhd` | Divide-by-zero is not raised for `inf / 0` | It is only for a finite dividend. `fpu/vec_arith_single`, `fpu/vec_arith_double` - IRIS fails these too |
| `cpu_FPU.vhd` | comment only: the `cvt.s.l` / `cvt.d.l` 56-bit truncation | Known limitation, diagnosed but not fixed. `fpu/vec_cvt_from_l` |

### Presentation — deliberately not an R4300 any more

An Indy shipped with an R4000, R4400, R4600 or R5000, never an R4300, and
software takes the TLB entry count from `PRId` because no register reports it.
`PRESENT_AS_R4400` in `cpu_cop0.vhd` selects the whole set; `cpu.vhd` and one
nibble in `cpu_FPU.vhd` carry copies. `docs/10-r4300-integration.md` has the
reasoning and the safety argument for the cache-geometry report.

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd` | `PRId` reports `0x0440` | An R4400PC is what an Indy has; `hinv` and IRIX both key off it |
| `cpu_FPU.vhd` | `FIR` reports revision 5, not 0x0A | The R4000-family FPU identity |
| `cpu_cop0.vhd`, `cpu_TLB_instr.vhd`, `cpu_TLB_data.vhd` | **48 TLB entries** instead of 32 | Not optional once `PRId` says R4400: IRIX writes indices up to 47, and a 32-entry part aliases those onto 0..15 and corrupts its own page tables. The search is sequential, so the cost is one address bit and 16 more cycles worst case |
| `cpu_cop0.vhd` | `Config` reports 16 KB/16-byte for both caches | R4400 geometry. TRUE for the data cache since docs/39 (16 KB of 16-byte lines); the instruction cache's 32-byte lines are under-reported, which is the safe direction for index-based flushes — see `docs/10`. It does not matter to IRIX anyway: IRIX 5.3 never reads `Config.IB/DB`, it hard-codes the line size from `PRId` (16 for an R4400, 32 for an R4600), which is why the data line MUST be 16 bytes under this presentation - docs/39 |
| `cpu.vhd` | COP2 is always unusable, `Cause.CE = 2` | An R4400 has no coprocessor 2; the R4300's data latch made `mfc2` succeed |
| `cpu.vhd` | MIPS IV COP1 function codes 0x11/0x12/0x13/0x15/0x16 raise Reserved Instruction | They reached the FPU and came back as Unimplemented Operation, which makes an R4400 look like an R5000 to software probing for MIPS IV |


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
| `cpu_cop0.vhd` | `TLB_fetchAddrOutMasked` passes the TLB's translation through instead of `"000" & …(28 downto 0)` | A real R4000/R4400 builds a 36-bit physical address out of the PFN and truncates nothing. Upstream's own comment says this line is "only for 32bit mode" |
| `cpu.vhd` | the kseg0/kseg1 strip moved off the write FIFO and onto the *unmapped* fetch path, and onto the reset PC | `mem1_address` now carries a physical address in every case. Stripping the top three bits in the FIFO was correct only because every fetch there was unmapped; it silently undid the TLB fix above |

Data accesses never needed this: `executeMemAddress` already takes the TLB
output unchanged and only strips the address on the unmapped path.

### Caches — what turning them on needed

`rtl/cpu/r4300_bus.sv` answers a fill out of ordinary SGI bus reads; these are
the changes inside the vendored files that had to go with it.

| File | Change | Why |
|---|---|---|
| `cpu.vhd` | the instruction cache tags a line with a new `mem1_addrCompare` instead of with `mem1_address` | Fallout from the strip above, and invisible until the cache was switched on. Upstream's tag is "the TLB output when mapped, the virtual address when not", which is exactly what `read_addrCompare` compares against — and upstream got the unmapped half for free because `mem1_address` *was* the virtual address there. Once the strip moved, the tag went physical while the compare stayed virtual and **every fetch missed**. The cache still returned correct instructions; it just read four doublewords to answer each one, for 3.5x the bus traffic of no cache at all |
| `cpu_cop0.vhd` | `Config.K0` is exported as `CONFIG_K0` | It was stored and read back but never acted on. Reassembled from the two fields upstream splits it across — `cacheAlgoKSEG0` is K0(1:0) and the low bit of `cu` is K0(2), because `cu` is really `Config(3:2)` |
| `cpu.vhd` | KSEG0 is cacheable only when `Config.K0 /= 2`, for both fetch and data | An N64 never writes `Config`, so upstream hardcodes KSEG0 as cached. The IP24 PROM comes out of reset with K0 = 2 (uncached) and has a pair of routines at `0xBFC04798` and `0xBFC047D8` whose only job is to switch it to 3 and back. Only the encoding 2 means uncached, so every other value — including the reserved 0 this core resets to, which is what the cpu-tests suite runs with — stays cacheable |

### Interrupts — five lines instead of two

An N64 has two interrupt sources and a reset button; an IP24 has one interrupt
controller with five lines into the CPU. `irqRequest` and `irqCartRequest` are
replaced by a single `irqLines`, `std_logic_vector(4 downto 0)`, carrying
`Cause.IP[6:2]` — LOCAL0, LOCAL1, 8254 counter 0, 8254 counter 1, bus error, in
that order (IRIS's `Ioc::update_interrupts`). `rtl/sgi/sgi_ioc.sv` drives it.

| File | Change | Why |
|---|---|---|
| `cpu_cop0.vhd`, `cpu.vhd` | `irqRequest` + `irqCartRequest` → `irqLines(4 downto 0)` | Five sources, not two |
| `cpu_cop0.vhd` | `Cause.IP(6 downto 2)` is assigned from it every cycle | All five are ordinary levels. Upstream *sets* IP4 from `preNMI` and never clears it, which is right for a reset button and wrong for a timer. `preNMI` is tied low here and its port is left in place so the entity still matches upstream's |

`Cause.IP7` (the Count/Compare timer) and `IP1:0` (the two software interrupts)
are untouched and remain CP0's own. `tests/run-int.sh` exercises the whole path
from an 8254 counter to an Interrupt exception, both directly on IP4 and
through INT2's mappable summary on IP2, and checks that masking at either end
stops it.

### The data cache — still the R4300's 8 KB, and why (docs/39)

The data cache is upstream's: 512 lines of 16 bytes, 8 KB, direct-mapped,
virtually indexed on address bits 12:4 and physically tagged. Two attempts
to grow it were made and measured on 2026-09-02, and both are recorded here
so they are not made a third time:

| Attempt | What happened |
|---|---|
| Killer Instinct's 16 KB of 32-byte lines (their R4600's, transcribed hunk for hunk) | Passed the whole cpu-tests suite and every ratchet, fitted clean, and killed `init` on the board and in the simulator (188,024,331 cycles, deterministic) |
| 16 KB of 16-byte lines (the same file with one more index bit) | Passed the same gates and killed `init` in the simulator the same way (200,100,483 cycles) |

In both, a RAM dump at the panic showed one page of `/sbin/init`'s text
(all its other loaded pages byte-perfect) holding zeros where the file's
code should be: dirty zero lines from the kernel's page clearing, written
back over the DMA'd page after an invalidate that had looked in the wrong
lines. That is a virtual-index alias on address bit 13 - the bit a 16 KB
direct-mapped cache indexes from the virtual address and an 8 KB one does
not. IRIX 5.3 colours pages for a 16 KB cache (`cachecolormask` = 3,
`color_validation`), but evidently not on the path that zeroes and then
maps this page; a real R4400 gets the same alias caught by its secondary
cache's VCE machinery, which this core does not have. A bigger data cache
therefore has to be physically indexed (the data mini-TLB translates in the
same cycle the cache reads its tags, so it is feasible) or two-way with
8 KB per way; neither is a geometry tweak. The line stays 16 bytes as well:
IRIX hard-codes the R4400's line size in `__dcache_inval` /
`__dcache_wb_inval` rather than reading `Config.DB`.

What DID change for the data cache is outside the vendored tree: a fill is
one two-word burst on the SGI bus (`rtl/cpu/r4300_bus.sv`, `ram_arb.sv`,
`ddr3_mux.sv`) instead of two round trips.

`DATACACHETLBON` is now 1 in `r4300_wrap.vhd` (upstream default 0), which is a
port value rather than a source change but belongs with them: with KSEG0 cached
and mapped pages not, the two views of one physical page disagree, and
`tlb/translation_works` writes through KSEG0 and reads back through a mapping.

The suite goes from 2155 checks passed / 9 failed to **2161 / 3**, and the only
failing test left is `fpu/vec_cvt_from_l`.
