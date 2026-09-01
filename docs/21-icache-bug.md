# OPEN BUG: `init` dies, and on HARDWARE it is not the instruction cache

**Status: open.** Found 2026-08-31 in simulation, where the bisection below
points squarely at the instruction cache. **Reproduced on a DE10-Nano the same
evening, where the workaround that saves it in Verilator does NOT save it.**
Read the hardware box first; the rest of this file is the simulation case and
is still accurate about the simulator.

## ON HARDWARE, 2026-08-31: same panic, and turning the caches off changes nothing

IRIX 5.3 now boots on the board from an installed disk
(`games/SGIIndy/SGIIndy53.img`, an installed root with `sash` in its volume
header), fscks, mounts, starts `init` - and panics with a message that is
**byte for byte** the simulator's:

```
PANIC: init died (why = 2, what = 0x9)
Dumping to dev 0x2000011 at block 0, space: 0x27de pages
```

`tests/hardware/irix53-init-died-20260831.png`. That is the first time hardware
and Verilator have failed in the same place, and it makes the board a usable
test rig for this bug - roughly ten minutes a run.

**And then the bisection does not transfer.** With `cache=off` in the OSD -
verified applied (`SGIINDY.CFG` byte 1 = `0x08`) and verified effective (the
same boot is visibly slower, still mid-dump where the cached run had finished) -
**`init` dies identically.** In simulation `--no-icache` survives this exact
panic and reaches `ec0: no carrier`.

With every cache in the machine bypassed there is no cache incoherency left to
blame, so **whatever kills `init` on the board is something the simulator does
not model**: DDR3 timing, `ram_arb`, or the DMA path are where to look. The
I/D coherency gap described below is real and worth fixing on its own merits -
it is a genuine architectural defect - but it is not sufficient to explain the
hardware failure, and a fix for it should not be expected to clear this panic.

**Method note, learned the hard way today:** this failure is not
deterministic. Two runs of one bitstream failed at completely different points
(`Creating miniroot devices` in one, deep in package installation in the
other), and a conclusion drawn from a single run was wrong. `scripts/bootrate.sh`
exists for exactly this. Run it more than once before believing anything.

---

## The simulation case (accurate for Verilator)

**Isolated to one component, reproducible in five minutes, with a working
oracle that disagrees.** Found 2026-08-31, after the two CP0 bugs in
[09-cpu-validation.md](09-cpu-validation.md) were fixed and IRIX 5.3 started
running userland for the first time.

This file is the whole case: the symptom, the bisection, everything already
ruled out with the measurement that ruled it out, and the leads that are left.
It is written so the next session can start from the leads rather than
re-deriving the bisection, which took most of an afternoon.

---

## Symptom

IRIX 5.3 boots, prints its banner, starts `init`, and `init` dies:

```
IRIX Release 5.3 IP22 Version 12200159 System V
Copyright 1987-1994 Silicon Graphics, Inc.
All Rights Reserved.

WARNING: time of day clock behind file system time--resetting time
WARNING: clock gained 11158 days
WARNING: CHECK AND RESET THE DATE!
WARNING: Process [init] 1 generated trap, but has signal 11 held or ignored
Process has been killed to prevent infinite loop
PANIC: init died (why = 2, what = 0x9)

Dumping to dev 0x2000011 at block 0, space: 0x27de pages
```

`--exc` shows the end of it. `init`'s dynamic linker runs **thousands** of
instructions and hundreds of syscalls — page faults, `Sys`, `TLBL`, `TLBS`,
all being serviced correctly — and then stores through a pointer that came out
zero:

```
[234785914] EXC TLBL   code=02 badvaddr=00000010 epc=7fc0f798
[234785974] EXC TLBL   code=02 badvaddr=ff800000 epc=7fc06800
[234796933] EXC TLBL   code=02 badvaddr=7fc20f90 epc=7fc20f90
[234801203] EXC TLBS   code=03 badvaddr=0000000c epc=7fc20f90
```

`badvaddr=0000000c` on a store is a null-pointer dereference. So this is not a
control-flow crash: something computed a pointer and got zero.

## Reproducing it

