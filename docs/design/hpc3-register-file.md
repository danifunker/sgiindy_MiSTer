# HPC3's register file, and what it cost to be flip-flops

Written 2026-09-17, after docs/design/scsi-sync-negotiation.md. docs/design/cache-fill-latency.md §7 listed `sgi_hpc3`'s arrays as the
next flip-flop storage in the core; this is that change, and it is the third of
the same shape (`eeprom_93c56` and `np_bt445` in build 37, docs/design/cache-fill-latency.md §2).

## 1. What was there

`rtl/sgi/sgi_hpc3.sv` is the decode in front of HPC3's register file. One
channel behind it is real - SCSI channel 0, whose registers live in
`hpc3_scsi_dma.sv` - and everything else is storage that reads back what was
written: the PBUS DMA channels' buffer and descriptor pointers, their control
groups, `gen`, and the DMA and PIO configuration of each channel.

    logic [31:0] dma_desc [0:31];      // {sub-block, word}
    logic [31:0] dma_ctrl [0:127];     // {sub-block, register 0..7}
    logic [31:0] gen      [0:7];
    logic [31:0] cfgdma   [0:7];
    logic [31:0] cfgpio   [0:15];

6,144 bits, cleared by `for` loops on reset and read combinationally twice per
bus access. Build 41's fit, by entity: **4,188 ALMs for `sgi_hpc3:u_hpc3`,
3,637 of its own** (HAL2 218 and `hpc3_scsi_dma` 334 are children) and 6,017 of
its own registers - a tenth of the device for a register file that sees a
handful of PIO accesses in a boot.

Two reads per access is what makes it expensive rather than merely large. HPC3's
registers are 32 bits at a stride of four, so a doubleword bus cycle covers the
register at +0 and the one at +4; both are decoded, and a partial write merges
its missing bytes against the current value - a third read of the same array,
which synthesis shares with the first. 192 registers behind two 32-bit muxes,
plus the reset loops' set/clear on every flip-flop, is the 3,637.

## 2. What it is now

One 256-word store, in two copies:

    0x00-0x1F  descriptor pairs   {sub-block, word}
    0x20-0x27  gen                {addr[4:3], word}
    0x28-0x2F  cfgdma             channel 0..7
    0x30-0x3F  cfgpio             channel 0..15
    0x80-0xFF  control groups     {sub-block, register 0..7}

**Two copies, because one bus cycle reads two registers.** A memory has one
read port and the cycle needs two, so both copies take every write and each
answers one half. They are 8,192 bits each, two M10Ks out of the 70 still free.

**A stored access takes a clock longer.** The clock after `sel` is spent
getting both halves out of the memories - which is also the value a partial
write merges against - and the answer goes out at the end of it. A 64-bit write
covering both registers of a pair needs the write port twice and takes one more
clock; the +4 half goes second, which is the half that wins when both map to
the same register. That is not hypothetical: `cfgdma`'s stride is 0x200 and
`cfgpio`'s 0x100, so a doubleword there covers one register twice, and the
`for` loop this replaces left the +4 half's value behind for the same reason.

The bus waits as long as it takes - `r4300_bus` holds its request in `S_BUSY`
until the answer comes - and nothing on this path has a deadline.

**What did not move.** SCSI channel 0's sub-block, HAL2's register file and the
three write-only PBUS ports still answer in the clock after `sel`. The channel's
registers are read on every disk interrupt and reading its control port clears
one; the interesting registers stay where the traffic is.

**The reset sweep** replaces the `for` loops: 256 clocks of zeros through the
write port, with a stored access that arrives while it runs remembered and
served afterwards. The blocks outside the store answer throughout.

## 3. Saying the two versions are the same

`verilator/tb_hpc3.sv` (`make -C verilator tb_hpc3`) drives the module against a
shadow of the spec's address map written in the bench: a register key per block,
the byte-enable merge, and the two-registers-per-doubleword rule. **It does not
check the acknowledge's latency** - it waits up to 64 clocks, as the CPU's bus
does - which is what lets one bench, with one stimulus, run against both
versions. `HPC3=<file>` points the target at another copy of the module.

    flip-flops (build 41):  T1..T7, 27,108 checks, 0 errors
    two M10Ks:              T1..T7, 27,108 checks, 0 errors - the same counts

