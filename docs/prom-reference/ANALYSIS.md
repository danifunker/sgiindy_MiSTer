# SGI IP24 Boot PROM — Analysis

## 1. Image layout

Both images are 512 KiB and share the same coarse structure. The PROM is
mapped at physical `0x1fc00000`; the reset vector executes in kseg1
(`0xbfc00000`, uncached), and the PROM freely uses the kseg0 alias
(`0x9fc00000`) for its own data. **Ghidra's auto-generated names in `prom.map`
use both aliases interchangeably** — `FUN_9fc02904` and `FUN_bfc02904` are the
same function. The tooling here normalises everything to the kseg1 form.

| Region | 5.3 Rev B10 | 5.0 Rev B6 | Contents |
|---|---|---|---|
| Exception vectors | `0x00000`–`0x003c0` | same | 120 × (`j`, `nop`) |
| Code | `0x003c0`–`0x4a894` | `0x003c0`–`0x4b694` | ~294 KB / ~275 KB reached |
| Strings + tables | `0x4a894`–… | … | 1984 / 1969 strings, ~35 KB |
| ADPCM audio | `0x55ac0`–`0x6db34` | `0x56790`–`0x6e804` | 98 420 bytes, 3 tunes |
| More tables | … –`0x7fa00` | … | dispatch tables, device descriptors |
| Padding | 1536 bytes `0xff` | 544 bytes `0xff` | |

Recovered: **1102 functions** (5.3) / **1083** (5.0), 56.0% / 52.5% of each
image proven reachable as code by recursive descent seeded from the vector
table, the symbol map, and an `addiu $sp,$sp,-N` prologue scan.

### Exception vector table

`0x0000`–`0x03c0` is 120 eight-byte slots, each a `j` plus a `nop` delay slot.
This is the R4000 **BEV=1** boot-exception layout:

| Offset | Target (5.3) | Vector |
|---|---|---|
| `0x000` | `0xbfc003c0` `realstart` | Reset / Soft reset / NMI |
| `0x200` | `0xbfc00f20` | TLB refill |
| `0x280` | `0xbfc00f28` | XTLB refill |
| `0x300` | `0xbfc00f18` | Cache error |
| `0x380` | `0xbfc00e40` | General exception |
| all others | `0xbfc007c4` | catch-all trap |

## 2. Reset sequence

`realstart` (`0xbfc003c0`) — verified instruction by instruction:

1. `Status = 0x30410000` — CU1|CU0 enabled, **BEV=1**, DE (cache parity errors
   disabled). `Cause`, `PageMask`, `WatchLo`, `WatchHi` cleared.
2. `Config = 2` (K0 = uncached), read back, test bit 15. On the clear path it
   calls `init_rom` (`0xbfc0a810`), which touches `MC_CPUCTRL0`. *(Bit 15 of
   R4000 `Config` is the endianness bit; the branch is an endianness fork-up —
   this is the one place the reset path is inferred rather than certain.)*
3. Clear `MC_CPU_ERRSTAT` and `MC_GIO_ERRSTAT`, dummy-read `0x1fbb0000`
   (`INTSTAT`).
4. Compute a refresh/timing value from `Config` cache-size fields and write
   `MC_CPUCTRL0`; write `MC_CPUCTRL1 = 0x16`; program `MC_RPSS_CTR`.
5. Then, in order:

| Call | Function | What it does |
|---|---|---|
| `0xbfc00524` | `FUN_bfc00a3c` | HPC3 bring-up (PBUS/Ethernet/SCSI windows) |
| `0xbfc0052c` | `FUN_bfc00bd0` | **HAL2 audio reset/mute** |
| `0xbfc00534` | `FUN_bfc00dcc` | WD33C93 SCSI reset (ch0) |
| `0xbfc0053c` | `FUN_bfc00d58` | INT2 interrupt controller init |
| `0xbfc00548` | `FUN_bfc039e0` | early console |
| `0xbfc00550` | `FUN_bfc03de0` | `MC_CPU_MEMACC` / `MC_CPUCTRL0` memory timing |
| `0xbfc00558` | `FUN_bfc03eb0` | device probe: SCSI, SEEQ Ethernet, RTC |
| `0xbfc00560` | `init_memconfig` | **memory sizing + diagnostics** |
| `0xbfc005dc` | `FUN_bfc009d4` | → `szmem` |
| `0xbfc00604` | `FUN_bfc032a4` | → ADPCM tune playback |

