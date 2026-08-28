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

**The machine boots. You can type at it.**

Running the real IP24 PROM under Verilator gets all the way to the Command
Monitor, over serial, driven by keystrokes the harness sends into the SCC's
receive pin:

```
                         Running power-on diagnostics...

SCSI controller 0 diagnostic              *FAILED*
	Check or replace:  CPU base board
PC keyboard/mouse controller diagnostic    *FAILED*
	Check or replace:  CPU base board

Diagnostics failed.
[Press any key to continue.]

System Maintenance Menu

1) Start System
2) Install System Software
3) Run Diagnostics
4) Recover System
5) Enter Command Monitor

Option? 5
Command Monitor.  Type "exit" to return to the menu.
>> version
PROM Monitor SGI Version 5.3 Rev B10 R4X00/R5000 IP24 Feb 12, 1996 (BE)
>> hinv
                   System: IP22
                Processor: 16 Mhz R4400, with FPU
     Primary I-cache size: 16 Kbytes
     Primary D-cache size: 16 Kbytes
              Memory size: 64 Mbytes
```

`tests/run-prom.sh` reproduces all of that and checks each line, so a change
that moves the boot backwards fails a test rather than surprising you later.
**"16 Mhz" is measured, not claimed**: the PROM times itself against the 8254,
which simulation runs ten times fast.

Against `docs/07-mister-port-plan.md`'s milestones: **M0–M3 done, M6 — the "it
boots" milestone — reached, M4 and M5 partly done.** Every failure above is a
device that genuinely is not implemented, and the PROM reports each and
continues, which is what it does for a machine with no SCSI, no keyboard and no
graphics fitted.

The CPU still passes the 240-test suite unchanged: **2155 checks passed, 9
failed**, against 2101/61 for IRIS's own R4400 on the same expectations. The
three failing tests are the two cache tests and `cvt.s.l`/`cvt.d.l`, all
diagnosed in `docs/10-r4300-integration.md`.

What is *not* done, and is worth knowing before you plan anything:

- **The GIO DMA engine is a stub.** Its registers behave and a start reports
  instant completion, but no data moves, so the PROM's boot memory clear does
  not clear anything. The PROM believes it worked.
- **The NVRAM is volatile.** The PROM rebuilds its environment on every boot.
  `setenv` will not survive a reset until the array is wired to MiSTer's SD
  save path.
- **No interrupts.** INT2 has masks and no sources.
- **No SCSI, Ethernet, keyboard or graphics.**
- **Nothing has been through Quartus.** `sgiindy.sv` is still the stock MiSTer
  template and no resource numbers exist.

## Read first

`docs/README.md` indexes everything. At minimum, in this order:

1. **`docs/12-chipset.md`** — the chipset as built, and the order in which each
   device blocked the next. Read this before touching `rtl/sgi/`.
2. **`docs/02-address-map.md`** — the register map, now corrected against the
   SGI chip specifications rather than the PROM's inventory.
3. **`docs/10-r4300-integration.md`** — the CPU as built. The byte-lane
   contract, the R4400 presentation, the bugs fixed in the vendored core.
4. `docs/09-cpu-validation.md` — the test suite and the oracle policy. This is
   the document that determines *how you work*.
5. `docs/06-simulation.md` — both harnesses, headless and interactive.
6. `docs/03-boot-prom.md` — the PROM's reset flow and the bring-up order.
7. `docs/07-mister-port-plan.md` — the milestones.

## Build and run

```sh
brew install verilator ghdl sdl2
brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu

tests/uart/run.sh         # the harness's serial decoder, no simulator, ~1 s
tests/run-scc.sh          # the Z8530, ~4 s
tests/run-cputest.sh      # 240-test MIPS suite on the core, ~35 s
tests/run-prom.sh         # boot the PROM to the Command Monitor, minutes

make -C verilator cputest # headless simulator
make -C verilator gui     # interactive simulator (SDL2 + ImGui)

verilator/obj_dir/Vsim_top --prom roms/IP24_Indy/ip24prom.070-9101-011.bin \
    --max-cycles 200000000 --stuck 20000000 --hot
verilator/obj_dir/Vsim_gui --prom roms/IP24_Indy/ip24prom.070-9101-011.bin --run
```

Two toolchain facts worth not rediscovering:

- **GHDL lowers the CPU's VHDL to Verilog for Verilator.** Quartus compiles the
  VHDL directly; Verilator cannot, so `tools/gen_r4300_verilog.sh` runs GHDL's
  synthesis backend over the same sources. No Yosys, nothing checked in — the
  output is gitignored and the Makefile regenerates it. Never reintroduce a
  checked-in netlist. **Delete `rtl/cpu/generated/r4300_wrap.v` after editing
  the VHDL**; the Makefile rule only regenerates it if it is missing.
