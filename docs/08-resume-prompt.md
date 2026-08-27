# Resume prompt

Paste everything below the line as the opening message of a fresh session.

Keep this file honest. It is the only document a new session is guaranteed to
read, so when something here stops being true it is worse than useless — it
sends the session off to build what already exists. Update it at the end of any
session that changes the answer to "what works" or "what is next".

---

You are continuing work on an **SGI Indy (IP24)** core for MiSTer FPGA. The repo
is `~/repos/sgiindy_MiSTer`. **Work autonomously**: make the routine calls
yourself, keep going through obstacles, and only stop to ask when a decision
genuinely changes what gets built (or when you need something run on real
hardware — see below).

## Where this is

**The CPU works and the SCC transmits. The PROM does not boot yet.**

Milestones M0 and M1 are done (`docs/07-mister-port-plan.md` has the list). The
core runs a 240-test bare-metal MIPS III/IV suite under Verilator against full
R4400 expectations:

| | checks passed | failed | tests failing |
|---|---:|---:|---:|
| IRIS, R4400 expectations | 2101 | 61 | 25 |
| **this core** | **2155** | **9** | **3** |

The three failures are diagnosed, not mysterious: two cache tests (both caches
are switched off) and `cvt.s.l`/`cvt.d.l` truncating their source to 56 bits.

The CPU is the MiSTer N64 project's R4300i, **made to present as an R4400**,
which is what an Indy actually shipped with. That is not just `PRId`: nothing
reports the TLB entry count architecturally, so software infers it from the CPU
identity, and the TLB was widened from 32 to 48 entries to make the claim true.
`PRESENT_AS_R4400` in `cpu_cop0.vhd` is the switch and both settings are tested.

## Read first

`docs/README.md` indexes everything. At minimum, in this order:

1. **`docs/10-r4300-integration.md`** — the CPU as built. The byte-lane
   contract, the R4400 presentation, the eight bugs fixed in the vendored core,
   the numbers. Read this before touching `rtl/cpu/`.
2. **`docs/09-cpu-validation.md`** — the test suite and the oracle policy. This
   is the document that determines *how you work*.
3. `docs/02-address-map.md` — the register map. You will live in this for M2.
4. `docs/03-boot-prom.md` — the PROM's reset flow and the bring-up order.
5. `docs/06-simulation.md` — what the harness gives you.
6. `docs/07-mister-port-plan.md` — the milestones.
7. `docs/prom-reference/HARDWARE.md` — the authoritative per-device reference.

`docs/05-existing-rtl.md` explains the prior DE1 sandbox at `~/mistersgi`. Read
it before copying anything out of there — several of its constructs are
workarounds for DE1 hardware that must not be carried forward, `data_flipped`
above all. `~/mistersgi/sgi_mc.v` is the exception and is your M2 starting
point.

## Build and run

```sh
brew install verilator ghdl
brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu

tests/run-cputest.sh      # 240-test MIPS suite on the core, ~35 s
tests/run-scc.sh          # the Z8530, ~4 s
make -C verilator cputest # just rebuild the simulator
```

Two toolchain facts worth not rediscovering:

- **GHDL lowers the CPU's VHDL to Verilog for Verilator.** Quartus compiles the
  VHDL directly; Verilator cannot, so `tools/gen_r4300_verilog.sh` runs GHDL's
  synthesis backend over the same sources. No Yosys, no `ghdl-yosys-plugin`, and
  nothing checked in — the output is gitignored and the Makefile regenerates it.
  Never reintroduce a checked-in netlist.
- **macOS has no `mips-linux-gnu-gcc`**, but the `mipsel` cross GCC is
  bi-endian: `-EB -mabi=n32` produces exactly the ELF32 MSB image the tests
  want. That is the whole reason this builds on a Mac.

## Validate everything through Verilator

Every claim about the core's behaviour must be backed by a simulation run, not
by reading the RTL. This has already caught things that reading would not — a
CDC race in the SCC's debug tap where the serial line was correct and the
reported bytes were one behind, and an inverted NaN polarity in the FPU that
looked perfectly reasonable in source.

The harness is `verilator/`, headless, no SDL. What it gives you:

