# Work item: diff IRIX's initialisation against IRIS, instruction by instruction

Paste everything below the line as the opening message of a fresh session. This
is a **separate work item** from [08-resume-prompt.md](08-resume-prompt.md) and
it is deliberately narrow: it is analysis, not RTL. Do not change `rtl/` to
"try something" while doing it.

---

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA, at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly - do not create branches in this repository.** The reference emulator
IRIS is the sibling checkout `C:\Temp\mistercore\iris`; **in IRIS, DO create a
branch for this work.**

## The job

**IRIX 5.3 now boots on the DE10-Nano and dies in the same place every time.
IRIS boots the same operating system fine. Find out what is different, by
building a trace of IRIX's initialisation in IRIS and walking it against
ours.** The deliverable is a written diff of behaviour with the divergence
point named - not a speculative fix.

## Where the machine is, as of 2026-08-31

The core boots IRIX 5.3 from an installed disk, runs `fsck`, mounts root,
starts `init`, and then:

```
PANIC: init died (why = 2, what = 0x9)
Dumping to dev 0x2000011 at block 0, space: 0x27de pages
```

`tests/hardware/irix53-init-died-20260831.png`. That panic is **byte for byte
what the Verilator model produces**, so hardware and simulation finally agree.

**It is not the caches, and this is measured.** `cache=off` in the OSD -
verified applied (`SGIINDY.CFG` byte 1 = `0x08`) and verified effective (the
run is visibly slower) - dies identically. With every cache bypassed there is
no incoherency left to blame. [21-icache-bug.md](21-icache-bug.md) leads with
this; its older instruction-cache conclusion is true of Verilator only.

There **is** a real, separate defect the IRIS author diagnosed and it is worth
knowing while you read traces: this core has **no I/D cache coherency at all**,
where an R4400 keeps the primary caches coherent through the inclusive
secondary cache, and IRIX's userspace loader patches relocations and jumps in
with no flush. It is genuine, it is unfixed, and it does **not** explain a
failure that survives every cache being off.

## Read this before you build anything

### IRIS ALREADY HAS A FULL DEBUGGER. DO NOT WRITE ONE.

`../iris/debug.md` documents it. It listens on TCP 8888 (`nc localhost 8888`)
and already gives you almost everything this task needs:

| What you want | Command |
|---|---|
| every instruction executed | `debug on` |
| **every uncached access - i.e. every device register touch** | `trace uncached on` |
| last N instructions before a point | `dt [count]` |
| call stack | `bt [frames]` |
| stop on a class of exception, incl. `vce` | `exception <class> on` |
| break on PC / read / write / fetch, virtual **or physical** | `bp add <addr> [pc\|r\|w\|f\|pr\|pw\|pf]` |
| function names instead of addresses | `loadsym unix.map` |
| primary and secondary cache contents | `l1i`/`l1d`/`l2 <check\|dump>` |

`trace uncached on` plus a physical breakpoint on the WD33C93 register block is
the single most valuable pair here: it is IRIX's device-initialisation sequence,
in order, with the PC that issued each access.

There is also an **MCP server**, `../iris/src/iris_mcp.py`, exposing the monitor
as tools (`run_command`, `read_memory`, `get_registers`, `read_cop0`, ...). If
you can attach to it, drive the debugger with that instead of scraping a
telnet session.

### The model for what to build where the debugger is not enough

`C:\Temp\mistercore\snow\core\src\cpu_m68k\heapwatch.rs`. Read it. It is the
same shape of problem solved once already: an FPGA core corrupted a driver
image mid-boot, snow booted the same ROM and disk cleanly, so a purpose-built
watch was added **to the working emulator** to log what the same code does when
it works - a capped EXEC log over a PC range with key registers, a capped WRITE
log of every bus write from that range, and a one-shot binary RAM dump at a
named trigger for offline disassembly. Build the IRIS equivalent for IP24
initialisation only if the built-in commands cannot answer the question, and
build it in the same spirit: capped, targeted, written to a file you can diff.

### Build IRIS first - it is not built here

There is no `target/` in the IRIS checkout. `cargo 1.100.0-nightly` is on PATH.

```sh
cd /c/Temp/mistercore/iris
git switch -c irix-init-trace          # the branch you were asked to make
cargo build --release --features developer,developerx,debug_cache
```