SCSI channel 0's registers, HAL2's file and the two generated halves of
`intstat` are driven but not predicted: they belong to other modules, and
reading the channel's control port clears an interrupt. A write to that control
port has `ch_active` and `flush` masked out, because both take the engine away
on its own clock.

`quartus_map` on the module alone, before any fit:

| | ALMs (estimate) | registers | block memory |
|---|---:|---:|---:|
| flip-flops | 4,874 | 7,089 | 0 |
| two M10Ks | **954** | **1,191** | 16,384 bits |

with `altsyncram:st0_rtl_0` and `st1_rtl_0` in the report, their power-up zeros
as MIFs, and no "uninferred RAM" line.

Gates: `cpuonly` 728/0, the R4600 suite 2409 / 0 (250 tests), `run-scsiwr`,
`run-dma` and `run-scsi` PASS. The last is the PROM booting with a disk
attached, and it is the one that matters here: at 0xBFC03E58 the PROM walks a
one-bit pattern through `enetr.cbp` and reads each value back, which is one of
the registers that just moved into the store.

## 4. Build 42

SEED=2, `output_files/sgiindy-b42-seed2.rbf`, md5 `1dc28a9667ae14c3e3b39dd07a4cbb7f`.

| | build 41 | build 42 |
|---|---:|---:|
| logic utilization | 37,565 ALMs (90 %) | **33,770 (81 %)** |
| registers, after the fit | 46,119 | **40,193** |
| registers, after synthesis | 43,654 | **37,757** |
| RAM blocks | 483 / 553 | 485 / 553 |
| `sgi_hpc3:u_hpc3`, its own | 3,637 ALMs, 6,017 registers | **250 ALMs, 119 registers** |
| worst setup slack (HDMI PLL) | +0.237 ns | +0.250 ns |
| core clock | +1.774 ns | +2.310 ns |

3,795 ALMs off the design for two M10Ks, and the register ceiling in
`scripts/build.sh` saw it three minutes into the build: 43,654 -> 37,757, which
is the 5,900 storage bits leaving the fabric.

The inferred store is `DUAL_PORT`, 256 x 32, address registered and output
unregistered, `READ_DURING_WRITE_MODE_MIXED_PORTS = OLD_DATA` - the same rule
the Verilog has, so the hardware answers a read taken in the clock of a write
to the same index exactly as the simulation did. Nothing in the module depends
on it either way.

The device is 81 % full where docs/design/cpu-speed-tlb-icache.md's speed builds were in the mid-nineties,
which is what makes the next speed change affordable.

**On the board**: cpu-tests as the PROM 2415 / 0 (255 tests, the same as build
41), `DISKCHECK PASS`, no SCSI notice in either boot's SYSLOG, display line-cache
misses 0.

| | build 41 | build 42 |
|---|---:|---:|
| boot until quiet / X login screen | 86.4 s / 91 s | 83.1 s / 79 s |
| `dd` 10 MB raw / `ls -lR` / xterm cold | 2.60 / 6.03 / 0.69 s | 2.60 / 5.87 / 0.68 s |
| `bzip2 -9` / fork / perl | 82.5 / 3.83 / 11.3 s | 84.0 / 3.88 / 12.6 s |
| boot clocks per instruction | 1.64 | 1.64 |

A `scripts/diskstress.sh` session on build 42 - 16 synced copies of /unix,
50 MB of writes - was clean as well: no FOREIGN block, every copy identical
(docs/design/scsi-sync-negotiation.md §7).

Nothing here should have moved and nothing did: the differences are the
instruction cache's placement (the boot's fills per 1000 instructions 7.64 ->
7.28, the login's 10.35 -> 9.55) and the 11-second granularity of the X-UP poll.
The register file this change rebuilt is not on any of these paths - which is
the point, and is why it was worth 3,795 ALMs.
