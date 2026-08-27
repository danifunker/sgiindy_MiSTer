# Boot PROM — images, reset flow, NVRAM, bring-up checklist

Condensed from `~/mistersgi/indy-prom/{README,ANALYSIS,HARDWARE}.md`, which
should be read in full before implementing any of it. Everything there is
derived from the two IP24 binaries plus a Ghidra `prom.map` carrying 147
hand-written symbol names (`realstart`, `szmem`, `init_memconfig`,
`cpu_get_eaddr`, …).

## Images available

| Machine | File | Version | Size |
|---|---|---|---|
| **Indy (IP24)** | `ip24prom.070-9101-007.bin` | SGI Version 5.0 Rev B6 IP24, Sep 28 1994 | 512 KiB |
| **Indy (IP24)** | `ip24prom.070-9101-011.bin` | SGI Version 5.3 Rev B10 **R4X00/R5000** IP24, Feb 12 1996 | 512 KiB |
| **Indigo (IP12)** | `ip12prom.070-8088-xxx.bin` | SGI Version 4.0.1 Rev C LG1/GR2, Jul 9 1992 | **256 KiB** |
| 4D/35 (IP12) | `ip12prom.070-8086-002.bin` | SGI Version 4.0.1 Rev C GR1/GR2/LG1, Feb 14 1992 | 512 KiB |
| Indigo R4000 (IP20) | `ip20prom.070-8116-004.BE.bin` | SGI Version 4.0.5D Rev A IP20, Aug 19 1992 | 512 KiB |
| Indigo2 (IP22) | `ip22prom.070-8127-002.bin` | SGI Version 5.1 Rev B IP22, Sep 16 1993 (BE) | 512 KiB |

Plus IP6, IP15, IP17, IP26, IP28, IP30 (Octane), IP32 (O2) — see
[01-source-inventory.md](01-source-inventory.md).

Several directories also carry **serial captures** (`*.capture.txt.gz`) of a
real machine's boot output — invaluable as a golden reference to diff the
core's console output against.

Both IP24 images are MIPS-III big-endian, mapped at physical `0x1FC00000`
(`0xBFC00000` uncached / `0x9FC00000` cached).

## Image layout (IP24)

| Region | 5.3 Rev B10 | Contents |
|---|---|---|
| Exception vectors | `0x00000`–`0x003C0` | 120 × (`j`, `nop`) |
| Code | `0x003C0`–`0x4A894` | ~294 KB reached by recursive descent |
| Strings + tables | `0x4A894`–… | 1984 strings, ~35 KB |
| ADPCM audio | `0x55AC0`–`0x6DB34` | 98 420 bytes, 3 boot tunes |
| More tables | …–`0x7FA00` | dispatch tables, device descriptors |
| Padding | 1536 bytes `0xFF` | |

### Exception vector table — R4000 BEV=1 boot layout

| Offset | Target (5.3) | Vector |
|---|---|---|
| `0x000` | `0xBFC003C0` `realstart` | Reset / Soft reset / NMI |
| `0x200` | `0xBFC00F20` | TLB refill |
| `0x280` | `0xBFC00F28` | XTLB refill |
| `0x300` | `0xBFC00F18` | Cache error |
| `0x380` | `0xBFC00E40` | General exception |
| all others | `0xBFC007C4` | catch-all trap |

## Reset sequence — `realstart` at `0xBFC003C0`

Verified instruction by instruction:

1. `Status = 0x30410000` — CU1|CU0 enabled, **BEV=1**, DE (cache parity errors
   disabled). `Cause`, `PageMask`, `WatchLo`, `WatchHi` cleared.
2. `Config = 2` (K0 = uncached), read back, test bit 15. On the clear path,
   calls `init_rom` (`0xBFC0A810`), which touches `MC_CPUCTRL0`. *(Bit 15 of
   R4000 `Config` is the endianness bit — this branch is inferred, not certain.)*
3. Clear `MC_CPU_ERRSTAT` and `MC_GIO_ERRSTAT`; dummy-read `0x1FBB0000`
   (`INTSTAT`).
4. Compute a refresh/timing value from `Config`'s cache-size fields; write
   `MC_CPUCTRL0`; write `MC_CPUCTRL1 = 0x16`; program `MC_RPSS_CTR`.
5. Then, in order:

| Call site | Function | What it does |
|---|---|---|
| `0xBFC00524` | `FUN_bfc00a3c` | HPC3 bring-up (PBUS / Ethernet / SCSI windows) |
| `0xBFC0052C` | `FUN_bfc00bd0` | HAL2 audio reset / mute |
| `0xBFC00534` | `FUN_bfc00dcc` | WD33C93 SCSI reset (ch0) |
| `0xBFC0053C` | `FUN_bfc00d58` | INT2 interrupt controller init |
| `0xBFC00548` | `FUN_bfc039e0` | early console |
| `0xBFC00550` | `FUN_bfc03de0` | `MC_CPU_MEMACC` / `MC_CPUCTRL0` memory timing |
| `0xBFC00558` | `FUN_bfc03eb0` | device probe: SCSI, SEEQ Ethernet, RTC |
| `0xBFC00560` | `init_memconfig` | **memory sizing + diagnostics** |
| `0xBFC005DC` | `FUN_bfc009d4` | → `szmem` |
| `0xBFC00604` | `FUN_bfc032a4` | → ADPCM boot tune playback |

`enterinteractivemode` (`0xBFC00624`) is the **Command Monitor** entry, reached
from 12 sites including the catch-all trap handler. **Reaching that prompt over
the serial console is the right definition of "the core boots".**