`Cargo.toml`'s `[features]` block documents them: `developer` (extended state),
`developerx` (breaks on IBE/DBE/ADEL/ADES/TLB errors), `debug_cache` (tracks a
cache line across every operation). `ci_clock` makes the CP0 timer
deterministic and is worth having if you want two runs to line up.

### Use the SAME disk on both sides, or the comparison is worthless

The board boots `/media/fat/games/SGIIndy/SGIIndy53.img` - 2 GB, an installed
IRIX 5.3 root with `sash` and `ide` in its volume header, EFS root on partition
0, swap on 1. A pristine `SGIIndy53.img.zip` sits beside it on the SD card.
Copy the image to this PC and point IRIS at it (`[scsi.1] path = ...`,
`cdrom = false`). **Do not** reach for `~/irix-images/Indy-IRIX53_dev.chd` that
older docs mention - it is on a different machine and it is a different
install.

Two things that waste ten minutes each: the `--ci` control socket path must be
short (`/tmp/...`, `SUN_LEN`), and `iris-ci serial-send` takes plain text, not
`'1\r'`.

## The method

1. **Get IRIX booting in IRIS on that exact image**, to a login prompt. Record
   how long it takes and what it prints. This is the oracle run.
2. **Capture the initialisation trace** - `trace uncached on` from reset through
   `init`, with symbols loaded. Save it to a file. This is every device the
   guest touches, in order, with the code that touched it.
3. **Get the same view from our side.** The board is a ten-minute run
   (`scripts/hwcheck.sh`, then read the screen); Verilator has `--exc`,
   `--ramdump`, `--trace-from-pc` and the bus trace, and
   [06-simulation.md](06-simulation.md) lists them. **Note the whole-machine
   Verilator model does not build on this Windows box** - per-module benches and
   `make -C verilator cpuonly` do; the board is the full-machine instrument here.
4. **Diff the two initialisation sequences and name the first real divergence.**
   Not the first textual difference - traces of two different runs differ
   constantly for uninteresting reasons. Collapse repeats, ignore timing, and
   look for a device register that is read or written on one side and not the
   other, or answered differently.
5. **Then, and only then, form a hypothesis about the RTL.**

## Traps, all paid for already

* **This failure is not deterministic.** Two runs of one bitstream failed in
  completely different places on 2026-08-31 (`Creating miniroot devices` in one,
  deep in package installation in the other), and a conclusion drawn from a
  single run was wrong and cost hours. `scripts/bootrate.sh` exists for this.
  **Never conclude from one run.**
* **A PC diff of two runs will lie.** `--pc-user` is the *decode* tap and
  re-presents an instruction on every replay and stall; it once pointed
  confidently at a "loop" that was a function prologue. Collapse consecutive
  repeats before comparing.
* **`alive.py`'s default address watches the PROM's data area**, which a running
  IRIX kernel legitimately never touches. `STATIC` there is not evidence of a
  wedge once IRIX is up. Point it at kernel memory (`0x30100000`).
* **IRIS folds the target into the initiator.** Its WD33C93A model talks to
  device objects directly; there is no bus-level target, no REQ/ACK, no phase
  machine. So it is an excellent oracle for *what the driver does* and no oracle
  at all for *what a target should answer*. That distinction already cost one
  bad build: copying IRIS's permissive MESSAGE OUT handling into `scsi.v`
  broke the PROM (`SYNC negotiation error`), because IRIS never has to answer
  the question the target arm asks.
* **Two things in the CPU are known-bad switches, both measured, both recorded
  in the code.** `DATACACHEFORCEWEB => '1'` wedges the machine
  (`cpu_datacache.vhd` makes `write_done` wait on a `wb_done` some store path
  never raises). Going to COMMAND phase unconditionally after MESSAGE OUT breaks
  the PROM. Do not re-derive either.

## What success looks like

A commit on `main` that adds a document naming **the first place IRIX's
initialisation diverges between IRIS and this core**, with both traces quoted
around that point and the evidence for why it is the divergence rather than
noise. A trace-capture script or an IRIS-side watch, on the IRIS branch, that
makes the comparison repeatable.

"They are identical through initialisation and `init` dies later for another
reason" is a perfectly good answer to come back with, **if** it is backed by the
traces - it would move the search to `init` itself and rule out a whole area.

What is not success: an RTL change with no named divergence behind it. There
have been enough of those this week, and two of them cost a working PROM.
