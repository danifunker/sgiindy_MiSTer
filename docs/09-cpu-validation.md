# CPU validation: the IRIS bare-metal test suite

There is an existing SGI Indy emulator project at `~/repos/iris` — **IRIS**, a
Rust IP24/IP22 emulator that boots IRIX 6.5 and 5.3 with working Newport
graphics, networking and X11. It carries a bare-metal MIPS III/IV CPU test
suite in `~/repos/iris/cpu-tests/`.

That suite is the single most valuable thing available to this project, and it
is what makes targeting the **Indy** realistic rather than speculative.

## Why it matters

The biggest risk on the Indy path was always CPU correctness: the only usable
64-bit MIPS core is the N64 R4300i, and "does an R4300i behave enough like an
R4x00 for the IP24 PROM and IRIX?" was an open question with no cheap way to
answer it. This suite answers it directly, with 240 tests / ~800 checks.

Better still, **it needs almost nothing from the chipset**:

| What the suite needs | Status |
|---|---|
| A CPU | the thing under test |
| RAM at phys `0x08000000` | trivial |
| SCC channel B TX at `0x1FBD9830` / `0x1FBD9834` | `z8530_scc.sv` already does this |
| *(optional)* an IRIS test device at `0xBF400000` | probed, not assumed — skip it |

No PROM, no MC, no HPC3, no NVRAM, no interrupts, no graphics. **The suite can
run on the core under Verilator long before the PROM can**, which makes it a far
better first bring-up target than "execute PROM instructions and hope".

Note the address match: `iris.h` defines `IOC_BASE 0xBFBD9800`, `SCC_CHB_CMD
= +0x30`, `SCC_CHB_DATA = +0x34`. That is exactly the window the DE1 sandbox
already decodes (`SCC1_CMD_CS` at `0x1FBD9830`, `SCC1_DATA_CS` at `0x1FBD9834`).
The channel naming differs — IRIS calls it channel B / tty1, the sandbox RTL
calls it channel A / Port 1 — so check which channel the SCC model actually
drives before concluding the console is broken.

## What the suite covers

| group | tests | what it covers |
|---|---:|---|
| `identity` | 5 | PRId, FIR, cache geometry, `Config.K0`, TLB size |
| *(R4300 values)* | | `PRId 0x0B22`, `FIR 0x0A00`, `Config 0x7006E460`, 32 TLB entries, 16 KB/32 B I$ + 8 KB/16 B D$ |
| `alu` | 29 | sign extension across the 32/64-bit boundary, overflow traps, shifts, logic, SLT |
| `muldiv` | 18 | mult/div in both widths, HI/LO, the architecturally-unspecified cases |
| `mem` | 18 | load/store widths, the whole unaligned family at every offset, alignment faults, KSEG0/KSEG1 |
| `branch` | 15 | every conditional, likely-nullification, link registers, delay slots, faults in delay slots |
| `excep` | 15 | traps, reserved instructions, coprocessor usability, EXL/ERET, vector selection |
| `cp0` | 21 | read-only registers, reserved-bit masks, 64-bit access, Count/Compare, LL/SC |
| `tlb` | 10 | entry round-trip over all 48, TLBP, every page size, real translation, V/D bits, ASIDs, refill |
| `fpu` | 88 | both formats, rounding modes, traps, denormals, all 16 compare predicates, FR=0 pairing, generated IEEE-754 vectors |
| `cache` | 8 | geometry, tag round-trip, cached/uncached views, I-cache coherency |
| `mips4` | 13 | every MIPS IV addition — computes on R5000, must raise RI on R4400 |
| **total** | **240** | |

## Why it is trustworthy

`cpu-tests/docs/oracle.md` sets out a strict expectation policy, in priority
order: the R4000 manual first (quoted inline in the tests), then nothing at all
where the manual is silent (those cases *report* rather than assert), then
host-computed exact-rational IEEE-754 vectors, then MAME/QEMU as tiebreakers,
then real hardware, and only as a last resort a golden recording — which must
say so in the test comment.