`enterinteractivemode` (`0xbfc00624`) is the Command Monitor entry, reached
from 12 sites including the catch-all trap handler.

## 3. Memory controller and RAM

Main DRAM begins at **physical `0x08000000`** on IP22/IP24 — confirmed by the
PROM's own working area at `0xa8740000` (kseg1 of phys `0x08740000`) and its
cached alias `0x88740000`, both of which appear as symbol prefixes in
`prom.map` (`a874…`, `8874…`).

MC registers are architecturally 64 bit; the PROM accesses the low half, so
every access lands at `base + reg + 4`. `MC_CPUCTRL0+4` is the single hottest
MMIO address in the image (59 referencing instructions).

`init_memconfig` drives the SIMM banks via `MC_MEMCFG0`/`MC_MEMCFG1` and runs
data and address tests, reporting per-slot failures. 5.3 Rev B10 added a
**SIMM slot name table** at `0xbfc6e3ac` (`<SIMM S1>` … `<SIMM S12>`, stored in
two orderings) plus static-RAM designators `U1, U2, U3, U5, U6, U8, U9, U11` at
`0xbfc6e4c0` — directly useful if a core wants to emulate diagnostic output.

Failure strings name the parts: *"Check or replace: SIMM S%d"*,
*"Check/Replace static RAM U10."*, *"No usable memory found. Make sure you have
a full bank (4 SIMMs)."* 5.3 adds *"Need at least one bank of memory that is
less than or equal to 128 [MB]"*.

## 4. NVRAM and RTC — fully decoded

The device is a **Dallas DS1386-8K** at physical `0x1fbe0000`: a byte-wide part
on a 32-bit bus, so **device byte *N* is the low 8 bits of the word at
`0x1fbe0000 + N*4`**.

Read/write primitives (`FUN_bfc110b0` / `FUN_bfc11144`) both compute
`0xbfbe0100 + offset*4`, which means:

> **The PROM's "NVRAM offset 0" is device byte `0x40`.**
> Device bytes `0x00`–`0x3f` are the DS1386 RTC/control register file.

### Checksum — `FUN_bfc11050`

Covers PROM offsets `0x00`–`0xff`, skipping offset 0 (which stores the result):

```c
int8_t s = 0xa5;
for (int i = 0; i < 256; i++) {
    if (i)     s = (int8_t)(s ^ nvram[i]);
    if (i & 1) s = (int8_t)((s << 1) | (s < 0));   /* rotate left through sign */
}
return s & 0xff;
```

Any write to a non-zero offset recomputes this and stores it at offset 0
(`FUN_bfc11144` tail, `0xbfc11184`–`0xbfc111b0`).

### Validity — `cpu_is_nvvalid` (`FUN_bfc116e8`)

NVRAM is accepted only when **both** hold:

1. `nvram[0] == checksum()`
2. `(nvram[1] & 0x3f) == 8`

### Applied to a stock `nvram-default.bin`

The reference image is 8192 bytes, matching a full DS1386-8K, and is laid out as a raw
device image (one byte per device byte). Its populated range is `0x40`–`0x130`,
which lines up exactly with the PROM's 256-byte checksummed window at device
`0x40`. The tag byte is correct (`nvram[1] & 0x3f == 8`).

**The checksum is stale:** stored `0xda`, computed `0xb3`. A real PROM would
reject it and reinitialise. The likely cause is visible in the data — the
strings `init_env(` and `init_env()\r\n` sit at device `0x10d`–`0x12f`, inside
the checksummed window; they look like debug output that was written into the
image after the checksum was last computed.

`reference/prom/nvram-default-repaired.bin` is that file with the single byte corrected
(offset `0x40`, `0xda` → `0xb3`); it validates. Nothing else was changed, and
the original was not modified.

## 5. Embedded audio — three IMA ADPCM tunes

The largest unexplained region turned out to be sound. A three-way selector at
`0xbfc03154`/`0xbfc0316c`/`0xbfc03184` picks one of three (buffer, length)
pairs, where **each length word is stored immediately after its blob**:

| Tune | 5.3 offset | 5.0 offset | Bytes | Samples | Duration @ 22050 Hz |
|---|---|---|---|---|---|
| 0 | `0x55ac0` | `0x56790` | 46 075 | 92 150 | 4.18 s |
| 1 | `0x60ec0` | `0x61b90` | 37 230 | 74 460 | 3.38 s |
| 2 | `0x6a034` | `0x6ad04` | 15 100 | 30 200 | 1.37 s |

