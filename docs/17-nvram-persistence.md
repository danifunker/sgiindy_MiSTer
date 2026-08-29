# NVRAM persistence — where the environment lives, and how to keep it

The machine forgets everything on reset. `setenv` works, `printenv` reads it
back, and the next boot prints

```
NVRAM checksum is incorrect: reinitializing.
```

and starts over. That one line is the difference between a machine that can be
configured and one that cannot, and it is the last thing between this core and
an unattended boot: `setenv SystemPartition`, `setenv OSLoadPartition`,
`setenv netaddr`, the console selection and the monitor type all live in the
store that is being thrown away.

This is the plan for keeping it, written before the build so that the build can
be checked against it.

## Which store, and how that was settled

**Not by reading.** SGI machines have more than one non-volatile store, and the
obvious documentation is about the wrong one.

`~/repos/iris` persists **two** files, each loaded at startup if it exists and
written back only on an explicit command — there is no save on exit:

| IRIS file | chip | what its own comments say it holds |
|---|---|---|
| `nvram.bin` | `Ds1x86` — the DS1386 RTC | the RTC's 8 KB of NVRAM |
| `nveeprom.bin` | a 93CS56 at **`0x1FBB0008`**, on the HPC3 side | "env vars + MAC @ words 0x7D-0x7F" |

and its MC-side 93C56 — the R4000 configuration EEPROM, which is the one *this*
core models in `rtl/sgi/eeprom_93c56.sv` — has no persistence at all.

Taken at face value that says the environment is in the HPC3-side EEPROM. It
is not, on an IP24. `iris/src/config.rs` calls that file the "Indigo2
motherboard EEPROM", and the measurement agrees with the file name rather than
with the comment. Booting to the Command Monitor and typing
`setenv zork frobozz` with both candidate addresses watched:

```
  1fbe0100  62 hits      <- the DS1386's NVRAM
  1fbb0008   0 hits      <- the HPC3-side 93CS56
```

**So on this machine the environment is the DS1386's NVRAM and nothing else.**
That also agrees with the PROM's own primitives: `nvram_read` and `nvram_write`
(`0xBFC110B0` / `0xBFC11144`) both compute `0xBFBE0100 + off*4`.

The HPC3-side EEPROM is still worth building eventually — it is where the
Ethernet MAC address lives, and the SEEQ 8003 will want one — but it is not
this work, and `sgi_hpc3.sv` currently answers `0x1FBB0004`/`0x1FBB0008` as
plain storage.

## What has to be preserved

`rtl/sgi/sgi_ds1386.sv` models a Dallas DS1386-8K: 8192 device bytes, of which
`0x00`–`0x3F` are the clock and its control registers and `0x40`–`0x1FFF` are
the NVRAM proper. It sits in HPC3's battery-backed-RAM window at `0x1FBE0000`
with **one device byte per 32-bit word**, so 8 KB of device occupies 32 KB of
address space.

**Persist all 8192 bytes, not just the NVRAM part.** The clock registers are
regenerated from the host clock at power-on and the alarm and control bytes are
software's, but the whole array is one image, a save file of 8 KB is nothing,
and a partial image is a format that has to be explained to whatever reads it
next. The load path overwrites the clock half immediately (see below), so
carrying it costs nothing and keeps the file a plain memory dump.

`reference/prom/nvram-default-repaired.bin` is exactly 8192 bytes and is a
valid, checksummed environment. It is gitignored with the rest of `reference/`,
but it is the obvious thing to seed a fresh save file from, and a boot from it
should print no checksum complaint at all — which is the sharpest possible test
that the load path works.

## THE CONSTRAINT THAT DECIDES THE DESIGN

The NVRAM is **two banks with exactly one reader and one writer each**, and
that is not an accident:

```systemverilog
logic [7:0] nv0 [0:4095];        // device bytes whose index bit 0 is 0
logic [7:0] nv1 [0:4095];        // ...and whose index bit 0 is 1
```

It used to be one `logic [7:0] nv [0:8191]`. That array had four ports —
`dev_rd(0)` and `dev_rd(1)` each read it and the unrolled write loop wrote it
twice — a memory block has two, so Quartus could not infer one and built all
65,536 bits out of flip-flops: **65,713 registers and 30,430 ALUTs, more logic
than the entire R4300i**, and on its own most of what made the design miss the
device. `syn/README.md` has the whole story. Worse, Quartus said *nothing*: no
"uninferred RAM logic" message, no warning, just the registers.

**So a load/save path must not add a port.** It has to share the two the bus
already uses, muxed in front of them, which is free: the save side reads one
byte per clock and the load side writes one per clock, and neither happens
while the guest is touching the device.

That is the single most important sentence in this document. A port added
carelessly here costs more logic than the CPU, and the tool will not tell you.

## The shape