It has already caught the *test* being wrong twice and says so. That is the
mark of a suite worth trusting.

It also does differential testing that needs no oracle: every `mips4/` test
runs on both CPUs and branches internally — the instruction must compute on
R5000 and raise Reserved Instruction on R4400 — with `mips4/mips3_control` as a
negative control so a CPU that raises RI for everything cannot pass by accident.

## The catch: an R4300i is not an R4400

The suite reads `PRId` at startup and picks R4400 or R5000 expectations. The
N64 R4300i is a third part, and the suite will correctly report the differences.
Verified against `~/mistersgi/R4300_VHDL/cpu_cop0.vhd`:

| | R4400 (suite expects) | R5000 | **N64 R4300i** | Consequence |
|---|---|---|---|---|
| `PRId` | `0x00000440` | `0x00002321` | **`0x00000B22`** (`cpu_cop0.vhd:431`) | handled — imp `0x0B` selects the R4300 cell (`iris.h:113`), revision checked loosely |
| `FIR` | `0x00000500` | `0x00002300` | **`0x00000A00`** | handled — `FIR_R4300` (`iris.h:88`) |
| TLB entries | 48 | 48 | **32** (`cpu_cop0.vhd:321`, `array(0 to 31)`) | handled — `TLB_ENTRIES_R4300` (`iris.h:257`), selected in `testlib.c:187` |
| I$ / D$ | 16 KB / 16 KB, 16-byte lines | 32 KB / 32 KB, 32-byte lines | 16 KB / 8 KB | handled — `is_r4300()` branches in `identity.c:54` and `cache.c:49` |
| `Config` IC/DC/IB/DB fields | populated | populated | **populated** — measured `0x7006E460` | ✅ 16 KB/32 B I$, 8 KB/16 B D$; the "reads as 4 KB" worry was wrong |
| Endianness | big | big | **big** — `COP0_16_CONFIG_bigEndian <= '1'` at reset (`cpu_cop0.vhd:582`) | ✅ correct for SGI |
| MIPS IV | absent (must raise RI) | present | absent | `mips4/` should behave like R4400 ✅ |

Two of those are good news. The R4300i is **natively big-endian**, which
settles the endianness question in `docs/04-cpu.md`: the sandbox's
`data_flipped` byte reversal exists only to feed the little-endian aoR3000 and
**must not be carried forward**. And Config bit 15 is exactly the bit the IP24
PROM reads back and branches on in `realstart`, so the PROM will see the right
answer.

### How to handle the divergences — done

`CPU_R4300` was added to the suite, which is its designed extension point
(`harness/testlib.c`, `harness/console.h`). What that involved, and every
decision taken per divergence, is in
[10-r4300-integration.md](10-r4300-integration.md). The plan it followed:

1. Add an `IMP_R4300` / `CPU_R4300` case to the harness, with its own
   expectations for `identity`, TLB size, and cache geometry.
2. For each remaining divergence, decide deliberately — and write the decision
   down — whether to **fix the core** or **accept the difference**:
   - *Fix* anything the IP24 PROM or IRIX actually depends on. The `Config`
     cache-geometry fields are the clearest case: `realstart` derives its
     refresh timing from them, so they must report something sane. Hardwiring
     them in a COP0 wrapper is cheap.
   - *Accept* things nothing depends on. 32 vs 48 TLB entries is visible to
     IRIX and may matter; PRId almost certainly wants spoofing to `0x00000440`
     so the PROM and IRIX identify the machine correctly.

   In the event, seven divergences turned out to be plain bugs in the vendored
   CPU rather than R4300-vs-R4400 differences at all, and were fixed. Only
   three genuine differences needed accepting: the R4300's real COP2 data
   latch, Unimplemented-Operation rather than Reserved-Instruction for an
   unimplemented COP1 function, and the cache geometry.