```sh
chdman extractraw -i ~/irix-images/Indy-IRIX53_dev.chd -o /tmp/irix53_dev.img
make -C verilator cputest
./verilator/obj_dir/Vsim_top \
    --prom roms/IP24_Indy/ip24prom.070-9101-011.bin --no-gfx \
    --disk 1=/tmp/irix53_dev.img \
    --max-cycles 6000000000 --stuck 600000000 \
    --type-on 'Option?' '1\r' --console /tmp/boot.txt
```

About ten minutes to the panic, deterministic, same cycle every time.
`tests/run-irix.sh` is the ratchet for the part that *does* work; it stops at
the kernel banner on purpose, because that is what is currently guaranteed.

## It is the instruction cache. This is measured, not inferred.

| run | `init` |
|---|---|
| both caches on | **dies** |
| `--no-dcache` | **dies** |
| `--no-icache` | survives — boot goes on to `ALERT: ec0: no carrier: check Ethernet cable` |
| both caches off | same as `--no-icache` |

`--no-icache` costs roughly 5× in simulated cycles, so it is a debugging lever
and not a configuration to ship. On hardware there is no I-cache-only switch
today: `sgiindy.sv` gates `icache_en` and `dcache_en` from the one OSD bit
`status[11]`. Splitting that into two bits is a two-line change if a stopgap
build is ever wanted.

## The disk image is fine, and there is an oracle that proves it

`~/repos/iris` boots the **same file** to `The system is coming up.`:

```sh
printf 'headless = true\nno_audio = true\nbanks = [64,0,0,0]\n\n[scsi.1]\npath = "/tmp/irix53_dev.img"\ncdrom = false\n' > /tmp/iris.toml
~/repos/iris/target/release/iris --config /tmp/iris.toml \
    --prom roms/IP24_Indy/ip24prom.070-9101-011.bin \
    --ci --ci-socket /tmp/i.sock &
export IRIS_SOCKET=/tmp/i.sock
~/repos/iris/target/release/iris-ci start
~/repos/iris/target/release/iris-ci serial-send 1
~/repos/iris/target/release/iris-ci serial-read
```

Two things that waste ten minutes each if you do not know them: the control
socket path must be short (`/tmp/…`, not the scratchpad — `SUN_LEN`), and
`iris-ci serial-send 1` takes plain text, **not** `'1\r'`.

## Ruled out, with what ruled it out

Do not spend the evening on these again.

| tried | result |
|---|---|
| the mini data TLB (`DISABLE_DTLBMINI => '1'` in `r4300_wrap.vhd`) | no change |
| the data cache alone (`--no-dcache`) | no change |
| unimplemented `cache` ops entering the D-cache command machine unstalled | **fixed and kept** — the IP22 kernel executes ~1000 such ops per boot — but no change to this bug |
| I-cache commands dropped while the cache was filling | **fixed and kept** (`cpu_instrcache.vhd` latches them now) — no change |
| translating the address of `Hit_Invalidate I` (op `0x10`) | **WRONG, reverted.** This cache is *virtually indexed* — `cpu_instrcache.vhd` indexes its tag ram with `read_addr(13:5)`, the virtual fetch address, and compares a physical tag. The untranslated address is the index it needs. Upstream grouping `0x10` with the index ops `0x00`/`0x08` is correct here for the wrong-sounding reason |
| tag and data of a filled line written at different indices | **hazard removed and kept**, but it moved no measurement (see below) |

## Leads that are left, in the order worth trying

### 1. The fill path was written for three clocks and now has one

`rtl/cpu/r4300_wrap.vhd` ties `clk1x`, `clk93` and `clk2x` **all to the one
system clock**:

```vhdl
clk1x  => clk,
clk93  => clk,
clk2x  => clk,
```

`cpu_instrcache.vhd`'s fill logic was written for an N64, where those are
genuinely different clocks and the two-stage `fill_addrTag_1x` /
`fill_addrTag_2x` pipeline is a sub-cycle crossing. At 1:1 it is two whole
cycles of delay. **Anything in that file whose correctness came from a 2×
clock is suspect**, and the fill data path (`cache_addr_a`, `ram_grant_2x`,
`cache_wr_a`) is all of it.

One instance of this has already been dealt with: the FILL arm writes the tag
at `fill_addrTag_sav(13:5)` while the data was being written at
`fill_addrTag_2x`, the same value two registers later — a line whose tag says
"present, page P" with another line's words under it. That is fixed, and it is
recorded honestly in the code as a **hazard removed rather than a bug fixed**,
because making the change moved no measurement. The rest of the file has not
been audited the same way.

