# CPU options

## The three candidates

| | **aoR3000** | **N64 R4300i** | **A real R4400** |
|---|---|---|---|
| Source | `~/mistersgi/aor3000/` (BSD) | `~/mistersgi/R4300_VHDL/` (MiSTer N64 core, VHDL) | does not exist as open RTL |
| ISA | MIPS I | MIPS III (64-bit) | MIPS III |
| Matches | **Indigo IP12 (R3000A)** | Indy IP24 (R4000PC-class) approximately | Indy IP24 exactly |
| FPU | **none** | yes (`cpu_FPU.vhd`) | yes |
| MMU | R3000A-compatible, 64 TLB entries + micro-TLBs | R4300 TLB (`cpu_TLB_*.vhd`) | R4400 TLB |
| Caches | 2 KB I$ + 2 KB D$, direct-mapped | `cpu_instrcache.vhd` / `cpu_datacache.vhd` (**tied off** in the sandbox) | 16 KB + 16 KB, plus secondary |
| Endianness | **little-endian, hard-wired, not software-selectable** | big-endian (N64 convention) | big-endian |
| Size / speed | ~7 660 LE, ~52 MHz on Cyclone IV | much larger; N64 core targets DE10-Nano | — |
| Bus | Avalon-MM master, burst + pipelined | `mem_*` port + separate RDRAM/DDR3 cache-fill path | SysAD |

## Endianness — the single biggest gotcha

SGI machines are **big-endian**. aoR3000 is fixed **little-endian**.

The sandbox papers over this in `DE1_TOP.v:728` (`data_flipped`): the ROM/RAM
byte-serial gearbox reassembles each word with the byte order reversed, so a
big-endian ROM image delivers a little-endian word to the CPU. There is a
commented-out `data_normal` alternative right below it, and a
per-address-range switch at line 741 that was used at some point to feed
*normal* order for a specific window (`0x1FC03D50`–`0x1FC03DEF`) — a strong hint
that this trick isn't uniformly correct.

This matters enormously for the port:

- With **aoR3000**, byte-flipping must be applied consistently to every path
  the CPU reads or writes — ROM, RAM, *and* every MMIO register. Half-byte-
  order bugs of exactly this kind are all over the sandbox's comment history
  (the SCC `_CS`/`MUX_ADDR` saga, the `r4300_bus_adapter` byte-lane rotation).
- With the **R4300i**, the core is natively big-endian, so `data_flipped`
  should probably become `data_normal`. **Verify this before anything else** if
  continuing the R4300i route — a wrong global byte order will look like the
  CPU executing garbage right after reset.

Also note that R4000-family `Config` bit 15 is the endianness bit, and
`realstart` reads `Config` back and branches on it (see
[03-boot-prom.md](03-boot-prom.md) step 2) — the PROM notices.

## Current state of the R4300i swap-in

The sandbox recently replaced aoR3000 with the N64 core's `cpu.vhd`. It is
wired at `DE1_TOP.v:453` with everything nonessential tied off:

- `INSTRCACHEON` = `DATACACHEON` = 0 — **caches disabled**, so all traffic is
  single word/doubleword through `mem_*`, and the DDR3/RDRAM cache-fill path is
  never exercised.
- `clk1x` = `clk93` = `clk2x` = one clock, to avoid CDC risk during bring-up.
- `irqRequest` = `irqCartRequest` = 0 — **no interrupts at all**.
- `cpuPaused` tied low; run/stop is via `ce_1x`/`ce_93` gated on a DIP switch.
- `SS_reset` is **not** vestigial: it seeds the real reset PC
  (`0xFFFFFFFF_BFC00000`) into `cpu.vhd`'s internal savestate shadow register.
  Tying it low leaves the reset PC at 0.
- `r4300_bus_adapter.v` bridges `mem_*` to the Avalon-style bus. Its read
  byte-lane rotation is a **deliberate partial fix**: it rotates the target byte
  down to `[7:0]` only when `req_addr[1:0] != 0`. The header explains why the
  general fix isn't possible from the adapter (`cpu.vhd` exposes no usable
  access-width signal on reads) and that rotating unconditionally hung the CPU.