3. Never edit an expectation to make a test pass. If the core is wrong, fix the
   core; if the test doesn't apply to an R4300, branch it on CPU kind.

Spoofing `PRId` to R4400 is tempting and probably necessary for the PROM, but
be aware it makes the suite assert R4400 behaviour the R4300i genuinely does
not have. Keep the real ID reachable somewhere so tests can branch honestly.

## A TLB refill taken with EXL set — the bug that wedged the IRIX kernel

**This is the eighth bug in the vendored CPU, it was found on 2026-08-31, and
it is the one that stopped the IRIX 5.3 kernel dead after it loaded.** It is
worth reading even if you never touch CP0 again, because of how it hid.

`cpu_cop0.vhd` chose the exception vector like this:

```vhdl
if (COP0_12_SR_errorLevel = '0' and ... tlbMiss ...) then
   exceptionPC <= x"80000000";     -- or 0x80000080, the XTLB vector
else
   exceptionPC <= x"80000180";     -- the general vector
end if;
```

It tests **ERL**. The R4000 rule is **EXL**: offset `0x000`/`0x080` is used for
a TLB refill only when `Status.EXL = 0`, and with `EXL = 1` every exception —
TLB refill included — goes to offset `0x180`. ERL is a different bit and is set
only by Reset, NMI and Cache Error.

**Nothing on an N64 nests a TLB miss, so upstream never saw it. IRIX does it on
every boot and cannot survive it.** Its `utlbmiss` handler at `0x80000000` is:

```
    mfc0  k0, Context
    nop
    sra   k0, k0, 1          # Context indexes 8-byte PTEs; IRIX's are 4
    lw    k1, 0(k0)          # <- the page table is ITSELF mapped
    lw    k0, 4(k0)          # <- so this can miss, and does
```

The second load takes a TLB miss of its own with `EXL` already set. The kernel
expects to land in the general handler, which has the recover-the-page-table
path. Instead it landed back at `0x80000000`, with `EPC` untouched, and re-ran
the same two loads forever.

The fix is one term, and the signal it needs already existed:

```vhdl
tlbRefillVector := (COP0_12_SR_errorLevel = '0' and excSavedEXL = '0' and ...);
```

`excSavedEXL`, **not** `COP0_12_SR_exceptionLevel`. The vector block sees the
exception one clock after it was accepted, and accepting it has already set
`EXL`; reading the live bit sends *every* refill to the general vector.
`excSavedEXL` is the pre-exception value, latched on the same clock `EXL` was
set, and it is what the two EPC-suppression rules in the same file already use.
`tests/tlb/refill_context` in the IRIS suite catches the live-bit version
immediately — it reports `refill vector = 3` where it wants 1 or 2 — which is
the second reason to run the suite after any CP0 edit and not just before.

### How it was found, which is the reusable part

The failure produced **nothing**. No console output, no exception box, no
panic, and — this is the trap — no bus cycles either, because the loop is eight
instructions in the primary caches. On hardware `alive.py` could only say
"memory is not moving"; in simulation `--stuck` had no address to name, and the
bus trace ended mid-routine at an instruction fetch of `0x80000000..0x8000001f`
and never fetched the second half of the handler.

Three things turned that into a one-line fix:

1. **A real installed IRIX disk, in Verilator, on a laptop.** `~/irix-images/
   Indy-IRIX53_dev.chd` is a MAME CHD of an installed IRIX 5.3 root;
   `chdman extractraw` makes it an ordinary image and `--disk 1=...` attaches
   it. That reproduces the hardware wedge **deterministically, at the same
   cycle every time** (182,599,999), in about five minutes, with no board in
   the loop. Reproducing a kernel bug by re-running the *installer* would have
   been hopeless; booting an already-installed disk takes the install out of
   the question entirely.
2. **`--irq`.** It showed the kernel setting `L0_MASK = 0x82`, `L1_MASK =
   0x22` and `MAP_MASK0 = 0x20` and then nothing ever asserting — which ruled
   out "the machine is waiting for an interrupt" and, with `1fbd98b0` at zero
   hits, ruled out "the 8254 is not ticking" as well. Both were plausible and
   both were wrong.
