# The CPU

The core's CPU is a MIPS R4600: the CPU of the MiSTer Killer Instinct arcade
core, vendored as VHDL. This document is how it is built into the machine -
the two toolchains that compile it, the wrapper and the bus adapter around it,
what it tells software it is, its TLB and its caches - and how it is checked.
Read it before touching `rtl/cpu/`.

`rtl/cpu/r4300/UPSTREAM.md` is the authoritative record of the vendored
sources: the upstream commit, and every local change with its reason and the
test that covers it. This document summarises those changes rather than
repeating them.

## At a glance

| | |
|---|---|
| Part | MIPS R4600: MIPS III, big-endian, with its FPU |
| Identity | `PRId` `0x2020` (implementation 0x20, revision 2.0); `FIR` `0x2020` |
| Clock | `clk_sys`, 50 MHz, clock enable tied high; `Count` advances every second clock |
| TLB | 48 entries, all matched at once, behind a one-page instruction mini-TLB and a four-entry data mini-TLB |
| Instruction cache | 16 KB, direct-mapped, 32-byte lines, physically indexed and tagged |
| Data cache | 16 KB, direct-mapped, 32-byte lines, write-back, physically indexed and tagged |
| Secondary cache | none (`Config.SC` = 1) |
| Physical address | 32 bits |
| Interrupts | five level-sensitive lines from INT2 into `Cause.IP[6:2]` |

What IRIX's `hinv` says about it on the board (and it lists no secondary
cache):

```
1 50 MHZ IP22 Processor
FPU: MIPS R4600 Floating Point Coprocessor Revision: 2.0
CPU: MIPS R4600 Processor Chip Revision: 2.0
Data cache size: 16 Kbytes
Instruction cache size: 16 Kbytes
```