## NVRAM — must be right, or the environment is wiped every boot

Device: Dallas **DS1386-8K** at phys `0x1FBE0000`, one device byte per 32-bit
word (stride 4, low 8 bits). The PROM's "NVRAM offset 0" is device byte `0x40`;
device bytes `0x00`–`0x3F` are the DS1386 RTC/control file.

### Checksum — `FUN_bfc11050`

Covers PROM offsets `0x00`–`0xFF`, skipping offset 0 (which stores the result):

```c
int8_t s = 0xa5;
for (int i = 0; i < 256; i++) {
    if (i)     s = (int8_t)(s ^ nvram[i]);
    if (i & 1) s = (int8_t)((s << 1) | (s < 0));   /* rotate left through sign */
}
return s & 0xff;
```

Any write to a non-zero offset recomputes this and stores it at offset 0.

### Validity — `cpu_is_nvvalid` (`FUN_bfc116e8`)

NVRAM is accepted only when **both** hold:

1. `nvram[0] == checksum()`
2. `(nvram[1] & 0x3F) == 8`

`indy-prom/tools/nvram.py` verifies and repairs images;
`indy-prom/out/nvram-default-repaired.bin` is a known-good 8 KiB device image.

Environment variables the PROM stores here: `SystemPartition`,
`OSLoadPartition`, `OSLoader`, `OSLoadFilename`, `OSLoadOptions`, `ConsoleIn`,
`ConsoleOut`, `ConsoleWarning`, `console`, `diagmode`, `dbaud`, `rbaud`,
`keybd`, `monitor`, `netaddr`, `netinsthost`, `netinstfile`, `tapedevice`,
`scsiretries`, `Verbose`.

## Command Monitor

27 commands, dispatch table at `0xBFC556D4` as
`{ const char *name; void (*handler)(); const char *help; }`. Names beginning
with `.` are hidden from `help`. Notable: `boot`, `hinv`, `ls`, `printenv`,
`setenv`, `resetenv`, `date`, `version`, `single`, `init`, `.go`, `.dump`,
`.fill`, `.play <tune #>`, `.gio`, `.reboot`, `off`.

The PROM implements the **ARCS** firmware interface (component tree, memory
descriptors, `Open`/`Read`/`Seek`/`Load`/`Invoke`/`Execute`) — this is what
IRIX's bootloader talks to.

## Embedded audio

Three IMA/DVI ADPCM tunes, byte-identical between the two IP24 revisions, only
the offsets move. Decoder at `FUN_bfc032cc` (648 bytes, copied into RAM),
with the canonical 89-entry step table at `0xBFC55954` and the 16-entry
index-adjust table at `0xBFC55914`; high nibble first, clamp at `0x8000`.
Played at ~22050 Hz (inferred from HAL2 BRES2 programming — strong but not
certain). Decoded WAVs are in `indy-prom/out/audio/`.

## Graphics anchor

The 5.0 PROM's diagnostic strings hardcode addresses that the 5.3 PROM
parameterises — a free gift that pins the GR2/REX register block:

- *"Reading XSTART Reg 0xbf0f0100"* → `XSTART` at `+0x100`
- *"Writing XSTARTI Reg 0xbf0f0148"* → `XSTARTI` at `+0x148`
- *"Writing CONFIG Reg 0xbf0f1330"* → `CONFIG` at `+0x1330`

i.e. **REX/GR2 at physical `0x1F0F0000`**. Graphics tests named in the strings:
*"GR2: Dac test"*, *"GR2: CPU to bitplanes DMA test"*, *"GR2: XMAP test"*,
*"GR2: VC1 test"*, *"REX power on test failed."*. The PROM also carries
*"IP22/GR2 PROM HQ Microcode"* and *"IP22/GR2 PROM GE Microcode"* blobs.

## Bring-up order a core must satisfy

Straight from `indy-prom/HARDWARE.md` — this is the implementation order:

1. `MC_SYSID` and `MC_CPUCTRL0/1` must read back sanely.
2. **`MC_RPSS_CTR` must advance** — `DELAY` and `calibrate_delay` busy-wait on
   it. A stuck counter hangs the PROM before any output at all.
3. `MC_MEMCFG0/1` must describe at least one full bank at phys `0x08000000`,
   and the data/address tests over it must pass.
4. The **GIO DMA engine** (`0x1FA02000`+) must complete the VDMA memory clear,
   or the PROM prints the `DMA_RUN`/`DMA_CAUSE` dump and stops.
5. INT2 `LOCAL0_STATUS` must be readable; masks must stick.
6. RTC/NVRAM must honour stride-4 byte aliasing and hold a valid checksum.
7. SCSI and Ethernet may be absent — the PROM reports failures and continues to
   the Command Monitor.
8. `HAL2_REV` bit 15 set ⇒ audio skipped entirely.

## Known-hard spots (from the sandbox's spoof list)

The sim carries these ROM patches, all currently disabled — they are a map of
where the sandbox previously got stuck:

| Address | Patch | Meaning |
|---|---|---|
| `0x1FC00560` | NOP the call | Skip the SDRAM test routine |
| `0x1FC012A8`–`0x1FC012B3` | NOP | `cache` instructions raised an exception on aoR3000 |
| `0x1FC03BF4` | NOP the call | Skip a serial routine |
| `0x1FC04080` | NOP | Skip the endless loop after a self-test failure |
| `0x1FC03C20` | force `jr $ra` (`0x03E00008`) | Early-return out of a routine |
| `0x1FB80D13` (Indigo) | read `0xFFFFFFFF` | Spoof "serial port ready" |

Getting to the point where none of these are needed is a good milestone
definition.