- **macOS has no `mips-linux-gnu-gcc`**, but the `mipsel` cross GCC is
  bi-endian: `-EB -mabi=n32` produces exactly the ELF32 MSB image the tests
  want.

## Validate everything through Verilator

Every claim about the core's behaviour must be backed by a simulation run, not
by reading the RTL. This has already caught: a CDC race in the SCC's debug tap,
an inverted NaN polarity in the FPU, and — this is the one to remember — a
memory controller that looked completely broken because the *CPU* could not
form a physical address above `0x1FFFFFFF`.

The headless harness (`verilator/sim_cputest.cpp`) gives you:

| Flag | What it does |
|---|---|
| `--elf FILE` | load a bare-metal ELF and boot from its entry point, no PROM |
| `--prom FILE` | load a PROM image at `0x1FC00000` |
| `--trace`, `--trace-from`, `--trace-count` | timestamped bus trace with decoded register names |
| `--stuck N` | no-forward-progress detector — names the address being hammered |
| `--hot` | the most-accessed addresses on exit |
| `--uart` | decode the SCC's `txdb` line and compare it with the byte tap |
| `--testdev` | fit the IRIS test device in GIO64 slot 0 |
| `--console FILE` | also write the console output to a file, flushed per line |
| `--type STR` | type STR at the console once it goes quiet |
| `--type-on TRIG STR` | the same, but only after TRIG has appeared in the output |

**The unclaimed-address summary is printed on every exit and is the tool that
built the chipset.** It lists every bus cycle no device answered, grouped by
address with counts and first/last cycle; the next thing to build is nearly
always the address at the top of a poll loop.

The interactive harness (`make -C verilator gui`) drives the *same* `sim_top`
and shows the same information live, plus a console you can type into — the
input is a real UART on `rxdb`, so a keystroke only arrives if the SCC's
receiver actually works.

## The oracles, in order

### 1. The bare-metal test suite — `~/repos/iris/cpu-tests/`

240 tests, ~2200 checks, MIPS III/IV, runs on the CPU with no OS. Read
`cpu-tests/docs/oracle.md` and honour that policy. It is **not** forked into
this repo, deliberately: it is a general MIPS suite that also runs on real SGI
hardware.

The standing rule, which has already been load-bearing: **never edit an
expectation to make a test pass.** If the core is wrong, fix the core.

### 2. The chip specifications, then IRIS

`reference/specs/` holds the SGI **MC**, **HPC3**, **GIO64**, **VDMA**, **IOC**
and **Z8530** specifications as PDFs. They are gitignored and they are the top
authority — every conflict resolved in their favour during M2 turned out right,
including against the PROM's own annotated inventory, whose *names* are shifted
by a register slot in several places even though its addresses are correct.

The PDFs have no text layer that `pdftotext` will read (it is not installed
anyway), but the streams are plain Flate — a dozen lines of Python pulls the
whole register map out. Do that rather than guessing; it is how `RPSS_CTR` was
found at MC + `0x1000` after the project had spent a while looking at `0x80`.

`~/repos/iris` is a working Rust Indy emulator that boots IRIX 6.5 to a
desktop, with readable implementations of every device this core still needs:
`mc.rs`, `hpc3.rs`, `ioc.rs`, `hal2.rs`, `ds1x86.rs`, `eeprom_93c56.rs`,
`pit8254.rs`, `rex3.rs`, `vc2.rs`, `xmap9.rs`. Where the spec is silent about
what software actually expects, IRIS is the tiebreaker — it is validated by the
most demanding test there is.

`reference/prom/ip24prom-011-5.3-B10.asm` is a full annotated disassembly of
the PROM with 147 hand-written symbol names. When the PROM stalls, find the
address in there; the answer is usually three instructions away.

Keep MAME (`reference/mame/`) as a third opinion. `roms/` carries one real
serial capture, `IP22_Indigo2/ip22prom.070-8127-002.capture.txt.gz` — there is
**no IP24 capture**, so nothing this core prints has been diffed against
hardware yet. See "One thing to ask the user for" below.

### 3. Real hardware

The user has physical SGI hardware and can run test binaries on it —
`docs/11-running-on-hardware.md` covers which machines and how. **Batch your
requests**: accumulate a set of questions and ask for one run, not ten. Commit
any hardware-confirmed result under `tests/hardware/`.

## Where to pick up

In rough order of value:

1. **The instruction cache.** Every fetch is a bus round trip today, which is
   both the simulation's speed limit and a performance floor on hardware.
   `cpu_instrcache.vhd` fills from the N64's RDRAM port, tied off in
   `r4300_wrap.vhd`; pointing it at this bus is the single biggest change
   available and would make every PROM run several times faster.
