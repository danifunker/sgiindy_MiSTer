# Source inventory — `~/mistersgi`

Verdict column: **KEEP** = port/vendor into the MiSTer core, **REF** = reference
only (read it, don't ship it), **DROP** = board-specific or generated.

## Top-level RTL

| File | Size | What it is | Verdict |
|---|---|---|---|
| `DE1_TOP.v` | 2072 lines | The whole SoC: address decode, byte-serial bus gearbox, peripheral stubs, CPU instantiation, debug OSD, DE1 pinout | **REF** — mine the decode tree + register models, rewrite the shell |
| `sgi_mc.v` | 19 KB | SGI **MC** memory/GIO64 arbiter controller register file — full register set, EEPROM bit-bang pins, DMA regs | **KEEP** |
| `sgi_hd_enet.v` | 1.5 KB | HPC3 SCSI0/ENET descriptor registers (4 regs). Instantiated at `DE1_TOP.v:1307` | **KEEP** (stub-level) |
| `sgi_ioc.v` | 1.5 KB | Byte-identical duplicate of `sgi_hd_enet.v`, never instantiated | **DROP** |
| `z8530_scc.sv` | 81 KB | Full Z8530 SCC: 2 channels, two clock domains, async Gray-pointer FIFOs, BRG, interrupts, soft reset | **KEEP** |
| `scc.v` | 14.5 KB | Older/simpler SCC model, superseded by `z8530_scc.sv` | **DROP** |
| `r4300_bus_adapter.v` | 9 KB | N64 R4300i `mem_*` ↔ Avalon-MM bridge. Header comments document real byte-lane bugs found the hard way | **KEEP** if R4300i route |
| `r4300_interface.v` | 7 KB | Older/unused R4300 interface experiment (tied to constant `R4300_DATA_IN`) | **DROP** |
| `ram_wrappers.v`, `ram_primitives.v` | 4.5/4.7 KB | Named wrappers so the Yosys-flattened R4300i netlist links under Verilator | **REF** (Verilator only) |
| `sdram.v`, `PLL.v`, `PLL_inst.v`, `PLL.ppf/.qip` | — | DE1 SDRAM controller + Cyclone II PLL | **DROP** (MiSTer has `sdram.v`/`ddram.v` + its own PLL) |
| `SCRATCH_RAM.v`, `STACK_RAM.v`, `char_ram.v`, `font_rom.v`, `cache_mirror.v` | — | Altera-inferred RAMs for the debug OSD | **DROP** |
| `osd.v`, `sync_vg.v`, `pattern_vg.v`, `top_sync_vg_pattern.v`, `x4enc2.v`, `quad_decoder.v` | — | 720p test-pattern generator + debug text OSD (**not** SGI video) | **DROP** |
| `AUDIO_DAC.v`, `Audio_PLL.v`, `I2C_AV_Config.v`, `I2C_Controller.v`, `SPU.v`, `keyboard.v`, `SEG7_LUT*.v`, `async_receiver.v`, `async_transmitter.v`, `source.v` | — | DE1 board glue | **DROP** |

## CPU cores

| Path | What it is | Verdict |
|---|---|---|
| `aor3000/` | Aleksander Osman's **aoR3000** R3000A core. BSD. 5-stage, 64-entry TLB, 2 KB I$ + 2 KB D$, no FPU, Avalon-MM master, ~7.7 kLE @ ~52 MHz on Cyclone IV. **Little-endian, hard-wired.** | **KEEP** (for IP12/Indigo) — but see endianness caveat in [04-cpu.md](04-cpu.md) |
| `R4300_VHDL/` | MiSTer **N64 core's R4300i** in VHDL: `cpu.vhd` (172 KB), `cpu_cop0.vhd`, `cpu_FPU.vhd`, `cpu_mul.vhd`, `cpu_instrcache.vhd`, `cpu_datacache.vhd`, `cpu_TLB_*.vhd` | **KEEP** (for IP24/Indy) |
| `R4300_VHDL_synth_scratch/` | Stub versions (`cpu_cop0_stub.vhd`, `cpu_FPU_stub.vhd`, `dpram_stub.vhd`) used while getting GHDL/Yosys synthesis to converge | **REF** |
| `cpu_netlist_v2.v` | 5.3 MB Yosys-flattened Verilog of the above. Only exists because Quartus/Verilator needed plain Verilog | **DROP** — Quartus compiles VHDL directly; feed it `R4300_VHDL/` |

## Reference material

| Path | Contents |
|---|---|
| **`indy-prom/`** | **The crown jewel.** Full annotated IP24 PROM analysis — see [03-boot-prom.md](03-boot-prom.md) |
| `indy-prom/out/` | 9.2 MB annotated disassembly per image, function inventory, per-device MMIO inventory (`hardware-011.txt`), string tables, symbol JSON, decoded boot tunes (WAV), repaired NVRAM image |
| `indy-prom/tools/` | Python (capstone): recursive-descent disassembler, IP22/IP24 hardware address DB (`hwmap.py`), NVRAM checksum verify/repair, ADPCM audio extractor |
| `indy-prom/prom.map` | Ghidra export carrying **147 hand-annotated symbol names** — this is what anchors the whole analysis |
| `SGI Indy Hardware Docs/*.pdf` | SGI chip specs: `mc.pdf` (memory controller), `hpc3.pdf`, `ioc.pdf`, `gio64.pdf`, `vdma.pdf`, `rex3.pdf` (rasteriser), `vc2.pdf`, `xmap9.pdf`, `dmux1.pdf`, `rb2.pdf`, `ro1.pdf`, `HM1S.pdf`, `vino/*.pdf` (video capture), `Z8530UM.pdf`, `t5.ver.2.0.book.pdf` (R5000/T5) |
| `SGI Indy Hardware Docs/indy_indigo2.cpp`, `IP22.c`, `sgi.cpp`, `indy_mc.c`, `z80scc.cpp` | MAME driver + device sources for the same machines — the best cross-check for register behaviour |
| `SGI BIOS ROM Images/` | PROMs: IP6 (4D/20), IP12 (Indigo R3000, 256 KiB), IP12 (4D/35), IP15, IP17 (Crimson), IP20 (Indigo R4000), IP22 (Indigo2), **IP24 (Indy) ×2**, IP26, IP28, IP30 (Octane), IP32 (O2), plus version strings, boot logos, boot tunes, and serial captures (`*.capture.txt.gz`) |
| `SGI BIOS ROM Images/sgiprom_to_bin.c`, `byteswap.c` | Utilities for converting/byte-swapping SGI PROM dumps |

## Simulation

| File | What it is | Verdict |
|---|---|---|
| `sim_main_imgui.cpp` | 62 KB Verilator + Dear ImGui + **DirectX11/Win32** harness. Bus trace, memory editors, register-name decoder, SCC console decode, 93C-series EEPROM bit-shift model, ROM/AVM spoof tables, PC-stuck detector, VGA capture | **REF** — port the model, not the shell |
| `sim_main.cpp` | 23 KB console-mode predecessor | **REF** |
| `sim_unused_crap.cpp` | Fragments (PC-stuck detector origin) | **DROP** |
| `verilate.sh` | One-line Verilator invocation | **REF** |
| `out/` | ~63 MB of generated Verilator C++ | **DROP** |
| `IndySim/IndySim.vcxproj`, `build/`, `imgui.ini` | Visual Studio project + build output | **DROP** |

## Generated / build artefacts (all DROP)

`DE1_TOP.{qpf,qsf,sof,pof,pin,cdf,done,jdi,qws}`, `DE1_TOP.*.rpt` (~4 MB of
Quartus reports), `*.stp` SignalTap files (~10 MB), `*.qip`, `*.mif`, `*.hex`,
`de1_constraints.sdc`, `DE1_TOP_assignment_defaults.qdf`, `Spf1.spf`,
`ip224613 DWORD Flipped.i64` (1.0 GB IDA DB), `sgi_indy_boot.asm` (112 MB),
`mame_debug.txt`, `mame_stdout.log`, `s-l1600.jpg`, `eeprom.nv`, `imgui.ini`.

Loose PROM copies in the repo root (`ip24prom.070-9101-011.bin`,
`ip12prom.070-8086-002.bin`, `ip224613.bin`) are duplicates of the ones under
`SGI BIOS ROM Images/`.
