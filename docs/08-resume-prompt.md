# Resume prompt

Paste this as the opening message of a fresh session. Everything below the line
is the prompt.

---

You are continuing work on an **SGI Indy (IP24)** core for MiSTer FPGA. The repo
is `~/repos/sgiindy_MiSTer`. **Work autonomously**: make the routine calls
yourself, keep going through obstacles, and only stop to ask when a decision
genuinely changes what gets built (or when you need something run on real
hardware — see below).

## Read first

`docs/README.md` indexes the whole knowledge base. At minimum read, in order:

1. `docs/00-overview.md` — where this came from and what is reusable
2. **`docs/09-cpu-validation.md`** — the CPU test suite and the oracle strategy.
   This is the document that determines how you work.
3. `docs/04-cpu.md` — the CPU decision and its open questions
4. `docs/03-boot-prom.md` — the PROM's reset flow and the 8-step bring-up order
5. `docs/02-address-map.md` — the register map
6. `docs/07-mister-port-plan.md` — the milestones you are executing
7. `docs/prom-reference/HARDWARE.md` — the authoritative per-device reference

`docs/05-existing-rtl.md` explains the prior DE1 sandbox at `~/mistersgi`; read
it before copying anything out of there, because several of its constructs are
workarounds for DE1 hardware that must not be carried forward — `data_flipped`
above all.

## Target: Indy (IP24) with the N64 R4300i

Build the **SGI Indy / IP24** using the MiSTer N64 project's R4300i core
(`~/mistersgi/R4300_VHDL/`). Vendor the **VHDL** — Quartus compiles it directly.
Never vendor `cpu_netlist_v2.v`, the 5 MB Yosys flatten; regenerate it by script
if Verilator needs it.

Keep the CPU behind a clean wrapper in `rtl/cpu/` with a documented bus
contract. An aoR3000/Indigo fallback is documented in `docs/04-cpu.md` in case
the R4300i plus Newport does not fit the DE10-Nano.

Endianness is **already settled**: `cpu_cop0.vhd:582` sets
`COP0_16_CONFIG_bigEndian <= '1'` at reset, so the R4300i is natively
big-endian, which is what SGI needs. Do not carry the sandbox's `data_flipped`
byte reversal forward — it exists only to feed the little-endian aoR3000.

## Validation strategy — this is the important part

There is a working SGI Indy emulator at `~/repos/iris` (**IRIS**, Rust, boots
IRIX 6.5 to a desktop with Newport graphics). Use it two ways:

### 1. The bare-metal CPU test suite

`~/repos/iris/cpu-tests/` is a 240-test / ~800-check MIPS III/IV suite that runs
on the CPU with no OS and reports PASS/FAIL over the SCC. It needs **only** RAM
at physical `0x08000000` and SCC TX at `0x1FBD9830`/`0x34` — no PROM, no MC, no
chipset. So it runs on the core under Verilator long before the PROM can, and it
is your **first CPU milestone**, not the PROM.

Its expectations come from the R4000 manual, not from golden recordings, and it
deliberately *reports* rather than asserts where the architecture is silent —
read `cpu-tests/docs/oracle.md` and honour that policy.

**The R4300i is not an R4400** — so it was made to present as one, because an
Indy never shipped with an R4300 and software infers the TLB entry count from
`PRId`. See `docs/10-r4300-integration.md`. The suite's `CPU_R4300` cell is
still there and still tested, for the build that reports the underlying part
honestly.

Then, for each divergence, **decide deliberately and write the decision down**:
fix the core where the PROM or IRIX depends on the behaviour (the `Config`
cache-geometry fields are the clearest case — `realstart` derives refresh timing
from them), accept it where nothing does. **Never edit an expectation to make a
test pass.** If the core is wrong, fix the core; if a test genuinely doesn't
apply to an R4300, branch it on CPU kind.

### 2. IRIS as the behavioural oracle for everything else

IRIS has readable Rust implementations of every device this core needs:
`mc.rs`, `hpc3.rs`, `ioc.rs`, `hal2.rs`, `ds1x86.rs` (Dallas RTC),
`eeprom_93c56.rs`, `rex3.rs` (rasteriser), `vc2.rs`, `xmap9.rs`, `mips_tlb.rs`,
`mips_cache_v2.rs`. Set up an **MMIO golden-log diff** against it: run the same
PROM in both, diff the traces, and the first divergence is the bug. This is the
highest-leverage debugging technique available and the prior sandbox never had
it.