```
      MiSTer                      sgi_indy                 sgi_ds1386
   ┌───────────┐              ┌──────────────┐          ┌──────────────┐
   │  hps_io   │  sd_lba      │              │ nv_sel   │  ┌────────┐  │
   │  virtual  │  sd_rd/wr    │  nvram_*     │ nv_we    │  │ nv0    │  │
   │  drive N  ├─────────────►│  passthrough ├─────────►│  │ nv1    │  │
   │           │  sd_buff_*   │              │ nv_addr  │  └────────┘  │
   └───────────┘              └──────────────┘ nv_din      one reader, │
                                               nv_dout     one writer  │
```

### The device port

Five signals on `sgi_ds1386`, and one rule:

| signal | direction | meaning |
|---|---|---|
| `nv_sel` | in | this cycle belongs to the save/load path, not the bus |
| `nv_we` | in | write `nv_din` at `nv_addr`, else present `nv_dout` |
| `nv_addr[12:0]` | in | device byte index, 0..8191 |
| `nv_din[7:0]` | in | |
| `nv_dout[7:0]` | out | registered, one cycle after `nv_addr`, like the bus read |

`nv_sel` wins the array's ports for that cycle. The bus side is not stalled
and does not need to be: the guest is in reset while an image loads, and a save
is a read, which cannot corrupt anything it races.

**`nv_addr` is a device byte index, not an address.** `dev_idx = {addr[14:3],
w}` on the bus side, so bank `w` is selected by `nv_addr[0]` and indexed by
`nv_addr[12:1]`. Writing the file out as a flat 0..8191 byte array and letting
the port do the de-interleave keeps the save file readable with `xxd` and
independent of that optimisation ever changing.

### The clock is not restored

Loading an image writes the clock registers too, and then the power-on
initialisation overwrites them from `POR_YEAR`/`POR_MONTH`/… as it does today.
That is deliberate. A DS1386 keeps time on a battery; this one does not, and a
restored clock would be wrong by however long the machine was off — which is a
worse lie than a fixed date, because software cannot tell it is stale. When the
top level can read the HPS clock, the right fix is to seed the clock from
*that* at load time, and the NVRAM image stays what it is.

## Three places it has to be wired

### 1. The harness — first, because it is the only thing testable today

`--nvram FILE` on `verilator/sim_cputest.cpp`:

* at reset, if the file exists, walk 8192 bytes into the device port before
  releasing the CPU;
* at exit, walk 8192 bytes out and write the file back.

No new DPI is needed — the port is 8 bits wide and the harness already drives
the model cycle by cycle.

This is the whole feature, minus hardware, and it makes the ratchet below
possible without a DE10-Nano.

### 2. MiSTer — a virtual drive, the way every other core does it

`hps_io` already gives this core seven virtual drives for SCSI images. NVRAM is
one more slot:

* `CONF_STR` gains an `S` entry for the NVRAM file;
* `img_mounted` on that slot triggers a load — 16 blocks of 512 bytes through
  `sd_lba`/`sd_rd`/`sd_buff_*`;
* a save is `bk_save`, which `N64.sv` derives as
  `status[41] | (OSD_STATUS & ~OSD_STATUS_1 & ~status[42])` — an explicit menu
  item *or* the OSD closing. Both, here: closing the OSD is what a user will
  actually do, and an explicit "Save NVRAM" is what a user will look for.

8 KB is sixteen 512-byte blocks. There is no reason to make it incremental.

### 3. `sgi_indy.sv` — a passthrough and nothing else

The block/byte conversion belongs in the top level with the rest of the MiSTer
plumbing, not in the chipset. `sgi_indy` forwards five wires.

## Definition of done

A test, `tests/run-nvram.sh`, in two halves:

1. **It remembers.** Boot with `--nvram out/nv.bin` on a file that does not
   exist, reach the Command Monitor, `setenv zork frobozz`, exit. Boot again
   with the same file and `printenv zork` must print `frobozz`.
2. **It knows it remembered.** The second boot must **not** print
   `NVRAM checksum is incorrect: reinitializing.` — which is a stronger check
   than the first, because it is the PROM's own opinion of the image rather
   than ours, and it fails if a single byte of the checksummed region is wrong.

Both halves are needed. The first passes if the image round-trips; the second
passes only if it round-trips *and* the PROM agrees the result is a valid
environment, which is what catches a de-interleave error that happens to be
self-consistent.

A third case is worth having once the first two pass: seed the file from
`reference/prom/nvram-default-repaired.bin` and assert a clean boot with no
checksum complaint on the *first* boot. That one cannot be committed as-is —
`reference/` is gitignored — so it belongs as an optional path the script
skips when the file is absent, the way `tests/run-cdrom.sh` builds its own
fixture.

## What this does not cover

* **The HPC3-side 93CS56 at `0x1FBB0008`**, which on an Indigo2 holds the
  environment and on any of them holds the Ethernet MAC. It is plain storage in
  `sgi_hpc3.sv` today and nothing reads it. Ethernet will need it.
* **The MC-side R4000 configuration EEPROM.** `eeprom_93c56.sv` is a real model
  of the part and the PROM reads and writes it, but IRIS does not persist it
  either and nothing has been shown to care what it contains across a boot.
* **Restoring the clock**, for the reason above.