3. **The PC.** `dbg_pc` did not exist; `docs/06` had listed it as the one
   missing instrument for years. Adding it took an afternoon and answered the
   question in a single run: the last 64 PCs were
   `80000000 → 80000004 → 80000008 → 8000000c → 80000010 → 80000000 → …`,
   which is the refill vector re-entering itself. Everything above is
   circumstantial next to that.

## Kernel mode is EXL or ERL, not just KSU — the bug after that one

**The ninth bug, found the same day and in the same file, and it is the one
that kept IRIX from running a single user process.** With the TLB refill vector
fixed the kernel boots, prints its banner, and starts `init` — and then wedges
again, this time in a five-million-iteration loop through its own general
exception handler.

`cpu_cop0.vhd` exported the privilege mode as the raw `Status.KSU` field:

```vhdl
privilegeMode <= COP0_12_SR_privilegeMode;
```

The MIPS rule is that the processor is in **Kernel mode when `KSU = 00` OR
`EXL = 1` OR `ERL = 1`**. Twenty lines away, in the same file, the exception
process computes exactly that correction — and uses it only for `bit64mode`:

```vhdl
mode := COP0_12_SR_privilegeMode;
if (mode > 2) then mode := "10"; end if;
if (COP0_12_SR_exceptionLevel = '1') then mode := "00"; end if;
if (COP0_12_SR_errorLevel     = '1') then mode := "00"; end if;
```

`privilegeMode` is what the address-region decode in `cpu.vhd` uses to choose
between "put this access through the TLB" and "strip the top three bits and go
straight to the bus". Getting that choice wrong is **silent**: the access
completes, at the wrong physical address.

So every exception taken *from user code* decoded its handler's addresses with
the user table. IRIX's general exception handler keeps its scratch area in
KSEG3 and reaches it with a fixed offset off `$zero`:

```
88010184  mfc0 k0, Cause
...
880101a8  sd   at, 0xa038(zero)      # save $at at 0xFFFFA038
880108e8  lw   k0, -0x5fec(zero)     # read a flag at 0xFFFFA014
88010928  lw   sp, -0x5fd0(zero)     # load the kernel stack pointer
88010938  jal  8800b48c              # into the C handler
8800b49c  sw   ra, 0x1c(sp)          # <- faults: sp is 0xFFFFFFFF
```

With `KSU` still 2 the decode called KSEG3 unmapped, stripped the top three
bits, and the whole save area landed at **physical `0x1FFFA000`**, where
nothing answers: writes vanished and reads came back `0xFFFFFFFF`. The handler
loaded its own stack pointer as `0xFFFFFFFF`, faulted on the first push, and
re-entered itself — about five million times before the run gave up.

Nothing on an N64 notices, for the same reason as the last one: its handlers
live in KSEG0, which the *user* table calls unused and which upstream's strip
then maps correctly anyway.

The fix is the correction the file already knows how to make, moved to where
`privilegeMode` is exported.

### The instruments this one needed

`dbg_pc` was not enough on its own, because the loop *did* touch the bus. Two
more went in, and both are cheap and permanent:

- **`dbg_mode`** — `{privilegeMode, bit64region, region_TLBmapped}`, printed
  next to the PC by `--pc`. One line settled it:
  `[226116623] PC 880101a8  ksu=2 32 unmapped`. The `sd` into the kernel's
  save area, decoded in user mode, decoded as unmapped. Everything before that
  line was inference; that line is the bug.
- **`--exc`** — one line per accepted exception with `Cause.ExcCode`,
  `BadVAddr` and `EPC`. From the console every failure is the same three words
  ("generated trap"); this separates a TLB miss from an address error from a
  reserved instruction, and it is what shows `init`'s dynamic linker running
  thousands of instructions and hundreds of syscalls before it dereferences a
  null pointer. **Put its assignments OUTSIDE `-- synthesis translate_off`**:
  the first version of this landed inside the savestate export block, GHDL
  dropped it, and all three registers read as a constant zero in Verilator.
