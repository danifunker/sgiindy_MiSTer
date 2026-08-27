# Running the CPU test suite on real hardware

The `cpu-tests` suite in `~/repos/iris/cpu-tests/` is deliberately free of
emulator-specific requirements — the test device is *probed* rather than
assumed, and everything essential goes over the SCC — so the same binary that
runs under Verilator boots on a real SGI and prints the same lines. That makes
real hardware the top-tier oracle (`cpu-tests/docs/oracle.md` §5).

## Before anything else: which machine

**The suite is MIPS III / n32 / 64-bit. It will not run on an R3000.**

`-march=mips3 -mabi=n32` means 64-bit registers, R4x00-style CP0, and an FPU
with an R4000-family FIR. An R3000A Indigo (IP12) faults on the first 64-bit
operation. There is no R3000 cell and adding one would mean a different suite.

| Machine | CPU | Works? |
|---|---|---|
| **Indy (IP24)** | R4400 / R4600 / R5000 | ✅ the intended target |
| **Indigo2 (IP22)** | R4400 / R4600 | ✅ |
| Indigo2 (IP26/IP28) | R8000 / R10000 | ⚠️ `PRId` imp `0x10`/`0x09` — no cell; refuses to run |
| Indigo (IP20) | R4000 | ⚠️ shares imp `0x04` with R4400, told apart by revision major ≥ 4. Identified as R4400, so R4400 expectations are asserted against an R4000 |
| **Indigo (IP12)** | R3000A | ❌ wrong ISA entirely |

An unrecognised `PRId` is handled gracefully: the suite prints
`UNKNOWN CPU — refusing to run` and exits `rc=127` rather than producing
meaningless results.

## Step 1 — build the ELF

```sh
cd ~/repos/iris/cpu-tests
make            # -> build/cputest.elf
```

Needs a MIPS cross toolchain. `toolchain.mk` searches for `mips-linux-gnu-`,
`mips-unknown-linux-gnu-`, then `mips64-unknown-linux-gnu-`.

**On macOS this is the awkward step.** `make toolchain-local` will not work — it
runs `apt-get download` + `dpkg -x` and sets an `x86_64-linux-gnu` library path.
Two options:

- **Docker/Linux VM** (reliable): build in a Debian container with
  `apt-get install gcc-mips-linux-gnu binutils-mips-linux-gnu`, then copy
  `build/cputest.elf` out.
- **A native cross toolchain**: any prefix that provides `mips-unknown-linux-gnu-gcc`
  works with the existing search order, or pass `make CROSS=<prefix>-`.

The build is checked at link time: `check-size` fails the build if a `.got` or
`.dynamic` section appears, which would mean the `-mno-abicalls` contract broke
and the binary would fault the moment it ran unrelocated.

## Step 2 — get it onto the machine

Three paths, in order of how proven they are.

### A. SCSI disk — the proven path

`mkvh` writes an SGI volume header naming the ELF, which the PROM loads by
name. This is verified end to end in emulation (`run/run-prom.sh`, 784 checks).

```sh
cd ~/repos/iris && cargo build --release --bin mkvh
cd cpu-tests && make image        # -> build/cputest.img
```

That runs `mkvh build build/cputest.img --bootfile cputest cputest=build/cputest.elf`
followed by `mkvh dump` so you can eyeball the result. The layout:

```
block 0    SGI volume header — magic 0x0BE5A941, bootfile "cputest", valid checksum
           voldir[0] = cputest, lbn 8, <size> bytes
           pt[8]  = PT_VOLHDR, spanning the whole file (not 8 sectors — see below)
           pt[10] = PT_VOLUME, whole image
block 8+   the ELF
```

Note `pt[8]` spans the *entire file*, matching what the IRIX 6.5.22 install CD
does. A conventional 8-sector volume header is correct only for a header with
no files in it.

Write `cputest.img` to something the Indy can see at a spare SCSI ID:

- **BlueSCSI / SCSI2SD / ZuluSCSI** — easiest. Put the image on the SD card as a
  fixed-disk device at a free ID.
- **A real SCSI disk** — `dd` the image to it from a machine with a SCSI HBA.

Then at the Command Monitor:

```
>> boot -f dksc(0,<id>,8)cputest
```

`<id>` is the SCSI ID you attached it at, `8` is the volume-header partition.

### B. Network boot — no disk needed