That was captured on build 25 (2026-09-08,
`git show fddd123:tests/out/hw/hinv-b25.txt`); nothing it reads - `PRId`,
`FIR`, `Config`, the rate of `Count` - has changed since. The 50 MHz is a
measurement rather than a label: IRIX derives it from `Count`
([docs/48](../history.md#48)), which `cpu_cop0.vhd` reads out as bits 32:1 of
a counter that advances every clock, so it runs at 25 MHz - `bench/count_rate`
on the board counts 49,999,991 ticks in two seconds
([design/r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md) §7).

## Where it comes from

The sources in `rtl/cpu/r4300/` are `MiSTer-devel/Arcade-KillerInstinct_MiSTer`
`rtl/cpu/` at commit `5c443bd`. That CPU is a fork of the
`MiSTer-devel/N64_MiSTer` R4300i, which was this core's CPU until 2026-09-07;
every change made on the N64 base was carried across. The directory, the
wrapper (`rtl/cpu/r4300_wrap.vhd`) and the bus adapter (`rtl/cpu/r4300_bus.sv`)
keep the R4300 name because nothing outside them cares what the part calls
itself. The licence is GPL-3.0, which is why this repository is.

What the Killer Instinct base brought over the N64 one - timing work in the
fetch path and the 64-bit region decode, a 16 KB data cache with 32-byte lines,
and the kernel-mode rule in
[cpu-validation.md](cpu-validation.md#kernel-mode-is-exl-or-erl-not-just-ksu) -
is listed in UPSTREAM.md, as is the one thing it brings that this core does not
take: a clock-domain-crossing mailbox on the memory path. Here `clk1x`,
`clk2x` and `clk93` are all the one system clock, where the mailbox was only
dead clocks on every uncached access and every miss.

Every local change carries an `-- SGI:` comment giving its reason.
`tools/diff_upstream.sh <Arcade-KillerInstinct_MiSTer checkout>` prints the
whole delta, so UPSTREAM.md's list can be checked rather than trusted.

## Two toolchains, one source

**Quartus compiles the VHDL directly.** `files.qip` lists the primitives in
`rtl/cpu/prim/` (in the `mem` library, where `cpu.vhd` instantiates them as
`entity mem.<name>`), the vendored files, `r4300_wrap.vhd` and `r4300_bus.sv`.
There is deliberately no checked-in netlist to drift out of step with the
source.

**Verilator gets Verilog from GHDL.** `tools/gen_r4300_verilog.sh` lowers the
same files with GHDL's own synthesis backend (`ghdl synth --out=verilog`; no
Yosys) into `rtl/cpu/generated/r4300_wrap.v`, which is gitignored. It works on
a copy, so the files Quartus compiles are never patched.

**Regenerate it after every VHDL change.** The `verilator/Makefile` rule for
`r4300_wrap.v` has no prerequisites: it runs the script only when the file is
missing. An edited CPU with an old generated file builds a model of the old
CPU, or fails with `PINNOTFOUND` if a port changed. Run the script, or delete
`rtl/cpu/generated/`, before `make`. The script checks that `ghdl` actually
runs rather than only that it is on `PATH`: a GHDL whose LLVM backend cannot
load its library otherwise fails late and leaves the old file in place, and
the error message gives the one-line library shim that fixes the Debian
package.

Two GHDL problems are worked around on the way:

- **GHDL 6.0.0** raises `TYPES.INTERNAL_ERROR : netlists-utils.adb:166` on a
  `numeric_std` comparison between operands of different widths. `cpu.vhd` has
  exactly one, `value1 <= x"FFFFFFFFFF"` against a 64-bit `unsigned` in the
  64-bit region decode - legal VHDL, which zero-extends the shorter side. The
  script widens the literal in its copy, and stops if the literal is no longer
  there to widen.
- **GHDL 4.1.0** lowers `shift_right` of a `signed` operand to Verilog's
  `$signed(x) >> n`, which is a logical shift. `cpu.vhd`'s shifter does that
  once, so under Verilator `dsra`, `dsra32` and `dsrav` returned a single sign
  bit instead of a sign fill, while Quartus, which reads the VHDL, was right.
  The script rewrites the operator to `>>>` in its output and prints how many
  it rewrote: one, unless GHDL or `cpu.vhd` has changed.

**The Altera megafunctions are replaced for both toolchains.** The vendored
files instantiate `altsyncram`, `altdpram` and `altera_mult_add`;
`rtl/cpu/prim/` has behavioural stand-ins with the same port lists, so the CPU
builds without `altera_mf`. Two details are load-bearing:

- The RAMs are configured `NEW_DATA_NO_NBE_READ`: a port that reads and writes
  one address in the same clock sees the **new** data. `dpram.vhd` models that
  write-first; modelling it as read-old is a silent one-clock-stale bug in the
  cache tag path. Read-during-write *across* ports is undefined in the
  hardware and the models resolve it by process order, which is why the fill
  path has an ordering rule ([below](#a-miss-is-one-burst)).
- `cpu_mul.vhd` has the megafunction's two register stages; `cpu.vhd` waits at
  least four clocks for a product anyway.

## The wrapper: `rtl/cpu/r4300_wrap.vhd`

**A flat port list.** `cpu.vhd`'s entity has a `buffer`-mode `mem_address`,
`unsigned` ports and, inside `-- synthesis translate_off`, a record-typed
`cpu_export` output. One level down they are all ordinary signals, so the
wrapper costs nothing and gives both toolchains a plain top.

**Reset, and the boot PC.** `cpu.vhd` does not reset to a constant. `SS_reset`
loads a savestate shadow register, `ss_in(0)`, with `0xFFFFFFFF_BFC00000`, and
`reset_93` then copies `ss_in(0)` into the PC; leave `SS_reset` low and the CPU
resets to zero. The wrapper's sequencer pulses `SS_reset` for one clock, writes
`0xFFFFFFFF & boot_pc` into `ss_in(0)` through `SS_wren_CPU`, holds the CPU in
reset for `SETTLE_CLOCKS` more while `reset_93` latches it, and lets go. It
runs on `clk` whatever `ce` is doing, so a stopped clock enable cannot strand
the CPU mid-reset.

`SETTLE_CLOCKS` is 2048 because of the caches. Each answers `SS_reset` by
clearing its 512 tag entries one per clock, and neither looks at `reset_93`.
Release the pipeline sooner and the first cached access lands while the data
cache is still clearing, where nothing latches it: `cpu.vhd` waits for a
`write_done` that never comes, and `error_stall` fires 4096 clocks later. 2048
is 512 with a factor of four in hand.

`boot_pc` is `0xBFC00000` on the board (`sgiindy.sv`): the MIPS reset vector,
and where the PROM is - the IP24's, or the test-suite image in
[cpu-tests-on-hardware.md](cpu-tests-on-hardware.md). The simulator sets it to
an ELF's entry point when given `--elf`, which is what lets the bare-metal test
suite run with no PROM at all. The upper word is all ones because the PC is a
64-bit register, and `0x00000000_BFC00000` would be xkuseg, not KSEG1.

**The fixed settings.**

| Port or generic | Value | Why |
|---|---|---|
| `clk1x`, `clk2x`, `clk93` | all `clk` | one clock domain; UPSTREAM.md, "The memory path" |
| `ce_1x`, `ce_93` | `ce` | tied high in `sgiindy.sv` |
| `INSTRCACHEON`, `DATACACHEON` | the OSD's "Primary caches" option | both on by default. The simulator's `--no-icache` and `--no-dcache` turn them off separately, which is how a fault is bisected onto one cache without a rebuild |
| `DATACACHETLBON` | `'1'`, upstream `'0'` | mapped data accesses go through the data cache too. With KSEG0 cached and mapped pages not, two views of one physical page disagree; `tlb/translation_works` writes through KSEG0 and reads back through a mapping |
| `DATACACHEFORCEWEB` | `'0'` | the comment at the port records what happened when it was set, and why it is not a switch this core can turn on |
| `ALECK64` | `'0'` | the only thing it did upstream, widening TLB translations past 29 bits, is unconditional here |
| `DEBUG_TRACE` | `false` | KI's 896-bit execution trace; nothing reads it, and every `debug_*` port is left open |
| `irq_lines` | INT2's five lines | `Cause.IP[6:2]`, low to high: LOCAL0, LOCAL1, 8254 counter 0, 8254 counter 1, bus error. Levels, driven by `rtl/sgi/sgi_ioc.sv`; `IP7` (Count/Compare) and `IP1:0` stay CP0's own. `tests/run-int.sh` runs the path from an 8254 counter to an Interrupt exception |

The `dbg_*` outputs are observability wires: the PC entering decode and the
mode it decodes in, each accepted exception with `Cause`, `EPC` and
`BadVAddr`, a retire-side PC, register 31 at retirement (for the board's
profiler), the performance-counter events, and the two caches' access streams.
[simulation.md](simulation.md) documents what the harness does with them.

## The bus adapter: `rtl/cpu/r4300_bus.sv`

`r4300_bus` turns the CPU's `mem_*` port into SGI bus requests, and it is the
only place the byte order changes. The file's header has the full derivation;
this is the contract. On the CPU side `mem_dataRead` and `mem_dataWrite` are
little-endian byte lanes - lane L is bits 8L+7:8L. On the SGI side everything
is big-endian, as every SGI register and every PROM structure is:
`bus_wdata[63-8i -: 8]` is the byte at `bus_addr + i`, guarded by
`bus_be[7-i]`. And the CPU side is not symmetric between reads and writes.

**Reads.** `cpu.vhd` wants the addressed data at the *bottom* of
`mem_dataRead`: the aligned doubleword shifted right by eight times the byte
offset. The data cache applies the same rule on the cached path (`read_data`
in `cpu_datacache.vhd`), and every load type in `cpu.vhd`'s stage-4 writeback
takes its bytes from the bottom (`bus_to_cpu16/32/64`).

**Writes.** The halves swap. `cpu.vhd` presents the low-address word in bits
63:32 whenever the access is 64-bit or lands in the upper half of the
doubleword. The data cache's big-endian write path undoes it, and so does the
adapter (`swap_halves = mem_req64 | mem_address[2]`). The case that pins it
down is SDR at offset 0: write mask `00010000` (lane 4), carrying the
register's least significant byte in bits 39:32, for a one-byte store to
doubleword offset 0.

**Byte enables mean nothing on a read.** `mem_writeMask` holds whatever the
last write left there, so a device with more than one register in a
doubleword cannot select on it. The adapter carries `bus_aoff`, the access's
byte offset within its doubleword, and that is what such devices decode.

**Unaligned loads on the uncached path.** `cpu.vhd` aligns the address it
hands the data cache for LWL/LWR/LDL/LDR, but puts the raw address on
`mem_*`, which looked like a gap in the shift rule. On the R4300-based core it
was not one: the suite's `mem/` tests, which run the whole unaligned family at
every offset, passed there with both caches off as well as on (the adapter's
header records it). With the caches on, which is how the suite runs now, those
loads go through the data cache.

## What it tells software it is

An Indy shipped with an R4000, R4400, R4600 or R5000 - never an R4300 - and
software identifies the part from `PRId` alone. The KI base already reports an
R4600, and `PRESENT_AS_R4600` in `cpu_cop0.vhd` selects what has to go with
that. It is a commitment, not a label, because software reads several things
from `PRId` that it can read nowhere else:

- **The TLB size.** No register reports it; IRIX takes it from `PRId`. An
  R4600 has 48 entries and KI's TLB had 32, and a part that reports an R4600
  and aliases entries 32..47 onto 0..15 corrupts its own page tables the first
  time the kernel writes a high index. `TLB_ENTRIES` is derived from
  `PRESENT_AS_R4600`, so the two cannot disagree.
- **The data-cache line.** IRIX 5.3 hard-codes it from `PRId` in
  `__dcache_inval` / `__dcache_wb_inval` - 32 bytes for implementation 0x20, 16
  for an R4400 - and never reads `Config.DB`. That is why this core is an R4600
  and not the R4400 the R4300-based core presented as (`PRId` `0x0440`) until
  2026-09-07: a data cache with 32-byte lines cannot pose as an R4400
  ([docs/39](../history.md#39), [docs/43](../history.md#43)).
- **Page colouring.** IRIX sets `cachecolormask` from `PRId`: 1 for an R4600,
  whose cache ways are 8 KB, and 3 for an R4400. That decides which virtual
  index bits it keeps equal to the physical ones, and it is why both caches
  here are physically indexed ([Caches](#caches)).
- **The PROM's clock setup.** The routine at `0xBFC312F8` reads `PRId` and
  divides the clock it measures by a per-family ratio table indexed by
  `Config.EC`: `{2,3,4,6,8,2,3,4}` for an R4000/R4400, `{2,3,4,5,6,7,8,0}`
  for an R4600/R4700/R5000. The R4300's reset value, EC = 7, reads 0 in the
  second table, and the routine's divide-by-zero guard - `break 7` at
  `0xBFC313DC` - stopped the first R4600 boot. `Config.EC` is 0 here, which is
  what an Indy R4600 has: its SysAD bus runs at half the pipeline clock.
- **`FIR`**, which `hinv` names the FPU from: `0x2020`, implementation 0x20
  revision 2.0, like `PRId`. It is hard-wired in `cpu_FPU.vhd` and kept in
  step with `PRESENT_AS_R4600` by hand.

`Config` reports 16 KB with 32-byte lines for both caches (IC = DC = 2,
IB = DB = 1), which is what an R4600 reports and what both caches are. It has
not always been true - the R4300-based core reported 16 KB with 16-byte lines
over a 16 KB / 32-byte instruction cache and an 8 KB / 16-byte data cache, and
build 24's 8 KB instruction cache reported 16 KB - and the rule that made
those reports safe is worth keeping for the next time the geometry changes:
over-reporting a cache size makes an index flush visit some lines twice, and
under-reporting a line size makes a range flush issue two operations per line.
Both are harmless. The opposite errors skip lines.

Setting `PRESENT_AS_R4600` false goes back to the R4300's `PRId` (`0x0B22`),
32 TLB entries, the R4300's `Config` geometry (16 KB / 32-byte and 8 KB /
16-byte, which no longer describes these caches) and EC = 7. `FIR` stays
`0x2020`, `cpu.vhd` no longer carries a copy of the constant (the behaviours it
selected there were reverted, [below](#what-was-changed-in-the-vendored-cpu)),
and the cpu-tests suite has no R4300 case and refuses to run. It is not a
supported configuration; the constant exists so that identity and TLB size stay
one decision.

### No secondary cache

`Config.SC` (bit 17) is 1: no secondary cache, which is what an R4600 reports
(cpu-tests' `docs/r4600.md`). The suite derives its `have_l2` from that bit
and, with it set, skips every secondary-cache operation; IRIX's `hinv` lists
no secondary cache. The opposite report would be the dangerous one: it would
send both of them `CACHE_SD` operations for a cache that does not exist.

### Physical addresses are 32 bits

An R4000-family part has a 36-bit physical address: `EntryLo`'s PFN is 24
bits (29:6), and 24 + 12 = 36. This core carries 32, in a place that is easy
to miss because the CP0 registers are the right width and only the TLB behind
them is not:

- `EntryLo0` and `EntryLo1` hold the whole 24-bit PFN, so a write and read-back
  **through the register** keeps every bit;
- `tlbwi` / `tlbwr` store only PFN bits 19:0 in the entry RAM
  (`TLBWRITE_phyAddr0/1`) and `tlbr` zero-extends them, so a round trip
  **through the TLB** drops PFN bits 23:20;
- `mem_address` is 32 bits, so no translation could put more on the bus.

Nothing on an Indy needs more: the highest physical addresses it uses, high
local memory at `0x20000000`-`0x2FFFFFFF`, fit with room to spare. What did
need fixing was the N64's truncation of every translation to 29 bits, which
put every high-memory access at `0x00000000` and made the PROM report "No
usable memory found" (UPSTREAM.md, "Machine size"). The cpu-tests suite cannot
see the 32-bit limit: its TLB tests build every `EntryLo` from
`scratch_phys()`, an address in the suite's own RAM, so PFN bits 23:20 are
never set.

## The TLB

48 entries, as on an R4600. Upstream compared them one per clock, starting from
the entry that matched last, which suits an N64 game that barely maps anything.
IRIX maps every user program, and on the board the walk was live in 14.5 % of
an IRIX boot's busy clocks (build 27). Now the fields a match needs - VPN2,
page mask, ASID, region, global - are shadowed in registers beside the entry
RAM (`TLBSH_*`), written by the same write that writes the RAM, and all 48 are
compared at once: a lookup finds its entry in one clock and translates in the
next, and `tlbp` answers from the match directly. The entry RAM stays the
source of `tlbr` and of the translation. Where two entries match - which IRIX
never creates, and an R4000 answers with a machine check - the lowest index
wins.

In front of it are a one-page instruction mini-TLB and a four-entry data
mini-TLB (`cpu_TLB_instr.vhd`, `cpu_TLB_data.vhd`). `Random` counts down from
47 to `Wired` and reloads, with an extra arm at zero so that a `Wired` the
part does not have bounds it instead of letting it run through 63..48.

The measurements behind the parallel match are in
[design/cpu-speed-tlb-icache.md](../design/cpu-speed-tlb-icache.md).

## Caches

Both primary caches are on unless the OSD's "Primary caches" option turns
them off.

| | instruction cache | data cache |
|---|---|---|
| size | 16 KB, 512 lines of 32 bytes | 16 KB, 512 lines of 32 bytes |
| organisation | direct-mapped | direct-mapped, write-back |
| index | physical address bits 13:5 | physical address bits 13:5 |
| tag compared | physical bits 31:12 | physical bits 31:14 |
| source | `cpu_instrcache.vhd` | `cpu_datacache.vhd` |

A real R4600's caches are two-way, 8 KB a way. These are direct-mapped and
report the R4600's geometry; the suite's `cache/set_conflict` checks only that
a conflict never returns the wrong line, which a direct-mapped cache satisfies
(cpu-tests' `docs/r4600.md` says so).

### Why both are physically indexed

With 4 KB pages, a 16 KB direct-mapped cache takes index bits 13:12 from above
the page offset. Indexed virtually, it holds a physical line in whichever set
the virtual address names, and stays correct only if software keeps those bits
equal between every mapping of a page. IRIX, told it has an R4600, keeps only
bit 12 equal (`cachecolormask` 1), and not on every path. Every virtually
indexed version failed on IRIX:

- KI's data cache as shipped - 16 KB, virtual bits 13:5 - killed `init` on the
  board and in the simulator: a page of `/sbin/init`'s text read back as
  zeros, dirty zero lines from the kernel's page clearing written back over it
  after an invalidate had looked in the wrong set
  ([docs/39](../history.md#39));
- KI's instruction cache, the same shape, gave build 23 a storm of bus errors,
  segmentation faults and illegal instructions once IRIX reached `rc2`
  ([docs/45](../history.md#45));
- an 8 KB instruction cache indexed on virtual bit 12 - the one bit IRIX
  colours - still lost `init` to SIGSEGV about one boot in three on build 24,
  because IRIX does not colour every mapping ([docs/47](../history.md#47)).

So both caches take index bits 13:12 from the translation. The data cache takes
them from the data mini-TLB, re-reading the tag on the clock a mini-TLB miss
resolves; the instruction cache takes them from the instruction mini-TLB's
physical page, a plain register, so the physical bits cost one 2:1 mux on the
fetch path. Both fill at the physical index they tag with. A line then lives in
exactly one set for every mapping, and the kernel's hit operations by physical
address find it - the instruction cache's `Hit_Invalidate_I` is translated,
like the data cache's hit operations. The instruction cache went back to 16 KB
on build 28, once it was physically indexed
([design/cpu-speed-tlb-icache.md](../design/cpu-speed-tlb-icache.md)).

### What is cached

KSEG1 never is. KSEG0 is cacheable unless `Config.K0` is 2, for both fetch
paths and for data. Upstream stored K0 and never acted on it, since an N64
never writes `Config`; the IP24 PROM comes out of reset with K0 = 2 and has a
pair of routines, at `0xBFC04798` and `0xBFC047D8`, that switch it to 3 and
back around the code that wants the caches. Only the encoding 2 means
uncached, so every other value stays cacheable - including the reserved 0 this
core resets to, which is what the bare-metal suite runs with. Mapped data
accesses follow their TLB entry's cache attribute, through the data cache
(`DATACACHETLBON`, above).

### A miss is one burst

`cpu.vhd` puts a line fill through the same write FIFO as every other access,
tagged with `mem_size`: `"100"` for a data-cache line, `"101"` for an
instruction-cache line, `"001"` for a single access. The FIFO has already
aligned the address to the line. `r4300_bus` makes it one bus request for four
doublewords (`bus_burst`); main memory streams them back, one `bus_ack` each
and `bus_last` on the fourth. Any other responder - the PROM, a hole in
MEMCFG - answers one word with `bus_last` set, and the adapter asks for the
rest, so a line that runs out of the PROM or off the end of a bank gets what
those devices answer, word by word, with no rule of its own.

The data does not come back on `mem_dataRead`. The caches take their beats on
`ddr3_DOUT` / `ddr3_DOUT_READY`, armed by `rdram_granted2x` - upstream's
connection to the N64's RDRAM controller - which the wrapper brings out as
`fill_data`, `fill_data_ready` and `fill_grant`. Three orderings are
load-bearing:

1. **One clock of `fill_grant`, never overlapping a data beat.** The grant
   takes priority over the cache's beat counter, so a beat that arrives with
   it is dropped.
2. **The cache must not see the fill finish before the last beat is
   written.** The data cache answers the access out of the line in the clock
   it sees `ram_done`, reading port B of a RAM whose port A writes the beats,
   and for a store it merges the write into the line on port B on that same
   edge. Read-during-write across ports is undefined, so an overlap makes the
   answer depend on process order; the symptom was a load of a line's second
   doubleword coming back stale, and the suite jumping through a garbage
   pointer. Since build 38 the adapter does not register the beats -
   `fill_data_ready` is `bus_ack` in `S_FILL` - so a word is written on the
   edge that ends the clock it came off the bus, `mem_done` rises on the edge
   that writes the last one, and `cpu.vhd` registers it into `ram_done` a
   clock later. That clock is the separation the rule needs.
3. **The tag must be the address the cache compares.** The instruction cache
   tags a line with `mem1_addrCompare`. Moving the kseg0/kseg1 strip onto
   `mem1_address` once made its tag physical while its compare was still
   virtual, and every fetch missed - correct instructions, one whole line read
   for each.

**Refills answered from the cache.** `cpu.vhd` asks for an instruction line
fill after every instruction TLB walk, without a lookup. The instruction cache
answers a fill for a line it already holds from a third copy of its tags, in
block RAM (`itagramf`), three clocks later and with no bus transaction.

**Line writes.** A dirty data line goes back as one transaction: `cpu.vhd`
issues a write tagged `"100"`, with word 0 on `mem_dataWrite` and words 1-3 on
`mem_dataWrite3`; the adapter undoes the cache's half swap word by word and
sends one request with `bus_burst` = 4, which `ddr3_mux.sv` writes back to
back and acknowledges once. Only main memory is ever asked for one - the data
cache writes a line back to where it filled it from.

Where a fill's clocks go on the board, and what the line writes and the other
fill-path changes bought, is measured in
[design/cache-fill-latency.md](../design/cache-fill-latency.md).

### Coherency is software's job

Nothing in the core keeps the instruction cache coherent with the data cache,
or either cache with DMA: `cpu.vhd` has no snoop port and no cross-invalidate.
Software does it with `cache` operations - written instructions reach fetch
only once the data line has been written back and the instruction line
invalidated, which is what the suite's `cache/icache_coherency` checks. A
`cache` operation this core does not implement stops at decode and does
nothing - the IP22 kernel executes about a thousand secondary-cache and
instruction-cache operations per boot, and each is safely nothing here only
because it goes no further - and one that reaches the instruction cache while
it is filling is held and retired when the fill ends rather than dropped.

## What was changed in the vendored CPU

UPSTREAM.md has every change, its reason and the test that covers it. In
outline:

| Area | Changes |
|---|---|
| Corrections against the R4000 manual | An exception taken with `EXL` already set keeps `EPC` and `Cause.BD` - except a provisional fetch-side fault for a user-mode instruction ([docs/25](../history.md#25)); a TLB refill taken with `EXL` set goes to the general vector ([cpu-validation.md](cpu-validation.md#a-tlb-refill-taken-with-exl-set)); a misaligned `lwc1`/`ldc1`/`swc1`/`sdc1` raises AdEL/AdES; a memory fault that is not an alignment fault reports AdEL/AdES by the direction of the access, not Int; the CP0 instructions and `cache` raise Coprocessor Unusable outside Kernel mode unless `Status.CU0` is set; opcode 0x33 raises Reserved Instruction; an unimplemented `cache` operation stops at decode; a `cache` command that arrives during an instruction-cache fill is held rather than dropped |
| FPU | an exactly-zero sum keeps the operands' sign when they agree; no divide-by-zero for `inf / 0`; `cvt.s.l` / `cvt.d.l` raise Unimplemented Operation for a source beyond ±2^53, as the Indy's parts do (upstream's bound is the R4300's ±2^55) |
| Identity | `PRId` and `FIR` `0x2020`, 48 TLB entries, `Config`'s cache geometry and `EC` - above |
| Machine size | TLB translations are not truncated to 29 bits; the kseg0/kseg1 strip is on the unmapped fetch path, not in the write FIFO |
| Interrupts | five level-sensitive lines into `Cause.IP[6:2]` in place of the N64's two |
| Caches | `Config.K0` honoured; the instruction cache tagged with `mem1_addrCompare`; both caches physically indexed; the instruction cache 16 KB; refills answered from the cache; a dirty line written back as one transaction; instruction line fills tagged `"101"` |
| Speed | all 48 TLB entries matched at once; a load leaves execute without stalling it unless the next instruction names the loaded register or is a memory access other than an integer load or store (`LOAD_NO_STALL`, `LOAD_NO_STALL_MEM`, both on); KI's clock-domain-crossing mailboxes removed |
| Observability | the `dbg_*` ports |

Three earlier SGI changes are gone: the NaN polarity, Reserved Instruction for
the MIPS IV COP1 function codes, and COP2 unusable whatever `Status.CU2` said.
Each had been made to match the cpu-tests suite's expectations of the time.
When the suite ran on real Indys those expectations turned out wrong and
upstream's behaviour right, so upstream's code stands again, with no `-- SGI:`
mark. What the silicon does - the legacy MIPS NaN encoding, in which a set
fraction MSB marks a *signalling* NaN; Unimplemented Operation for a COP1
function code the FPU lacks; no exception at all for `mfc2` with CU2 set - is
in UPSTREAM.md and
[design/r4600-accuracy-clock-disk.md](../design/r4600-accuracy-clock-disk.md) §2.

## How it is checked

| Check | Result |
|---|---|
| cpu-tests, R4600 case, on the board: the suite as the PROM, build 44 (release SGIIndy_20260918) | **2415 checks passed, 0 failed**, 255 tests |
| cpu-tests, R4600 case, in the simulator: the current CPU RTL, last run 2026-09-17 | **2409 passed, 0 failed**, 250 tests |
| `make -C verilator cpuonly`: the CPU and `r4300_bus` alone, against a memory whose answer latency is swept, 2026-09-17 | 728 runs, 0 against expectation |
| `tests/run-irix.sh`: an installed IRIX 5.3 root booted in the simulator until the kernel prints its banner | skips without the image, which the repository cannot carry |

The suite, its R4600 case and why the board runs five more tests than the
simulator are in [cpu-validation.md](cpu-validation.md); running it on the
board is [cpu-tests-on-hardware.md](cpu-tests-on-hardware.md). IRIX is the
other half of the check: the suite runs in Kernel mode, almost entirely
unmapped, and the two CP0 bugs that first stopped the IRIX kernel passed every
test it had ([cpu-validation.md](cpu-validation.md#what-the-suite-cannot-see)).