- **`--ramdump ADDR:LEN:FILE`** — guest RAM out to a file, KSEG-stripped, for
  `tools/misterdeploy/disbin.py`. `guestmem.py` for the simulator, and the
  reason the handler above could be read as instructions rather than guessed
  at. (`disbin.py` needs `capstone`; on a PEP-668 Python a venv is the way.)

## Still open: `init` dies with signal 11, and it is the instruction cache

With both fixes above in, IRIX boots, `init` starts, and its dynamic linker
runs thousands of instructions and hundreds of syscalls — and then stores
through a pointer that came out zero:

```
[234801203] EXC TLBS   code=03 badvaddr=0000000c epc=7fc20f90
WARNING: Process [init] 1 generated trap, but has signal 11 held or ignored
PANIC: init died (why = 2, what = 0x9)
```

**The bisection is done.** `--no-dcache` alone still dies; `--no-icache` boots
past `init` as far as `ALERT: ec0: no carrier`. So the instruction cache hands
out a wrong word, rarely. `~/repos/iris` boots the same disk image to "The
system is coming up.", so the image is sound and the fault is this core's.

Ruled out, each by measurement, so nobody repeats them:

| tried | result |
|---|---|
| `DISABLE_DTLBMINI => '1'` (mini data TLB off) | still dies |
| `--no-dcache` | still dies |
| unimplemented `cache` ops made no-ops at decode | still dies (kept: real fix) |
| I-cache commands latched instead of dropped mid-fill | still dies (kept: real fix) |
| translating `Hit_Invalidate I` | **wrong** — the I-cache is virtually indexed, so the untranslated address is the index it needs. Reverted |
| writing the fill's data at the un-pipelined index | no change (kept: hazard removed) |

Worth trying next, in order:

1. **The fill path's clock pipeline.** `cpu_instrcache.vhd` was written for
   three different clocks (`clk1x`, `clk2x`, `clk93`); `r4300_wrap.vhd` ties
   all three to the one system clock. Anything in there whose correctness came
   from a 2× clock is now suspect.
2. **`FetchAddrTLBMuxed1/2` in `cpu.vhd`.** There are two tag comparators, fed
   two different virtual addresses, and both are given the one
   `TLB_instrAddrOutFound`. Within a page that is the same answer; across a
   page boundary it is not.
3. **The alias case.** 16 KB direct-mapped, indexed by virtual bits 13:5,
   tagged with physical bits 31:12, over 4 KB pages — four virtual colours per
   physical page, as on a real R4000. What IRIX assumes about that is worth
   reading before assuming the core is wrong.

### A method note that cost an afternoon

Diffing the PC streams of a good run and a bad one is the obvious way in, and
`--pc-user` exists for it. **The decode tap re-presents an instruction on every
pipeline replay**, and two configurations replay in different places, so a raw
diff confidently reports a divergence that is not there — in this case it
pointed at a two-instruction "loop" at `0x7fc05274` that `--trace-from-pc` then
showed to be `sw ra,0x3c(sp)` in a function prologue, replayed. Collapse
consecutive repeats in both streams before comparing.

`dbg_rpc` / `dbg_retire` were added to fix that properly — a retire-accurate
PC, mirroring `pcOld2..4` outside the savestate export's `translate_off` — and
they are **wired to the harness but not used**, because the stream they produce
is interleaved rather than sequential: the mirror does not yet track the
pipeline the way `pcOld2..4` do. Finishing it is probably the most valuable
hour available on this problem.

## IRIS is also a far better oracle than MAME

`docs/06-simulation.md` recommends diffing against MAME. IRIS is better on
every axis and should be the primary oracle:

