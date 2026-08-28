# Simulation harness

The sandbox's most productive tool, and the reason M1 could be measured rather
than argued about.

## What exists now, in this repo

`verilator/` builds **two** harnesses over the same `sim_top` and the same C++
device models. One top level, one set of models: a GUI wrapping a different
core would drift, and then "it works in the GUI" would stop meaning anything
about what CI runs.

**Headless** — no SDL, no window, no ImGui — so CPU and SCC regressions run in
seconds and in CI:

```sh
make -C verilator cputest
./verilator/obj_dir/Vsim_top --elf .../cputest.elf --testdev
./verilator/obj_dir/Vsim_top --prom roms/IP24_Indy/ip24prom.070-9101-011.bin \
    --stuck 20000000 --hot
```

**Interactive** — SDL2 + OpenGL2 + Dear ImGui, from the MiSTer sim framework
vendored in `verilator/sim/`:

```sh
make -C verilator gui
./verilator/obj_dir/Vsim_gui --prom roms/IP24_Indy/ip24prom.070-9101-011.bin --run
```

Panels: Control (run/stop `F5`, single step `F11`, 5000-step `F6`, reset,
cycles/s, `cpu_error` counts) · **Console**, with a box to type back at the
machine · Bus trace with decoded register names · **Unclaimed addresses** ·
Hot addresses · **PROM patches** · RAM and PROM hex editors, which start
closed because they are bulky and rarely what you want while watching a boot.

This is core ImGui, **not the docking branch**, so there is no dockspace: the
panels are plain windows tiled into three columns on first use and the user's
business after that. Every one of them resizes from any edge or corner, and
the layout is remembered in an `imgui.ini` written to whatever directory the
harness was launched from (it is gitignored). The `View` menu toggles each
panel and has a **Reset layout**, which is the escape hatch when a window ends
up somewhere its resize grip cannot be reached — deleting the ini file does
the same thing.

Two things that made this look broken before and are worth not rediscovering:
`MemoryEditor::DrawWindow` clamps its window's width to its own content, so a
hex editor built with it simply refuses to widen — use `DrawContents` inside a
window of your own. And ImGui's default `ResizeGrip` colour is nearly
transparent, which on a dark theme reads as "this window cannot be resized".

The console input is a real UART transmitter on `rxdb`, not a back door into
the SCC's receive FIFO, so a keystroke only arrives if the receiver, the baud
rate generator and the RX FIFO all work. Its bit rate is not configured: it is
measured from the machine's own transmitter, so whatever the PROM programs into
WR12/13 is automatically what the harness sends at — and the box stays disabled
until the machine has printed something, because sending at a guessed rate
produces plausible wrong characters, which is far worse to debug than "not
connected yet".

That measurement is worth more care than it looks. The PROM changes the console
rate during boot — it announces "diagnostic baud rate set to 19200" before the
System Maintenance Menu — so it is re-measured per burst of output rather than
once, and a run shorter than the current bit time is taken immediately, because
it is proof the machine has sped up. `tests/uart/run.sh` is a host-side unit
test over exactly the waveforms that got this wrong, including the one-clock
low on `txdb` at reset, which used to make the first character decode as a
single `0xFF`.

| File | What it is |
|---|---|
| `verilator/sim_top.sv` | the core wired to C++-backed memory, PROM and GIO models |
| `verilator/sim_ram.v` | those models' RTL side; the storage is in C++, reached by DPI |
| `verilator/sim_devices.cpp` | memory, the IRIS test device, and the ELF loader |
| `verilator/sim_cputest.cpp` | the headless harness: options, console, bus trace, diagnostics |
| `verilator/sim_gui.cpp` | the interactive harness: the same, with panels and a keyboard |
| `verilator/sim_uart.h` | the serial decoder and transmitter both harnesses share |

Everything docs recommended porting from the sandbox is there:

- `reg_name()`, the MMIO decode table, matched by **word overlap** rather than
  containment — the bug recorded three times in the old codebase;
- a timestamped bus trace (`--trace`, `--trace-from`, `--trace-count`);
- a no-forward-progress detector (`--stuck N`) that names the address being
  hammered. It watches the **bus**, not the PC: `cpu.vhd`'s PC is only
  observable through the savestate export, which is inside a `-- synthesis
  translate_off` block and so is not in the synthesised netlist. Watching bus
  addresses finds the same failure and names the register, which the PC alone
  would not;
- `--hot`, the most-accessed addresses on exit;
- `--no-icache` / `--no-dcache`, which run with one or both primary caches off.
  They exist because a cache bug looks like a CPU bug: the fill path was
  brought up by bisecting each symptom onto one cache from the command line
  rather than by rebuilding, and the four-way table in `docs/10` is what they
  measure;
- an **unclaimed-address summary** on exit: every bus cycle no device answered,
  grouped by address with counts and first/last cycle. This is the single most
  useful diagnostic for chipset bring-up — the next thing to build is nearly
  always the address at the top of a poll loop — and it replaced a per-cycle
  stderr line that buried everything else under 122000 copies of itself;
- `--irq`, one line per change of INT2's five lines into the CPU, with the
  status and mask registers that decided them. An interrupt that never fires
  and an interrupt that fires and is ignored look identical from the console,
  and this separates them in one line: an asserted status bit against a zero
  mask is software that has not enabled the source, a clear status bit is the
  device. It is what showed that the PROM masks LOCAL0 off entirely and polls
  the SCSI chip instead, which retired a wrong diagnosis in `docs/12`;
- the SCC console tap, plus `--uart` to decode the `txdb` line independently;
- an **ELF loader** that probes both ends of every segment after writing,
  because unmapped physical space accepts writes silently.

### Still missing