| Flag | What it does |
|---|---|
| `--elf FILE` | load a bare-metal ELF and boot from its entry point, no PROM |
| `--prom FILE` | load a PROM image at `0x1FC00000`; `boot_pc` already defaults to `0xBFC00000` |
| `--trace`, `--trace-from`, `--trace-count` | timestamped bus trace with decoded register names |
| `--stuck N` | no-forward-progress detector — names the address being hammered |
| `--hot` | the most-accessed addresses on exit |
| `--uart` | decode the SCC's `txdb` line and compare it with the byte tap |
| `--testdev` | fit the IRIS test device in GIO64 slot 0 |

The stuck detector watches the **bus**, not the PC: `cpu.vhd`'s PC is only
observable through the savestate export, which lives inside a
`-- synthesis translate_off` block and is not in the synthesised netlist.
Watching bus addresses finds the same failures and names the register, which
the PC alone would not.

## The oracles, in order

### 1. The bare-metal test suite — `~/repos/iris/cpu-tests/`

240 tests, ~2200 checks, MIPS III/IV, runs on the CPU with no OS and reports
over the SCC. Its expectations come from the R4000 manual rather than golden
recordings, and it deliberately *reports* rather than asserts where the
architecture is silent. Read `cpu-tests/docs/oracle.md` and honour that policy.

It is **not forked into this repo**, deliberately: it is a general MIPS suite
that also runs on real SGI hardware, and forking it would strand the R4300
support. `CPU_R4300` was added to that checkout — see
`docs/10-r4300-integration.md`.

The standing rule, which has already been load-bearing: **never edit an
expectation to make a test pass.** If the core is wrong, fix the core. If a
test's *precondition* does not hold on this part, fix the precondition and say
why. If two behaviours are genuinely both defensible, accept both and report
which was seen. Eight of the divergences this suite found turned out to be
plain bugs in the vendored CPU; only three were real R4300-vs-R4400 differences.

### 2. IRIS as the behavioural oracle for everything else

`~/repos/iris` is a working Rust Indy emulator that boots IRIX 6.5 to a
desktop, with readable implementations of every device this core still needs:
`mc.rs`, `hpc3.rs`, `ioc.rs`, `hal2.rs`, `ds1x86.rs` (Dallas RTC),
`eeprom_93c56.rs`, `rex3.rs`, `vc2.rs`, `xmap9.rs`. When the manual and your
reading of the RTL disagree, IRIS is the tiebreaker — it is validated by the
most demanding test there is.

The **MMIO golden-log diff** against it is still unbuilt and is the single
highest-leverage thing you can add for M2/M3: run the same PROM in both, diff
the traces, and the first divergence is the bug.

Keep MAME (`reference/mame/`, `~/repos/mame`) as a third opinion. Diff console
output against the real serial captures in `roms/*/*.capture.txt.gz`.

### 3. Real hardware

The user has physical SGI hardware and can run test binaries on it —
`docs/11-running-on-hardware.md` covers which machines and how. The suite is
free of emulator-specific requirements, so the same binary boots on iron and
prints the same lines.

Use it for ground truth where the manual is ambiguous and IRIS is not
authoritative. **Batch your requests**: real-hardware runs cost the user time,
so accumulate a set of questions and ask for one run, not ten. Commit any
hardware-confirmed result under `tests/hardware/` with the captured output as
the reference, which is what `cpu-tests/docs/oracle.md` §5 asks for.

## Where to pick up: M2, the memory controller

Load the PROM and watch it wedge:

```sh
make -C verilator cputest
cd verilator && ./obj_dir/Vsim_top --prom ../roms/IP24_Indy/ip24prom.070-9101-011.bin \
    --max-cycles 20000000 --stuck 3000000 --hot
```

What happens today, which is a clean starting point rather than a mystery:

- The PROM fetches from `0xBFC00000` and runs. The CPU is not the problem.
- It bit-bangs the serial EEPROM at `MC + 0x30` a couple of hundred times and
  moves on.
- Then it wedges in `DELAY()` — the hot addresses are `0x1FC00510/518/520`,
  which is the delay loop, spinning on `0x1FA01000`, **`RPSS_CTR`**.