- It is a **working Indy** that boots IRIX to a desktop, so its device
  behaviour is validated by the most demanding possible test.
- It has readable Rust implementations of **every device this core needs**:
  `mc.rs`, `hpc3.rs`, `ioc.rs`, `hal2.rs`, `ds1x86.rs` (Dallas RTC),
  `eeprom_93c56.rs`, `rex3.rs` + `rex3_simd.rs` (the rasteriser),
  `vc2.rs`, `xmap9.rs`, `mips_tlb.rs`, `mips_cache_v2.rs`.
- `cpu-tests/docs/memory-map.md` documents the physical map precisely,
  including the trap that the bottom 512 KB is an **alias** of
  `0x08000000..0x0807ffff` and that everything from `0x00080000` to
  `0x08000000` is unmapped and **silently swallows writes**. The sandbox's
  `BANK1_CS` mirror at `0x00000000`–`0x0007FFFF` is exactly this alias.
- It has a GDB stub (`gdb_stub.rs`) and a debug overlay, so it can be
  single-stepped alongside the core.

Keep MAME as a third opinion where IRIS and the manual disagree.

## Running it

```sh
cd ~/repos/iris/cpu-tests
make                  # needs a mips-linux-gnu cross toolchain
                      # or: make toolchain-local
cd ~/repos/iris && cargo build --release
cd cpu-tests && make run
```

Output is a line per test plus `RESULT: N checks passed, M failed`, terminated
by `IRIS-CPUTEST-DONE rc=<failures>` — the exit code **is** the failure count,
and that token is what to match on when scripting.

Reference results, measured rather than quoted — the suite has grown since
`cpu-tests/docs/status.md` was written:

| | checks passed | failed | tests failing |
|---|---:|---:|---:|
| IRIS, R4400 expectations | 2101 | 61 | 25 |
| **this core, as R4400, caches on** | **2161** | **3** | **1** |
| this core, as R4400, caches off | 2155 | 9 | 3 |
| this core, as R4300, caches off | 2114 | 9 | 3 |

The caches-off rows are what `--no-icache --no-dcache` still produces; the
R4300 row has not been re-measured since the caches came on.

The core presents as an R4400, so the first two rows are the same expectations
applied to two implementations. The R4300 row is the same core with
`PRESENT_AS_R4400` off, kept working so the suite's `CPU_R4300` cell stays
exercised.

`tests/baseline/iris-r4400.log` is the IRIS run, kept as the reference;
`tests/compare.py` diffs against it test by test. IRIS's failures are known
findings in `cpu-tests/docs/findings.md` — mostly FPU trap and flag semantics
— and are *not* the core's target: the core should pass them, and after the
FPU fixes in [10-r4300-integration.md](10-r4300-integration.md) it passes
fifteen of them.

`make image` + `run/run-prom.sh` builds an SGI volume-header disk image and
boots the suite through the real PROM path instead of loading the ELF directly.

## Wiring it into this core

The path to running the suite under Verilator:

1. Get the CPU fetching from a RAM model at KSEG0 `0x88200000` (physical
   `0x08200000`, 2 MB into RAM — see `cpu-tests/harness/link.ld` for why that
   address and not `0x80200000`).
2. Have the C++ harness load `build/cputest.elf` straight into the RAM model,
   the way IRIS's `--load-elf` does — no PROM needed. Probe both ends of each
   segment before committing, because unmapped physical space accepts writes
   silently.
3. Wire `z8530_scc.sv` at `0x1FBD9830`/`0x34` and pipe its TX bytes to stdout.
4. Run, and diff the output against IRIS's run of the same binary.

That gives a CPU regression suite running in simulation before a single line of
MC, HPC3 or NVRAM code exists — and it is the same binary that boots on real
hardware, so any result can be checked against iron.

## Running it on real hardware

The same binary boots on a real SGI — see
[11-running-on-hardware.md](11-running-on-hardware.md). **Note that the suite is
MIPS III / n32 and will not run on an R3000 machine.**
