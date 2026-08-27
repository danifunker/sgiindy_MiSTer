# How the existing RTL works (`DE1_TOP.v`)

2072 lines. Understanding this file is the difference between porting the
project and restarting it. Structure, top to bottom:

## 1. Ports and the `VERILATOR` shadow interface

Lines 1–225. Real DE1 pins (SDRAM, Flash, SRAM, VGA, PS/2, I2C, audio codec,
GPIO, 7-seg, LEDs, keys, switches) plus, under `` `ifdef VERILATOR ``, a large
set of debug-only ports that expose internal state to the C++ harness: the AVM
bus, the SCC strobes and register file, the R4300i `mem_*` port and adapter
state, the MC EEPROM bit-bang pins, and — notably — `FL_DQ_IN`, a plain input
that *bypasses* the real `FL_DQ` inout because Verilator's inout handling was
producing wrong readback on the BIOS fetch path.

Almost all of this disappears in a MiSTer port: the pin list becomes
`emu`'s standard interface, and the debug ports become either SignalTap taps
or a rewritten sim harness.

## 2. The byte-serial bus gearbox (the heart of it)

Lines ~280–410. A single state machine turns each Avalon-style 32-bit
transaction into **four sequential byte accesses**, because the DE1's Flash is
byte-wide.

```
state 0        idle; on avm_read/avm_write, latch address, burstcount,
               byteenable, writedata; assert avm_waitrequest
state 4,5,6,7  READ: capture DATA_READ_MUX[7:0], [15:8], [23:16], [31:24]
               into BYTE_BUFFER[], incrementing BYTE_ADDR each cycle;
               loop back to 4 while BURST_COUNT > 1