Keep MAME (`reference/mame/`, `~/repos/mame`) as a third opinion where IRIS and
the manual disagree. Diff console output against the real serial captures in
`roms/*/*.capture.txt.gz`.

### 3. Real hardware

The user has physical SGI hardware and can run test binaries on it. The
`cpu-tests` suite is deliberately free of IRIS-specific requirements — the test
device is probed rather than assumed and everything essential goes over the SCC
— so **the same binary boots on a real machine and prints the same lines**.

Use this for ground truth where the manual is ambiguous and IRIS is not
authoritative. Batch your requests: real-hardware runs cost the user time, so
accumulate a set of questions and ask for one run, not ten. Commit any
hardware-confirmed result under `tests/hardware/` with the captured output as
the reference, and annotate the corresponding test as hardware-confirmed, which
is what `cpu-tests/docs/oracle.md` §5 asks for.

## Validate everything through Verilator

Every claim about the core's behaviour must be backed by a simulation run, not
by reading the RTL. The harness lives in `verilator/`, already scaffolded with
the standard MiSTer sim framework (SDL2 + OpenGL2 + Dear ImGui, plus `sim_bus` /
`sim_console` / `sim_video` / `sim_input` / `sim_audio` / `sim_serial` /
`sim_blkdevice` / `sim_clock`), a `Makefile` and `verilate.sh`. It builds on
macOS with `brew install verilator sdl2`.

**You must author `verilator/sim.v`, `verilator/sim_ram.v` and
`verilator/sim_main.cpp`** — they do not exist yet. `sim.v` is a `module emu`
wrapper instantiating the core the way `sgiindy.sv` will on hardware, with
`sim_ram.v` in place of SDRAM. Model the prior sandbox's harness
(`~/mistersgi/sim_main_imgui.cpp`) for *content*, not structure — it is
Win32/DX11-only and cannot build here.

Port these, they earned their keep (see `docs/06-simulation.md`):

- the `decode_reg_name` MMIO table (~60 entries) so bus traces are readable
- a timestamped bus trace with the CPU PC on every transaction
- the **PC-stuck detector** (flag when PC hasn't advanced for ~20 000 cycles) —
  this is what finds "the PROM is polling a register that never returns what it
  wants"
- the SCC console tap (grab the TX byte at the FIFO-pop event; do not try to
  decode a serial waveform)
- the runtime-toggleable ROM/MMIO spoof tables, matched by **word overlap**, not
  `addr >= lo && addr <= hi` — bus reads arrive word-aligned even for byte loads

Add an **ELF loader** into the RAM model, the way IRIS's `--load-elf` does, so
`cpu-tests` can run with no PROM. Probe both ends of each segment before
committing: unmapped physical space accepts writes silently and reads back zero,
so a mis-addressed load shows up as a CPU fetching zeros.

Mind the physical map (`cpu-tests/docs/memory-map.md`): RAM starts at
`0x08000000`, the bottom 512 KB is an **alias** of `0x08000000..0x0807ffff`, and
everything from `0x00080000` to `0x08000000` is unmapped. The suite links at
KSEG0 `0x88200000` for exactly this reason.

## Milestones

Work `docs/07-mister-port-plan.md` M0 → M6 in order. Each is defined by an
observable, not by "component X is written":

- **M0** harness runs, ELF loader works, traces, IRIS diff working
- **M1** **CPU passes the `cpu-tests` suite**, matching IRIS except for the
  enumerated R4300-vs-R4400 divergences
- **M2** MC good enough to survive `realstart` (free-running `RPSS_CTR` is the
  trap; `Config` cache-geometry fields are the other one)
- **M3** first PROM banner line on the serial console, matching a real capture
- **M4** memory sizing + GIO DMA memory clear complete
- **M5** NVRAM with correct checksum and validity tag, persisted to SD
- **M6** **interactive Command Monitor prompt** — `hinv` and `help` respond

M6 is "it boots" and needs **no graphics work at all**. Do not start Newport
(M7) or SCSI/IRIX (M8) before M6 is solid — though note that when you get there,
IRIS's `rex3.rs` / `vc2.rs` / `xmap9.rs` are a complete working reference.

## Ground rules

- **No identifying information in this repo.** No personal names, emails,
  usernames, absolute home paths, machine names, or links to personal accounts
  in any committed file or commit message. Upstream project attribution
  (MiSTer-devel, IRIS, aoR3000, the MiSTer N64 project, OzOnE, MAME) is correct
  and should stay.
- **PROM images are in `roms/`** at the repository owner's decision, and are
  SGI-copyrighted firmware not covered by this repository's licence (see
  `NOTICE.md`). Nothing embeds them: the core loads a PROM from SD at runtime
  like every other MiSTer core's BIOS. `reference/` is still gitignored.