The three blobs are **byte-identical between the two PROM revisions** — only
their offsets moved.

The decoder (`FUN_bfc032cc`, 648 bytes) is copied into RAM before use and
carries two tables, which settle the format beyond doubt:

- `0xbfc55954`, 356 bytes = **89 entries** — the canonical IMA/DVI ADPCM step
  table, `7, 8, 9, 10, 11, …, 29794, 32767`. Verified equal to the standard
  table, first entry to last.
- `0xbfc55914`, 64 bytes = 16 entries — the canonical index-adjust table
  `{-1,-1,-1,-1,2,4,6,8}` twice.

The loop reads the **high nibble first** (`srl $a3, 4`) and clamps at `0x8000`.
`tools/extract_audio.py` reimplements it; decoded WAVs are in `out/audio/`.

These are the tunes played by the undocumented Command Monitor command
**`.play <tune #>`** (`sub_bfc13320`), and one of them is played from
`realstart` at boot.

### Sample rate — inferred, 22050 Hz

The PROM programs HAL2's Bresenham rate generator at exactly four sites in the
whole image. Two of them are `RELAY_C` (`0x9100`/`0x9104`, the speaker relay);
the other two set BRES2: clock-select = 1 (44.1 kHz crystal family) and
`IDR0 = 1`, `IDR1 = 0xffff`, i.e. `inc = 1`, `mod = 2` → **master / 2 =
22050 Hz**. The resulting durations (4.2 s / 3.4 s / 1.4 s) are consistent with
boot-chime-length material. This is the one number in this document derived by
reasoning about HAL2's rate formula rather than read directly, so treat it as
strong-but-not-certain; the WAVs are trivially re-rendered at another rate by
passing a different argument to `extract_audio.py`.

## 6. Command Monitor

The dispatch table at `0xbfc556d4` is 27 records of
`{ const char *name; void (*handler)(); const char *help; }`. Names beginning
with `.` are hidden from `help`.

| Command | Handler | Help text |
|---|---|---|
| `auto` | `bfc400a0` | autoboot: auto |
| `boot` | `bfc3e980` | boot [-f FILE] [-n] |
| `.checksum` | `bfc40160` | checksum RANGE |
| `date` | `bfc11ce8` | date [mmddhhmm[ccyy]] |
| `.dump` | `bfc11e88` | dump [-(b\|h\|w)] … |
| `exit` | `bfc40230` | exit |
| `.fill` | `bfc12804` | fill [-(b\|h\|w)] [-v] |
| `.g` | `bfc12a00` | get: g [-(b\|h\|w)] ADDRESS |
| `.go` | `bfc40260` | go [INITIAL_PC] |
| `help` / `.?` | `bfc4088c` | help or ? [COMMAND] |
| `init` | `bfc007ec` | initialize: init |
| `hinv` | `bfc40ac0` | inventory: hinv [-v] [-t] |
| `ls` | `bfc41770` | list files: ls DEVICE |
| `.gio` | `bfc02884` | gio info: gio |
| `passwd` | `bfc12c30` | passwd |
| `.play` | `bfc13320` | **play \<tune #\>** |
| `off` | `bfc13380` | power off machine: off |
| `printenv` | `bfc41cf0` | printenv [ENV_VAR] |
| `.p` | `bfc12b24` | put: p [-(b\|h\|w)] ADDRESS |
| `.reboot` | `bfc135a0` | reboot |
| `resetenv` | `bfc0f9e0` | resetenv |
| `resetpw` | `bfc12d64` | resetpw |
| `setenv` | `bfc41a80` | setenv ENV_VAR STRING |
| `single` | `bfc41db0` | single user: single |
| `unsetenv` | `bfc41c28` | unsetenv ENV_VAR |
| `version` | `bfc02cac` | version |

Environment variables handled by `init_env` / `_init_bootenv` / `init_consenv`
include `SystemPartition`, `OSLoadPartition`, `OSLoader`, `OSLoadFilename`,
`OSLoadOptions`, `ConsoleIn`, `ConsoleOut`, `ConsoleWarning`, `console`,
`diagmode`, `dbaud`, `rbaud`, `keybd`, `monitor`, `netaddr`, `netinsthost`,
`netinstfile`, `tapedevice`, `scsiretries`, `Verbose`.