- The **IRIS golden-log MMIO diff**: run the same PROM in both, diff the
  traces, and the first divergence is the bug. It has not been needed yet, and
  that is worth recording — every chipset stall through M2 was legible from the
  unclaimed-address list plus the PROM's own disassembly, which is a faster
  loop than building a differ. It earns its keep when behaviour is subtly
  wrong rather than absent.
- **MMIO** spoofing. The GUI's spoof table patches the PROM image, which covers
  the sandbox's whole list of "known-hard spots"; overriding a device register
  would need RTL support, since the devices are no longer in C++.
- The **PC** panel. `cpu.vhd`'s PC is only observable through the savestate
  export, which lives inside a `-- synthesis translate_off` block and so is not
  in the netlist GHDL lowers for Verilator. Adding an `-- SGI:` debug output
  outside that block would put it in reach.

## What the DE1 sandbox had

```sh
verilator -Iaor3000/rtl -Iaor3000/rtl/block -Iaor3000/rtl/memory \
          -Iaor3000/rtl/model -Iaor3000/rtl/pipeline \
          -Wno-UNOPTFLAT -Mdir out --cc \
          DE1_TOP.v r4300_bus_adapter.v cpu_netlist_v2.v \
          ram_wrappers.v ram_primitives.v \
          --exe sim_main.cpp
```

Two harnesses:

- `sim_main.cpp` (23 KB) — console mode, the original.
- `sim_main_imgui.cpp` (62 KB) — Dear ImGui + **DirectX 11 + Win32**. This is
  the one that was actually used (there is an `IndySim.vcxproj` and an
  `imgui.ini`).

`DE1_TOP.v` is compiled with `` `define VERILATOR ``, which swaps the real
SDRAM/Flash pins for a simple Avalon-style bus plus a byte-serial Flash port.
**All RAM/ROM/register state lives in C++** — the RTL has no memory behind
those pins in simulation.

## What the harness models

| Thing | How |
|---|---|
| BIOS ROM | 512 KB `rom_ptr[]`, fed one byte per cycle as `top->FL_DQ` / `top->FL_DQ_IN` indexed by `top->FL_ADDR`. Stored in the DWORD-flipped/byte-serial order the RTL expects |
| Main RAM | Two 32 MB banks (`bank0_ptr`, `bank1_ptr`), 32-bit words |
| MC serial EEPROM | A real 93C-series bit-shift model driven from `EEROM_CS_OUT`/`EEROM_SCK_OUT`/`EEROM_SO_OUT` → `EEROM_SI_IN`, backed by `eeprom.nv` on disk |
| SCC console | Taps the Z8530's internal TX-FIFO-pop event (`tx_byte_grab_toggle_a/b`) rather than decoding a serial waveform — there's no real bit clock, and the byte about to be shifted out is exactly what the PROM wrote |
| VGA | Captures the 1280×720 OSD/test-pattern output into `vga_ptr[]` |

## What the UI gives you

- **Bus trace** — timestamped ring buffer of every AVM transaction with
  address, data, PC, R/W, decoded register name, and the gearbox `state`.
- **Register-name decoder** (`decode_reg_name`) — ~60 entries covering the whole
  MC register file, HPC3, SCSI, ENET. Port this table; it makes traces readable.
- **Memory editors** — live hex views of ROM and both RAM banks.
- **PC-stuck detector** — flags when the PC hasn't advanced for 20 000 cycles,
  which almost always means a poll on a register that never returns what the
  PROM wants. This one feature is probably worth more than the rest combined.
- **Live spoof tables** — ROM patches and MMIO read overrides toggleable at
  runtime without re-verilating. See the table in
  [03-boot-prom.md](03-boot-prom.md).
- **SCC console pane** — what the PROM is printing.

## A real bug the harness's comments record

`apply_spoof` originally used `addr >= lo && addr <= hi`, which never matched:
AVM reads arrive **word-aligned** (low 2 bits masked) even for `lb`/`sb`
instructions — byte selection is via byte-enables, not a different bus address.
The Indigo byte poll at `0xBFB80D13` appears on the bus as `0x1FB80D10`, below
`addr_lo`, so the spoof silently never fired. It now tests overlap of
`[addr, addr+3]` against `[lo, hi]`.

The same class of bug is documented three separate times in this codebase (here,
in `MUX_ADDR`, and in `r4300_bus_adapter.v`'s byte-lane rotation). Address/byte-
lane discipline is the recurring hazard in this design.

## Recommendation for the MiSTer core

Build the equivalent, but **portable**: Verilator + a plain C++ or SDL harness
(no DX11/Win32), so it runs on macOS where the work is happening. Keep:

1. The `decode_reg_name` table.
2. The bus trace with PC.
3. The PC-stuck detector.
4. The SCC console tap.
5. The spoof tables (they're the fastest way to bisect "where does it hang").

Then add what's missing: a **golden-log diff against IRIS**
(`~/repos/iris`) — a working Rust Indy emulator that boots IRIX to a desktop,
with readable implementations of every device this core needs. Comparing the
core's MMIO trace to IRIS's for the same PROM is the single highest-leverage
debugging technique available here, and it wasn't set up in the sandbox. See
[09-cpu-validation.md](09-cpu-validation.md).

Keep MAME (`reference/mame/indy_indigo2.cpp`, `~/repos/mame`) as a third
opinion where IRIS and the manual disagree, and diff console output against the
real serial captures in `roms/*/*.capture.txt.gz`.

The harness must also be able to **load a bare ELF straight into the RAM
model**, the way IRIS's `--load-elf` does, so the `cpu-tests` suite can run with
no PROM involved. Probe both ends of each segment before committing: unmapped
physical space accepts writes silently and reads back zero, so a
mis-addressed load shows up as a CPU fetching zeros.