- **Vendor VHDL, not netlists.**
- Check licences before vendoring anything: aoR3000 is BSD but its `linux/` and
  `sim/vmips/` subdirectories are GPL. Check the N64 `cpu.vhd` licence and
  IRIS's licence before copying code from either.
- Match the surrounding code's style. Comment the *why* — the prior sandbox's
  best asset is its comments explaining bugs found the hard way, and three
  separate address/byte-lane bugs are recorded there. That class of bug is the
  recurring hazard in this design; be paranoid about it.

## What already works — M0 and M1 are done

Read [`docs/10-r4300-integration.md`](10-r4300-integration.md) first; it is the
record of how, and it is where the byte-lane contract lives.

- **The CPU runs.** The R4300i is vendored as VHDL in `rtl/cpu/r4300/`, lowered
  to Verilog for Verilator by `tools/gen_r4300_verilog.sh` (GHDL's synthesis
  backend — no Yosys, no checked-in netlist), wrapped by
  `rtl/cpu/r4300_wrap.vhd`, and bridged to the SGI bus by
  `rtl/cpu/r4300_bus.sv`.
- **It presents as an R4400**, which is what an Indy has. That is not just
  `PRId`: nothing reports the TLB entry count architecturally, so software
  infers it from the CPU identity, and the TLB was widened from 32 to 48
  entries to make the claim true. Cache geometry, COP2 and the MIPS IV traps
  moved with it. `PRESENT_AS_R4400` in `cpu_cop0.vhd` is the switch, and both
  settings are tested.
- **It is measured.** `tests/run-cputest.sh` runs the 240-test suite on it:
  2155 checks passed / 9 failed against R4400 expectations, versus 2101 / 61
  for IRIS's own R4400. Three tests fail, all diagnosed. Eight bugs in the
  vendored CPU were found and fixed; `rtl/cpu/r4300/UPSTREAM.md` lists them and
  `tools/diff_upstream.sh` proves the list complete.
- **The SCC transmits.** `rtl/sgi/z8530_scc.sv` behind `rtl/sgi/sgi_scc.sv`,
  proved by `tests/run-scc.sh` — a bare-metal image that programs the part the
  way the PROM does, checked both at the byte tap and by decoding the `txdb`
  waveform.
- **The harness exists.** `verilator/` builds a headless simulator with an ELF
  loader, bus trace, register-name decode, no-forward-progress detector and
  console tap. The GUI harness (`sim.v`, module `emu`) is still unwritten and
  is not needed before M6.
- `roms/` and `reference/` are populated as before; `tools/prom/` still needs
  `capstone`.

## Where to pick up

**M2 — the MC, enough to survive `realstart`.** `SYSID`, `CPUCTRL0/1`
readback, and a genuinely free-running `RPSS_CTR`. `~/mistersgi/sgi_mc.v` has a
working register file to start from. Note that one worry M2 carried has
evaporated: `Config`'s cache-geometry fields are driven, and now report R4400
geometry, so `realstart` will not derive nonsense refresh timing from them.

Then M3: load a PROM image with `--prom`, boot from `0xBFC00000` (the harness
already does this — `boot_pc` defaults to it), and chase the first banner line
with `--trace` and `--stuck`.

Two pieces of the M0 wish-list are still missing and should be built before the
PROM chase gets hard: the **runtime-toggleable ROM/MMIO spoof tables**, and the
**IRIS golden-log MMIO diff**. Neither was needed for CPU work, because the
test suite is a better oracle than a trace diff; both come into their own the
moment the question becomes "why did the PROM stop here".

Report progress as you complete each milestone, with the simulation output that
demonstrates it.