`RPSS_CTR` is a free-running 100 ns counter and `DELAY()`/`calibrate_delay()`
busy-wait on it. `docs/02-address-map.md` predicted exactly this: *"if it
doesn't advance the PROM hangs before any output."* So M2's first task is not
the whole MC — it is a counter that counts.

After that, in order: `SYSID` (`+0x18`, the sandbox returns `0x21` for an Indy
with MC rev 1), `CPUCTRL0` (`+0x00`, the hottest MMIO address in the whole
image) and `CPUCTRL1` (`+0x08`, written `0x16` early in `realstart`), then the
93C56 EEPROM properly — `~/mistersgi/sgi_mc.v` reads back `0xFFFFFFFF` with the
real SI path commented out, and IRIS's `eeprom_93c56.rs` is the model to follow.

M3 is the first PROM banner line on the console, matched against a real serial
capture. The SCC is already there and already proven, so M3 is about getting
the PROM far enough to print, not about serial.

Two pieces of the M0 wish-list are still missing and both come into their own
the moment the question becomes "why did the PROM stop here": the
**runtime-toggleable ROM/MMIO spoof tables** and the **IRIS golden-log diff**.
Neither was needed for CPU work because the test suite is a better oracle than
a trace diff, but the PROM chase is exactly the case they were designed for.
Build them early rather than after a day of manual tracing.

Also still unwritten, and not needed before M6: the GUI harness (`verilator/sim.v`,
module `emu`) and `sgiindy.sv`'s real top level — it is still the stock MiSTer
template, so nothing has been through Quartus yet and no resource numbers exist.

## Ground rules

- **No identifying information in this repo.** No personal names, emails,
  usernames, absolute home paths, machine names, or links to personal accounts
  in any committed file or commit message. Upstream project attribution
  (MiSTer-devel, IRIS, the MiSTer N64 project, OzOnE, MAME) is correct and
  should stay.
- **The licence is GPL-3.0** because the vendored CPU is. See `NOTICE.md`.
- **Vendor VHDL, not netlists**, and keep `rtl/cpu/r4300/` diffable against
  upstream. Every local change is marked `-- SGI:`, listed in
  `rtl/cpu/r4300/UPSTREAM.md`, and provable with `tools/diff_upstream.sh`. If
  you change the vendored CPU, update that file in the same commit.
- **PROM images are committed** in `roms/`, at the repository owner's decision.
  They are SGI-copyrighted firmware not covered by this repository's licence.
  Nothing embeds them — the core loads one from SD at runtime like any MiSTer
  core's BIOS. `reference/` stays gitignored.
- Comment the *why*, not the *what*. The best asset this codebase inherited is
  its comments explaining bugs found the hard way. Address and byte-lane bugs
  are the recurring hazard in this design — there are now four recorded — so be
  paranoid about them and write down what you worked out.

## Traps already paid for

Do not rediscover these:

- **The CPU's `mem_*` byte lanes are not symmetric.** Reads want the aligned
  doubleword shifted right by the address offset; writes swap the halves when
  the access is 64-bit or lands in the upper word; byte enables are meaningless
  on a read. `rtl/cpu/r4300_bus.sv` has the full derivation with citations.
- **`cpu.vhd`'s `error_*` outputs are N64 debugging aids, not faults.** They
  flag overflow, reserved-instruction and address-error traps, all of which
  this suite raises on purpose. Treating them as fatal stops the run on its
  first deliberate trap. The harness counts them; only a wedged pipeline and a
  FIFO overflow abort.
- **The SCC's channel naming is inverted between sources.** IRIS calls the pair
  at IOC `+0x30`/`+0x34` channel B / tty1 — that is the SGI console. The DE1
  sandbox called the same window channel A / Port 1. `rtl/sgi/sgi_scc.sv`
  follows IRIS.
- **A bare-metal image that never programs WR5 gets nothing out of the SCC**,
  on this core and on real hardware alike, because the transmitter is disabled.
  That is why `cpu-tests` output arrives via the test device and why
  `tests/scc/scctest.c` exists.
- **GHDL 6.0.0 crashes** (`netlists-utils.adb:166`) on a `numeric_std`
  comparison whose operands differ in width. The generator works around the one
  instance in `cpu.vhd`; if a new one appears, that is the symptom.

Report progress as you complete each milestone, with the simulation output that
demonstrates it.