The core is fed to Verilator as `cpu_netlist_v2.v`, a 5.3 MB GHDL/Yosys flatten
of the VHDL. **Do not carry that netlist into the MiSTer core** — Quartus
compiles VHDL natively; add `R4300_VHDL/*.vhd` to the QSF directly. The netlist
exists only because Verilator can't read VHDL.

## Recommendation

**Build the Indy (IP24) with the N64 R4300i.**

This reverses an earlier recommendation to start with the Indigo/IP12 and
aoR3000. The reason is `~/repos/iris/cpu-tests/` — a 240-test bare-metal
MIPS III/IV suite that runs on the CPU with no OS and reports over the SCC.
See [09-cpu-validation.md](09-cpu-validation.md).

What changed:

- **The CPU risk is now measurable.** "Is an R4300i close enough to an R4x00?"
  was the open question that made the Indy path speculative. The suite answers
  it with ~800 checks, and its expectations come from the R4000 manual rather
  than from a golden recording.
- **The suite needs almost no chipset** — RAM at `0x08000000` and SCC TX. It
  can run on the core under Verilator *before* the PROM can, making it a better
  first bring-up target than executing PROM instructions and hoping.
- **Endianness is settled.** `cpu_cop0.vhd:582` sets
  `COP0_16_CONFIG_bigEndian <= '1'` at reset — the R4300i is natively
  big-endian, which is what SGI needs and what the IP24 PROM reads back from
  `Config` bit 15 in `realstart`. The sandbox's `data_flipped` byte reversal
  exists purely to feed the little-endian aoR3000 and **must not be carried
  forward**.
- **IRIS is a complete behavioural reference** for the rest of the machine:
  working Rust implementations of MC, HPC3, IOC, HAL2, the Dallas RTC, the
  93C56 EEPROM, REX3, VC2 and XMAP9, in an emulator that boots IRIX to a
  desktop.

The aoR3000/Indigo path stays viable as a fallback if the R4300i plus Newport
turns out not to fit the DE10-Nano, and aoR3000 remains the better core in
isolation (small, BSD, proven). But it has no FPU at all, the IP24 PROM enables
CU1, and the test suite's 88 FPU tests would be unusable against it. Starting
there now means giving up the validation asset that makes this project
tractable.

An R4400 proper is not available as open RTL. The realistic Indy target is
"R4300i presenting as an R4x00", and the divergences are enumerated and costed
in [09-cpu-validation.md](09-cpu-validation.md).

## Open questions — status

The CPU is integrated and measured; see
[10-r4300-integration.md](10-r4300-integration.md) for the whole story and
`tests/run-cputest.sh` for the numbers.

1. ~~**Byte order**~~ — **resolved.** The R4300i resets with
   `Config.bigEndian = 1` (read back as `Config = 0x7006E460`, bit 15 set);
   `data_flipped` was never carried forward.
2. **`PRId` / `Config`** — **partly resolved.** `PRId` is `0x00000B22` as
   expected. But the claim that the R4300i does not drive `Config`'s
   cache-size fields is **wrong**: it reports IC = 2, DC = 1, IB = 1, DB = 0,
   i.e. a 16 KB/32 B I-cache and an 8 KB/16 B D-cache — its real geometry.
   Nothing needs hardwiring for `realstart`'s refresh timing.
   `PRId` still wants spoofing to `0x00000440` if the PROM or IRIX turns out
   to key off it; that decision is still open and belongs with M2.
3. **Caches** — still off, and now for a concrete reason: the fill path talks
   to the N64's RDRAM/DDR3 controller rather than to `mem_*`. The `cache`
   instruction itself decodes and does not fault, except for the two operations
   upstream never implemented (`error_instr` flags them, harmlessly).
4. **Interrupts** — still absent. `scc_int_n` is now brought out of the core,
   so INT2 has something to connect to when it is written.
5. **FPU** — **measured.** 88 FPU tests, and after eight fixes to the vendored
   FPU the core passes every one of them except `fpu/vec_cvt_from_l`. Fifteen
   FPU tests pass here that IRIS fails. The FPU is not the risk it looked like.
6. **TLB size** — 32 entries confirmed, all ten `tlb/` tests pass against that
   number. Whether IRIX minds is still open; nothing has forced the question.