### 2. Two tag comparators, one TLB answer

`cpu.vhd`:

```vhdl
FetchAddrTLBMuxed1 <= TLB_instrAddrOutFound when (TLB_instrMapped = '1') else FetchAddr1(31 downto 0);
FetchAddrTLBMuxed2 <= TLB_instrAddrOutFound when (TLB_instrMapped = '1') else FetchAddr2(31 downto 0);
```

There are two tag rams fed two different virtual fetch addresses, and both
comparators are handed the one `TLB_instrAddrOutFound` — which is the
translation of whichever address `TLB_instrMapped` was computed from. Within a
page that is the same physical page number and it does not matter. **Across a
page boundary it is a different page number**, and the comparison uses the
wrong one. `read_hit` is muxed by `read_select` so only the selected path is
consumed, which is why this is a lead and not an obvious bug — but it deserves
a targeted test rather than an argument.

### 3. The alias case

16 KB, direct-mapped, indexed by **virtual** bits 13:5, tagged with
**physical** bits 31:12, over 4 KB pages. Bits 13:12 of the index come from the
virtual page number, so there are four virtual colours per physical page. A
real R4000 primary cache is virtually indexed too and IRIX knows it, so read
what IRIX assumes before concluding the core is wrong. Note also that `Config`
advertises 16-byte lines while this cache has 32-byte lines — that direction is
safe (IRIX over-invalidates), but the reverse would not be, so check the
direction rather than trusting this sentence.

## Method note: the PC diff that lied

The obvious way in is to diff the user-mode PC stream of a good run
(`--no-icache`) against a bad one and look at the first divergence.
`--pc-user FILE` exists for exactly this. **Read its caveat before trusting the
answer.**

It is the *decode* tap, and decode re-presents an instruction on every pipeline
replay and stall. Two configurations replay in different places, so a raw diff
reports divergences that are not there. It confidently pointed at a
two-instruction "loop" at `0x7fc05274` that `--trace-from-pc 7fc051f0` then
showed to be:

```
7fc05270: 27bdffa8   addiu sp, sp, -0x58
7fc05274: afbf003c   sw    ra, 0x3c(sp)
7fc05278: afb70034   sw    s7, 0x34(sp)
7fc0527c: afb1001c   sw    s1, 0x1c(sp)
```

— a function prologue with no branch in it at all. Collapse consecutive
repeats in both streams before comparing, and treat the result as a lead.

**`dbg_rpc` / `dbg_retire` exist to fix this properly and are not finished.**
They are ports for a retire-accurate PC, mirroring `pcOld2..4` outside the
savestate export's `-- synthesis translate_off` so they survive into the
netlist GHDL lowers for Verilator, and they are wired from `cpu.vhd` through
`r4300_wrap` / `sgi_indy` / `sim_top` all the way to the harness — where they
are **deliberately unused**. The stream they produce comes back interleaved
rather than sequential, so the mirror does not track the pipeline the way
`pcOld2..4` do. They are left in place, unused and labelled, rather than
removed or quietly used, because an instrument that looks right and is not is
worse than none.

**Finishing that is probably the most valuable hour available on this bug**: a
trustworthy retire trace turns "diff a good run against a bad one" into a
routine technique, and this is precisely the kind of fault — rare, data-shaped,
no message — that nothing else here can find.

## Instruments that helped, and where they are

All in `verilator/sim_cputest.cpp` unless noted; `docs/06-simulation.md` has
the full list.

* `--exc` — one line per exception with `Cause.ExcCode`, `BadVAddr`, `EPC`.
  From the console, every failure is the same three words ("generated trap").
* `--ramdump A:N:F` — guest RAM to a file, KSEG-stripped, for
  `tools/misterdeploy/disbin.py`. `guestmem.py` for the simulator.
* `--trace-from-pc H` — arm the bus trace the first time PC H is decoded. A
  cycle number cannot be known in advance for anything after a kernel boots,
  and this is how the line fill serving a named instruction gets caught with
  its data.
* `dbg_pc` and the last-64-PC ring, printed on **every** exit
  (`rtl/cpu/r4300/cpu.vhd`).
* `dbg_mode` — `{privilegeMode, bit64region, region_TLBmapped}`, printed beside
  the PC by `--pc`.
