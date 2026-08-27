# Simulation harness

The sandbox's most productive tool, and the reason M1 could be measured rather
than argued about.

## What exists now, in this repo

`verilator/` builds a **headless** harness — no SDL, no window, no ImGui — so
CPU and SCC regressions run in seconds and in CI:

```sh
make -C verilator cputest
./verilator/obj_dir/Vsim_top --elf .../cputest.elf --testdev
```

| File | What it is |
|---|---|
| `verilator/sim_top.sv` | the core wired to C++-backed memory, PROM and GIO models |
| `verilator/sim_ram.v` | those models' RTL side; the storage is in C++, reached by DPI |
| `verilator/sim_devices.cpp` | memory, the IRIS test device, and the ELF loader |
| `verilator/sim_cputest.cpp` | the harness proper: options, console, bus trace, diagnostics |

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
- the SCC console tap, plus `--uart` to decode the `txdb` line independently;
- an **ELF loader** that probes both ends of every segment after writing,
  because unmapped physical space accepts writes silently.

The GUI harness (`sim.v`, module `emu`) is still to be written; it wraps the
same core and is not needed for anything through M6.

Two things it does *not* have yet: the runtime-toggleable ROM/MMIO spoof
tables, and the IRIS golden-log MMIO diff. Neither has been needed — the
`cpu-tests` suite is a better oracle than a trace diff for CPU work — but both
belong here before the PROM bring-up starts.

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
