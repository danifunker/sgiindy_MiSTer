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
| `PRId` | `0x00000440` | `0x00002321` | **`0x00000B22`** (`cpu_cop0.vhd:431`) | `identity/t_prid` fails; suite picks R4400 expectations by default |
| `FIR` | `0x00000500` | `0x00002300` | R4300 value | `identity/t_fir` fails |
| TLB entries | 48 | 48 | **32** (`cpu_cop0.vhd:321`, `array(0 to 31)`) | `identity/t_tlb_size` and parts of `tlb/` fail |
| I$ / D$ | 16 KB / 16 KB, 16-byte lines | 32 KB / 32 KB, 32-byte lines | 16 KB / 8 KB | `identity/t_config_cache_geometry` fails |
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
| **this core, R4300** | **2114** | **9** | **3** |

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