2. **NVRAM persistence.** `rtl/sgi/sgi_ds1386.sv` powers up blank, so the PROM
   rebuilds its environment on every boot. Wiring the array to MiSTer's SD save
   path is the difference between a machine that remembers a `setenv` and one
   that does not.
3. **The GIO DMA engine** in the MC, for the boot memory clear. Registers exist
   and a start reports instant completion; no data moves.
4. **Interrupts.** INT2 has masks and no sources. `sgi_ioc.sv` takes
   `l0_source`/`l1_source` as inputs precisely so wiring them changes nothing
   else.
5. **SCSI and Ethernet**, if you want to boot something.
6. **Newport**, which is the rest of the machine, and `sgiindy.sv`'s real top
   level — still the stock MiSTer template, so nothing has been through Quartus
   and no resource numbers exist.

### One thing to ask the user for

**A serial capture of a real Indy booting `070-9101-011`.** `roms/` has a
capture for the IP22 but not the IP24, so the console output above has never
been diffed against hardware — the milestone plan's definition of M3 asks for
exactly that and it cannot currently be met. Batch it with whatever else you
need run on iron.

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
  you change the vendored CPU, update that file in the same commit **and rerun
  `tests/run-cputest.sh`** — that suite is the only reason to believe a change
  to the CPU is safe.
- **PROM images are committed** in `roms/`, at the repository owner's decision.
  They are SGI-copyrighted firmware not covered by this repository's licence.
  `reference/` stays gitignored.
- Comment the *why*, not the *what*. The best asset this codebase inherited is
  its comments explaining bugs found the hard way.

## Traps already paid for

Do not rediscover these:

- **Upstream assumptions that are true of an N64 and false of an SGI are not
  marked as assumptions.** `cpu_cop0.vhd` truncated every TLB translation to 29
  bits, which is invisible on a machine with 512 MB of address space and fatal
  on one that puts high local memory at `0x20000000`. It presented as "the
  memory controller does not work", three layers from the cause. There will be
  more of these; suspect the CPU when a device looks impossible.
- **The CPU's `mem_*` byte lanes are not symmetric.** Reads want the aligned
  doubleword shifted right by the address offset; writes swap the halves when
  the access is 64-bit or lands in the upper word; **byte enables are
  meaningless on a read** — use `bus_aoff` to tell which word a device register
  access actually addressed. `rtl/cpu/r4300_bus.sv` has the derivation.
- **MC registers answer at `reg + 4`, not `reg + 0`**, and that is wiring, not
  convention: the chip is on the low 32 bits of SysAD and the *odd* word
  address is the big-endian one. HPC3, IOC2 and the RTC are the opposite —
  ordinary 32-bit registers on a stride of four, both words live.
- **IOC2 and the RTC put their 8-bit registers in the LOW byte** of the word,
  the byte at `word + 3`. The PROM reads them with `lbu` at `base + 3` and
  drives the whole power-on console through byte accesses at `0xBFBD9833`.
- **`cpu.vhd`'s `error_*` outputs are N64 debugging aids, not faults.** They
  flag traps this suite raises on purpose. Only a wedged pipeline and a FIFO
  overflow abort a run.
- **The SCC's channel naming is inverted between sources.** IRIS calls the pair
  at IOC `+0x30`/`+0x34` channel B / tty1 — that is the SGI console. The DE1
  sandbox called the same window channel A / Port 1. `rtl/sgi/sgi_scc.sv`
  follows IRIS.
- **The PROM prints through WR8 on the *command* port**, not the data port:
  `pon_putc` (`0xBFC03C34`) points WR0 at register 8 and writes the character to
  `0xBFBD9833`. The datasheet allows both; a model that only pushes the TX FIFO
  on data-port writes accepts the entire boot banner and prints nothing.
- **A bare-metal image that never programs WR5 gets nothing out of the SCC**,
  on this core and on real hardware alike, because the transmitter is disabled.
- **GHDL 6.0.0 crashes** (`netlists-utils.adb:166`) on a `numeric_std`
  comparison whose operands differ in width. The generator works around the one
  instance in `cpu.vhd`; if a new one appears, that is the symptom.
- **Three clocks run fast in simulation** and are parameterised so hardware
  keeps the real value: `sclk`, `RTC_TICK_DIV` and `PIT_TICK_DIV`. See
  `docs/12-chipset.md` — `calibrate_delay` restarts forever if the 8254 is made
  *too* fast, so there is a limit to that trick.

Report progress as you complete each milestone, with the simulation output that
demonstrates it.
