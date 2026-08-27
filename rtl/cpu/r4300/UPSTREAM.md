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
| `cpu_instrcache.vhd`, `cpu_datacache.vhd` | primary caches (currently disabled) |
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
| `cpu_cop0.vhd` | `Config` reports 16 KB/16-byte for both caches | R4400 geometry. Both errors are in the safe direction for index-based flushes — see `docs/10` |
| `cpu.vhd` | COP2 is always unusable, `Cause.CE = 2` | An R4400 has no coprocessor 2; the R4300's data latch made `mfc2` succeed |
| `cpu.vhd` | MIPS IV COP1 function codes 0x11/0x12/0x13/0x15/0x16 raise Reserved Instruction | They reached the FPU and came back as Unimplemented Operation, which makes an R4400 look like an R5000 to software probing for MIPS IV |