Password handling is present, gated on a jumper: *"Warning: Password jumper has
been removed. Cannot set PROM password."* and the internal
*"PASSWD JUMPER MISSING--forced to g."*.

## 7. Other decoded tables

| Address (5.3) | Records | Contents |
|---|---|---|
| `0xbfc7b410` | 2 × 44 bytes | **SCSI controller descriptors** (see HARDWARE.md) |
| `0xbfc6e3ac` | 12 | SIMM slot names `<SIMM S1>`…`<SIMM S12>` |
| `0xbfc6e4c0` | 8 | Static-RAM chip designators `U1`…`U11` |
| `0xbfc77eb8` | 14 | Keyboard layouts: `DE FR IT DK ES de_CH SE FI GB BE NO PT JP fr_CH` |
| `0xbfc718fc` | — | Same layouts + `US`, plus `System Recovery` |
| `0xbfc6e9f4` | 12 | Month names |
| `0xbfc77ba4`… | ~40 | SCSI sense keys and ASC/ASCQ text |
| `0xbfc7ee00` | 44 | ARCS component-class names (`processor`, `cache`, `SCSI`, `display`, …) |
| `0xbfc7f490` | 22 | `errno` strings |

The ARCS class table confirms the PROM implements the **ARCS** firmware
interface (`Open`, `Read`, `Seek`, `Load`, `Invoke`, `Execute`, `GetPeer`-style
component tree, memory descriptors) — the named symbols in `prom.map` line up
with the ARCS/`libsc` standalone I/O library.

## 8. Version diff: 5.0 Rev B6 → 5.3 Rev B10

457 789 of 524 288 bytes differ: this is a full recompile, not a patch.
Filtering the string tables to meaningful text (≥ 8 chars, mostly alphabetic,
excluding the ADPCM region) gives 1111 vs 1179 strings, **75 added, 7 removed**.

What actually changed:

- **R5000 support.** The banner goes from `IP24` to `R4X00/R5000 IP24`.
- **Per-SIMM fault reporting.** The `<SIMM S1>`…`<SIMM S12>` table is new.
- **Full ARCS memory-descriptor support.** New type names `ExceptionBlock`,
  `FirmwarePermanent`, `FirmwareTemporary`, `FreeContiguous`, `FreeMemory`,
  `LoadedProgram`, `SystemParameterBlock`, `BadMemory`, plus
  `Descriptor %2d: base = 0x%08lx, pages = %04ld, type = ` and
  *"No memory descriptors available."*
- **A complete `errno` string table** (22 entries) replaces ad-hoc messages.
- **Graphics register tests parameterised.** 5.0 hardcodes the addresses in its
  messages — *"Reading XSTART Reg 0xbf0f0100"*, *"Writing XSTARTI Reg
  0xbf0f0148"*, *"Writing CONFIG Reg 0xbf0f1330"* — while 5.3 prints `0x%x`.
  Those literals are a free gift: they pin the GR2/REX register block at
  physical **`0x1f0f0000`**, with `XSTART` at `+0x100`, `XSTARTI` at `+0x148`,
  `CONFIG` at `+0x1330`.
- **Installation / System Recovery UI.** New: *"Select device for
  installation:"*, `System Recovery`, `W   E   L   C   O   M   E     T   O`,
  *"error: cannot malloc space for standalone gui"*.
- New memory constraint message about a bank ≤ 128 MB.
- Networking hardening (*"bad socket reference"*, *"could not connect to
  server"*, *"timed out"* replace 5.0's *"socket screw-up"*).

The three audio tunes are unchanged.

## 9. Graphics

The PROM's graphics support targets **GR2** (Express/Extreme) with tests named
in the strings: *"GR2: Dac test"*, *"GR2: CPU to bitplanes DMA test"*,
*"GR2: XMAP test"*, *"GR2: VC1 test"*, *"REX power on test failed."*, *"All of
the REX register r/w tests have passed."*, plus embedded microcode blobs
announced as *"IP22/GR2 PROM HQ Microcode"* and *"IP22/GR2 PROM GE Microcode"*.
Device names `SGI-GR2`, `gr2`, `AHGR2` appear in the inventory tables.

Graphics registers are reached through a base pointer held in a variable rather
than `lui`-formed constants, so they do not show up in the MMIO inventory. The
5.0 strings (above) are the reliable anchor: **REX at phys `0x1f0f0000`**.