state 8        present the assembled word(s), assert avm_readdatavalid
state 16..20   WRITE: four cycles, then deassert avm_waitrequest
```

`FL_ADDR = {BYTE_ADDR[21:2], state[1:0]}` — the low two address bits come
straight from the state counter.

**Byte order:** `data_flipped` (line 728) reassembles
`{BYTE_BUFFER[3],[2],[1],[0]}`, i.e. the ROM byte at word offset 0 (big-endian
MSB) ends up in bits `[7:0]`. This converts big-endian storage into
little-endian words for aoR3000. A `data_normal` alternative is commented out
directly below, and line 741 shows a per-address-range switch between the two
was once needed. See [04-cpu.md](04-cpu.md) — this is the endianness trap.

**This whole gearbox is DE1-specific and should not survive the port.** MiSTer
has SDRAM/DDR3 with 16/64-bit wide paths; the PROM lives in DDR3 or block RAM,
loaded from SD. Replace it with a straightforward wishbone/Avalon fabric.

## 3. `MUX_ADDR` — a subtle bug fix worth preserving as a lesson

Lines 745–790. Every chip-select is decoded from `MUX_ADDR`, not raw
`BYTE_ADDR`. The comment block explains why at length: `BYTE_ADDR` is a
registered copy of the *previous* transaction's address during the cycle when
a new transaction's decode is needed, so `_CS` wires derived from it decoded
the wrong device. This was found and fixed narrowly for the SCC first, then
generalised. Any rewrite must get this right structurally rather than
rediscovering it.

The decode table itself (lines 770–790) is correct and cross-checked against
the PROM's own MMIO inventory — see [02-address-map.md](02-address-map.md).
`GPIO_0[16:0]` mirrors every `_CS` wire out to a logic analyser header.

## 4. `DATA_READ_MUX` — the read-side priority mux

Lines 1023–1105. A long ternary chain. Order matters: `scc_mux_sel` is checked
**before** any `BYTE_ADDR`-derived `_CS`, for the same stale-address reason.

What it returns per region:

| Region | Returns |
|---|---|
| SCC windows | real Z8530 output |
| `BANK1`/`MAINRAM`/`MAINRAM2`/`PBUSDMA` | `DRAM_DATA_IN` (i.e. C++ RAM model in sim) |
| `NEWPORT` | `0xFFFFFFFF` |
| `HAL2` | `0xFFFFFFFF` |
| `SYSID` | `0x00000021` (Indy, MC rev 1; `0x20` and Indigo's `0x11` are commented alternatives) |
| `MC` | `sgi_mc.v` output |
| `HD_ENET` | `sgi_hd_enet.v` output |
| `SCRATCH` | `0xFFFFFFFF` |
| INT2, PBUS4, HD0, GENCON, RESET_REG, DALLAS `+0xF8`/`+0xFC` | loopback registers |
| `BIOS` | the Flash byte, replicated across all four lanes |
| anything else | `0x00000000` |

The commented-out "FUDGE" lines here are the historical ROM patches, now moved
into the sim's spoof tables — see [03-boot-prom.md](03-boot-prom.md).

## 5. Peripheral models

**Real models:**
- `sgi_mc.v` — the MC register file. Reads are a big combinational ternary
  chain over `READ_ADDR_LOW[15:0]`; writes are gated on `MC_WR` (`state==18`).
  Note the register set is complete and correct, but most registers are pure
  storage — `RPSSCounter` in particular must be a genuinely free-running
  counter or the PROM hangs (see the bring-up checklist).
- `z8530_scc.sv` — a proper SCC: two channels, `clk` (bus) and `sclk` (serial,
  intended 3.6864 MHz), async Gray-pointer TX/RX FIFOs, BRG, interrupt vectors,
  optional soft reset. Parameterised (`SOFT_RESET_EN`, `RR8_CTRL_POP`,
  `BRG_SRC_A/B`, plus a Lisa-Uniplus BRG workaround — it came from a Mac/Lisa
  project). Wired here to `0x1FBD9830`–`0x1FBD983F` with `scc_a_b` from
  `avm_address[3]` and `scc_d_c` from `avm_address[2]`.
- `sgi_hd_enet.v` — four HPC3 SCSI/ENET descriptor registers, storage only.

**Loopback stubs** (write-then-read-back, no behaviour): INT2 (all 7 registers),
PBUS4 (6), HD0 SCSI (2), GENCON, RESET_REG, two Dallas kludge registers.

**Constant stubs:** Newport, HAL2, SCRATCH/INTSTAT.

## 6. Debug OSD

Lines ~1749–1890. `top_sync_vg_pattern.v` generates 720p timing and a test
pattern; `osd.v` + `char_ram.v` + `font_rom.v` composite a text overlay showing
PC, decoded mnemonic, and registers; PS/2 keyboard drives a breakpoint UI
(`SW[9] && BP_MATCHED`). VGA output is this OSD, **not** SGI framebuffer output
— there is no Newport model.

The R4300i swap left this partly stranded: `rf_cmd` (the decoded-instruction
name) has no R4300i equivalent and is tied to `CMD_null`, and `data_out` is a
best-effort stand-in (`r4300_dbg_mem_address`).

On MiSTer this whole thing is replaced by the framework's own OSD, or by
`ascal`/`video_mixer` once real graphics exist.

## 7. Clocking and reset

```
`ifdef VERILATOR : SYS_CLK = CLOCK_50 (SDRAM controller bypassed entirely)
`else            : PLL(27 MHz) -> DRAM_CONT_CLK; SYS_CLK = DRAM_CONT_CLK / 8
                   (SYS_CLK must be 1/8 of DRAM_CONT_CLK for the SDRAM module)
```

Reset is a 21-bit down-counter (`0x2FFFFF` on hardware, `0x10` in sim) gated on
PLL lock, producing `SDRAM_INIT`, which in turn produces `r4300_reset_pulse`.

The `/8` ratio is purely an artefact of the DE1 SDRAM controller and goes away
on MiSTer.

## What to carry across, concretely

| Take | Leave |
|---|---|
| The `_CS` decode table (lines 770–790) | The byte-serial gearbox and `FL_*` path |
| The `MUX_ADDR`-vs-`BYTE_ADDR` lesson | `data_flipped` (re-derive byte order from first principles) |
| `sgi_mc.v` (finish the DMA engine and RPSS counter) | The OSD / test-pattern video chain |
| `z8530_scc.sv` | DE1 pinout, PLL, SDRAM controller, 7-seg, codec |
| `sgi_hd_enet.v` as a starting stub | `sgi_ioc.v` (dead duplicate), `scc.v`, `r4300_interface.v` |
| The read-mux priority ordering rationale | The FUDGE comments (they live in the sim now) |