The PROM supports `boot -f bootp()<file>`, and `cpu-tests/docs/memory-map.md`
confirms the suite's self-relocation makes it independent of how it was loaded:
`--load-elf`, `boot -f dksc(...)` and `boot -f bootp()` all converge on the same
layout.

IRIS implements BOOTP + TFTP in its own NAT gateway (`src/net.rs`,
`src/tftp.rs`) for the emulated case. On real hardware you supply the servers —
`dnsmasq` with `--enable-tftp --tftp-root=<dir>` on the same LAN segment is the
usual approach, serving `cputest.elf`.

```
>> setenv netaddr <the Indy's IP>
>> boot -f bootp()cputest.elf
```

This path is **not yet proven on iron** in this project, but it needs no disk
hardware at all and it exercises the PROM's network stack, which nothing else
here tests. If you have BlueSCSI already, path A is less work.

### C. CD-ROM — incomplete

`cpu-tests/PLAN.md` §12 has this as Phase 5, "partly" done. The volume-header
mechanism works and `src/scsi.rs` already does the 2048/512 block-size switching
the PROM needs to read an SGI volume header off a CD. What is missing is an EFS
writer for partition 7 (no host tool exists; `tools/mkefs` is planned at ~600
lines). Burning the volume-header-only image to a CD may work, since the voldir
holds 15 entries of ≤8-character names and needs no filesystem — but that is
untested. Not worth attempting before A or B.

## Step 3 — watch the serial console

**The suite prints over the SCC, so you must be on a serial console.** If the
machine's console is set to graphics, the output goes to the screen the suite
never touches and you will see nothing.

At the Command Monitor:

```
>> setenv console d
```

Baud comes from the `dbaud` environment variable, default **9600**, 8N1.
Check `printenv` if you are not sure. SGI Indy and Indigo2 use DIN-8 serial
connectors with a Macintosh-style pinout, so you will need a DIN-8 to DB-9 (or
USB) adapter — confirm against your specific machine before buying one.

`con_init()` is deliberately a no-op: the PROM has already programmed the baud
rate and the WR registers before handing over, so the suite only polls TX-empty
and writes.

## Step 4 — read the result

Expected output shape:

```
========================================================
 IRIS CPU test suite   cpu=R4400
   PRId   0x00000440    FIR    0x00000500
   Config 0x...          testdev no   L2 yes
========================================================
alu/addu_sign_extends ...................... PASS
...
 RESULT: 783 checks passed, 19 failed  (172 tests)
IRIS-CPUTEST-DONE rc=19
```

`testdev no` is correct and expected on real hardware. The exit code convention
(`rc=` is the failure count) has no meaning on iron — **the serial log is the
result**. Capture it.

After printing `IRIS-CPUTEST-DONE`, `testdev_exit()` spins forever by design
rather than falling off the end of the world. Power-cycle when the log stops.

## Two hardware-specific hazards

**1. The test-device probe happens before the exception handlers are installed.**
`main()` calls `testdev_probe()` and only then `exc_install()`
(`harness/testlib.c:213-215`). The probe reads `0xBF400000` — GIO64 expansion
slot 0. `harness/console.c` says plainly: *"If the slot is empty this read takes
a bus error on real hardware."* At that instant the PROM's handlers are still
the installed ones, so a bus error most likely drops you back to the Command
Monitor before a single test runs.

If that happens, it is the first thing to patch: either move `exc_install()`
ahead of `testdev_probe()`, or compile the probe out for hardware runs. Worth
knowing before you conclude the binary is broken.

**2. The tail of the last line can be lost.** `con_flush()` exists because
`scc_putc` waits for the transmit *buffer* to empty, which says nothing about
the byte already in the shift register — `IRIS-CPUTEST-DONE rc=100` once arrived
as `IRIS-CPUTEST-DONE rc=`. The flush spin should cover it, but if the final
line looks truncated, that is why, not a failing run.

## What to do with the results

Per `cpu-tests/docs/oracle.md` §5, any expectation confirmed on real hardware
should be **annotated as such in the test**. For this project:

- Commit the captured serial log under `tests/hardware/` with the machine, CPU,
  PROM version and date.
- Where hardware disagrees with IRIS, hardware wins and IRIS has a bug — report
  it upstream.
- Where hardware disagrees with the core, the core has a bug.
- Where hardware disagrees with the R4000 manual, read the manual section again
  before touching anything; that has been the right move twice already.

Batch the questions. A hardware run costs real time, so accumulate what you need
answered and do one run, not ten.
