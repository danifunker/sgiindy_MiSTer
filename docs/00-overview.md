# Overview — what `~/mistersgi` is

## Short version

`~/mistersgi` is a ~1.3 GB working sandbox for reverse-engineering the SGI Indy
(IP24) enough to boot its Boot PROM on an FPGA. It is **not** a MiSTer core: the
top level is `DE1_TOP.v`, targeting a Terasic **DE1** (Cyclone II, 8 MB SDRAM,
4 MB parallel Flash, SRAM, VGA, PS/2). It is a mix of:

1. Original RTL by "OzOnE" (the DE1 top level, the SGI peripheral register
   models, the byte-serial bus gearbox, the debug OSD).
2. Third-party CPU cores dropped in: **aoR3000** (Aleksander Osman's R3000A) and
   more recently the **MiSTer N64 project's R4300i** (`cpu.vhd`, GHDL/Yosys-
   flattened to `cpu_netlist_v2.v`).
3. A **Verilator + Dear ImGui/DX11** simulator (`sim_main_imgui.cpp`) that models
   RAM/ROM/registers in C++ and gives a bus trace, memory editor, PC-stuck
   detector, and live register spoofing.
4. A large pile of **reference material**: SGI PROM images for a dozen machines,
   SGI chip specs (MC, HPC3, IOC, REX3, VC2, XMAP9, GIO64, VDMA, VINO, Z8530),
   MAME source for `indy_indigo2`, and a full annotated disassembly of the IP24
   PROM (`indy-prom/`).

## Where it got to

Boot progress is measured by how far the PROM gets. The evidence in the repo:

- The bus, address decode, MC register file, and PROM fetch path all work well
  enough that the PROM executes past reset and into the early init calls.
- A real **Z8530 SCC** model (`z8530_scc.sv`) is wired to the console UART
  window at `0x1FBD9830`–`0x1FBD983F`, and the sim taps the SCC's TX byte grab
  to display what the PROM is printing.
- Many devices are still **stubs returning constants**: Newport graphics
  (`0xFFFFFFFF`), HAL2 audio, INT2, the WD33C93 SCSI ports, HPC3/PBUS DMA,
  and most of the Dallas DS1386 RTC/NVRAM (two hand-picked "kludge" registers
  at `+0xF8`/`+0xFC` exist purely to pass a self-test).
- A set of **ROM patch spoofs** exists to skip the SDRAM test, NOP `cache`
  instructions, NOP the self-test-fail loop, and force early returns. All are
  currently disabled by default in the sim, which suggests they were needed at
  some point and later worked around properly — but they are a good map of the
  hard parts.
- The R4300i swap-in is **recent and unfinished**: caches are tied off
  (`INSTRCACHEON`/`DATACACHEON` = 0), all three clocks (`clk1x`/`clk93`/`clk2x`)
  are tied to one clock, interrupts are tied low, and the read byte-lane
  rotation in `r4300_bus_adapter.v` is knowingly a partial fix (see its header).
  Of that list, this core has since fixed the byte lanes and turned both caches
  on; the clocks and interrupts are still as described.

## What is genuinely reusable for MiSTer

**High value, take it:**
- `indy-prom/` — the PROM disassembly, `HARDWARE.md`, `ANALYSIS.md`, the NVRAM
  checksum algorithm, and the Python tooling. This is the single most valuable
  artefact in the repo and is already written as a core-implementation reference.
- `SGI Indy Hardware Docs/` — the SGI chip specs (PDFs) and MAME's
  `indy_indigo2.cpp` / `IP22.c` / `z80scc.cpp`.
- `SGI BIOS ROM Images/` — PROMs for IP6/IP12/IP15/IP17/IP20/IP22/IP24/IP26/
  IP28/IP30/IP32, with version strings.
- `sgi_mc.v` — a working MC (memory controller) register file. Needs the DMA
  engine finished but the decode and register set are correct and match the spec.
- `z8530_scc.sv` — a proper two-clock-domain SCC with async FIFOs. Not
  SGI-specific; reusable as-is behind a MiSTer bus wrapper.
- The **address decode table** in `DE1_TOP.v` lines ~770–790 — correct and
  cross-checked against the PROM's own accesses.
- `r4300_bus_adapter.v` — if the R4300i route is kept, this is the mem_*↔bus
  bridge with its hard-won comments intact.

**Low value / leave behind:**
- Everything DE1-specific: `DE1_TOP.v`'s pinout, `PLL.v`, `sdram.v`, the Flash
  byte-serial gearbox, `SEG7_LUT*.v`, `I2C_AV_Config.v`, `AUDIO_DAC.v`,
  `keyboard.v`, the OSD/font/char RAM debug overlay, `top_sync_vg_pattern.v`.
- All Quartus build output (`DE1_TOP.*.rpt`, `.sof`, `.pof`, `.stp`), the `out/`
  Verilator output, `build/`.
- The 1 GB IDA database `ip224613 DWORD Flipped.i64` and the 112 MB
  `sgi_indy_boot.asm` — superseded by `indy-prom/out/*.asm`.
- `sgi_ioc.v` — dead code, an exact duplicate of `sgi_hd_enet.v` that is never
  instantiated.
- `sim_main_imgui.cpp` is Win32/DX11-only; the *model* inside it (memory map,
  EEPROM bit-shift model, SCC console decode) is worth porting, the shell is not.

## Licensing note before anything is committed

- aoR3000 is BSD (its `linux/` and `sim/vmips/` subdirs are GPL — don't vendor
  those).
- The MiSTer N64 `cpu.vhd` carries the N64 core's licence; check it before
  vendoring, and vendor the **VHDL sources** (`R4300_VHDL/`), never the 5 MB
  `cpu_netlist_v2.v` Yosys dump.
- SGI PROM images are copyrighted SGI firmware. They must be **user-supplied**
  at runtime from the SD card, exactly like every other MiSTer core's BIOS.
  Do not commit them to the core repo.
