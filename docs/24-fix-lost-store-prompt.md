# Work item: find and fix the lost store that kills `init`

Paste everything below the line as the opening message of a fresh session. This
follows [23-init-divergence.md](23-init-divergence.md), which did the analysis
and named the defect. **This one is RTL work**: the analysis is finished, the
suspects are down to four files, and there is a deterministic 28-minute
reproduction on this machine that needs no board and no bitstream.

---

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA, at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly - do not create branches in this repository.** The reference emulator
IRIS is the sibling checkout `C:\Temp\mistercore\iris`; if you need to change
anything there, branch first.

## The job

**A store from userland does not land in memory, and that is what kills IRIX.**
`/sbin/init` allocates a table, stores the pointer into its own `.bss`, reads it
back a moment later and gets zero. Find where the write is lost and fix it.

Read [23-init-divergence.md](23-init-divergence.md) first - all of it. It is the
evidence, and everything below assumes you have it.

## What is already established - do not re-derive any of this

* `init` faults at **`0x7fc07ca4`** (`sw zero, 12(v0)`) with `v0 == 0`. `v0` was
  loaded at `0x7fc07c8c` from **`0x7fc43ef0`**, the first word of `init`'s
  `.bss`. `init` blocks SIGSEGV, so the kernel kills it and panics on the death
  of pid 1: `init died (why = 2, what = 0x9)`.
* **Exactly one instruction in the whole binary writes that word**:
  **`0x7fc073b8`**, `sw v0, 0x3ef0(at)`, in the delay slot of `jal 0x7fc09ae8`,
  immediately after `jal 0x7fc10b40` - a `calloc(count, 20)`.
* **The allocation succeeds.** In the *failing* machine, `init`'s saved register
  context holds `0x7fc447a0` with `0x17b0` (6064 = 6060 rounded to 8) beside it,
  a few hundred cycles after the call. Independently, the RAM dump at the panic
  has a 6060-byte hole in `init`'s heap at exactly that block's address and
  size, with 78 live pointers above it and one inside.
* Therefore **the store is lost**, and nothing wrote a zero: `.bss` starts as
  zero and the write never landed.

### Ruled out, each by measurement

| suspect | how it was ruled out |
|---|---|
| the caches | `cache=off` on the board dies identically; `--no-dcache` in sim panics identically (215,149,699 cycles vs 242,603,699) |
| DDR3, `ddr3_mux`, HPS traffic | the Verilator model replaces DDR3 with `sim_ram.v` and still loses the store |
| `malloc` / out of memory | the heap works - 78 live pointers above the block - and the request was 4680-6060 bytes by pid 1 at the start of boot |
| `rld`, relocation, I/D coherency | `/sbin/init` is **statically linked** (no `PT_INTERP`); `rld` is at `0x0fb60000`, nowhere near |
| the wrong `var` count (234 vs 303) | the sim computes 303, like IRIS, and panics anyway |

### What is left

* `rtl/cpu/r4300_bus.sv`
* `rtl/sgi/ram_arb.sv`
* `rtl/sgi/sgi_memmap.sv`
* the CPU's store path below the primary cache, in `rtl/cpu/r4300/cpu.vhd`

## The instrument, which is new and is the whole reason this is now tractable

**The whole-machine Verilator model builds and boots IRIX to the panic in 28
minutes, deterministically, with nothing emulated away except DDR3.**
[23-init-divergence.md](23-init-divergence.md) has the flag archaeology; you
only need:

```sh
make -C verilator wholemachine
./verilator/obj_wm/Vsim_top \
    --prom boot.rom --no-gfx --ram-mb 64 \
    --disk 1=/path/to/SGIIndy53.img \
    --type-on "Option?" "1\r" --stop-on "init died" \
    --max-cycles 3000000000
```

Both of those were run verbatim from a clean `obj_wm/` on 2026-09-01: the target
builds from scratch in a couple of minutes and the binary boots. `--disk` (not
`--disk-rw`) keeps guest writes in memory, so a run cannot damage the image. Two runs stopped on the identical cycle (242,603,699), so **A/Bs
against this model are trustworthy** - which is what makes it worth more than
the board for this particular bug.

Useful switches, all already exercised: `--no-dcache`, `--watch HEX`
(repeatable, physical address, prints address and data of every access),
`--trace-from-pc HEX` + `--trace-count N`, `--ramdump A:N:F`, `--exc`,
`--pc-user FILE`, `--stop-on STR`.

Run it in WSL `Ubuntu-24.04` (Verilator 5.020 is only there). A disk image is at
`C:\Temp\mistercore\iris\SGIIndy53-master.img` - pristine, never booted
read-write; do not point `--disk-rw` at it.

## The first experiment, and it should be the first thing you run

**Catch the store on the bus.** With `--no-dcache` every store is a bus
transaction and the panic still happens, so the write either appears or it does
not, and that single fact splits the remaining suspects:

```sh
./verilator/obj_wm/Vsim_top ... --no-dcache \
    --trace-from-pc 0x7fc073b8 --trace-count 200
```

The trace arms the first time `0x7fc073b8` is decoded, so the store should be
among the first writes in it.

| what the trace shows | what it means |
|---|---|
| no write at all | the store never left the CPU - `cpu.vhd`'s store path or `r4300_bus.sv` |
| a write with the right data at a **wrong physical address** | address decode: `sgi_memmap.sv`, or `ram_arb.sv` |
| a write with the right address but **wrong data** | data path / byte enables |
| the write looks correct | something *later* overwrites it - take that physical address and `--watch` it for the whole boot to catch the culprit |

**You will need the physical address of `init`'s `.bss` page and it cannot be
computed.** `init`'s data segment is *not* physically contiguous, so deriving it
from the `.data` page is wrong (that was tried; it gave a plausible-looking zero
that meant nothing). Take it from the trace above.

## Then: verify the fix three ways, in this order

1. `./obj_wm/Vsim_top ... --stop-on "init died"` runs to `--max-cycles` instead
   of stopping. That is the primary gate and it is 30 minutes.
2. `--no-dcache` as well, because that is the configuration the bug was
   localised in and it must stay fixed there.
3. **Then the board**, and **more than once** - `scripts/hwcheck.sh
   --no-deploy` after a Quartus fit. See the determinism trap below.

## Traps, all paid for already

* **The board's failure mode varies between runs.** Two runs of one bitstream on
  2026-09-01 gave `init died` and, seventeen minutes later, SCSI `READ(10)`
  timeouts in `fsck`. Never conclude from one board run. `scripts/bootrate.sh`
  exists for this. The *simulation* is deterministic; the board is not.
* **`rtl/cpu/generated/r4300_wrap.v` is gitignored and goes stale silently.** It
  is the GHDL lowering of `rtl/cpu/r4300_wrap.vhd`, and Quartus never reads it,
  so a stale copy is invisible until Verilator fails with `PINNOTFOUND` on nine
  `dbg_*` pins. **If you touch any CPU VHDL, run `tools/gen_r4300_verilog.sh`
  before believing a Verilator result.** It needs GHDL's llvm shim: `mkdir -p
  /tmp/llvmshim && ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1
  /tmp/llvmshim/libLLVM-18.so.18.1 && export LD_LIBRARY_PATH=/tmp/llvmshim`.
  The script derives `$ROOT` from `$BASH_SOURCE`, so a de-CRLF'd copy of it must
  stay inside `tools/`.
* **Two known-bad switches, both measured, both in the code as comments.**
  `DATACACHEFORCEWEB => '1'` wedges the machine (`cpu_datacache.vhd` makes
  `write_done` wait on a `wb_done` some store path never raises). Going to
  COMMAND phase unconditionally after MESSAGE OUT breaks the PROM. Do not
  re-derive either. **`DATACACHEFORCEWEB` is going to look extremely tempting
  for a lost-store bug - it is a write-through switch. It has already been tried
  and it hangs.**
* **`--pc-user` is the decode tap** and re-presents an instruction on every
  replay and stall, so a raw diff of two PC logs lies. Collapse consecutive
  repeats first. This is why the panic's PC trace shows `7fc07ca8` sixty times.
* **Attach a disk to the sim or half the machine never runs.** Without `--disk`
  there is no SCSI target, no negotiation, and the SCSI defects below hide
  completely.
* **`tools/misterdeploy/efspeek.py` is wrong** - it decodes an EFS extent as
  `{bn:24,ex:8}{offset:24,nbytes:8}` when it is `{magic:8,bn:24}{length:8,
  offset:24}`, and reads inode extents at 20 when they live at `0x20`. Use
  `tools/misterdeploy/efsread.py`.
* **Do not kill IRIS mid-write.** Doing that during a kernel relink corrupted a
  disk image here and cost a boot chasing a hang that was self-inflicted.
* **A headless IRIS boot leaves `/var/adm/SYSLOG` entries that look exactly like
  a board run**, `xdm` failing on `Display :0` included. Do not read them as the
  core succeeding.

## The second defect, if the first is blocked or once it is fixed

**The SCSI target fails IRIX's synchronous-transfer negotiation, and the PROM's
too.** It reproduces in the same model in **ten minutes** - the PROM prints
`sc0,1,0: SYNC negotiation error, resetting SCSI bus` during POST, before IRIX
is loaded. It is a separate bug from the lost store and neither is shown to
cause the other.

The contract, captured from IRIS and committed as
[`tests/traces/iris-scsi-negotiation.txt`](../tests/traces/iris-scsi-negotiation.txt):
after **Select-with-ATN (`0x06`)** report SCSI status **`0x11`** then **`0x8E`**;
accept a **six-byte** DMA'd MESSAGE OUT (IDENTIFY + a five-byte SDTR); report
**`0x8A`**. The driver then issues **Abort (`0x01`)** - there is *no* CDB behind
the negotiation, which is where `rtl/scsi/scsi.v`'s reasoning is wrong: its
`cmd_timeout` design assumes IRIX always follows a multi-byte MESSAGE OUT with a
command, and IRIX does not. What the driver is waiting for is the target's reply
in **MESSAGE IN** - an SDTR of its own, or a MESSAGE REJECT - and this target
presents neither.

**Read `scsi.v`'s comments before touching that arm.** A MESSAGE REJECT was
built once and made things worse, and going to COMMAND unconditionally cost the
PROM its boot. Both are recorded there. The difference now is that you can see
the effect on the PROM *and* on IRIX in ten minutes instead of a Quartus fit.
`rtl/scsi/sgi_scsi.sv` also builds standalone under Verilator with `-fno-gate`,
which is the right unit for a target-side question - **IRIS cannot answer one at
all**, having no bus-level target.

`+define+MSG_DEBUG` turns on a `$display` in `scsi.v` that prints the actual
MESSAGE OUT bytes; IRIS cannot show them, its model reads them directly rather
than through DMA.

## A third thing, smaller, and board-only

The board's kernel sizes the machine **4 MB smaller** than IRIS's and than the
simulator's - `234` against `303` in the same `var` field, `10240` against
`11264` pages. It does **not** reproduce in a model that replaces DDR3 and
`ram_arb` with `sim_ram.v`, so it lives on the real memory path, and it is not
what kills `init`. Read it live off the board with
`python3 /media/fat/sgidbg/guestmem.py 0x881c5ef8 0x80` - it is a KSEG0 address,
so it is just physical memory.

## What success looks like

The store lands; `init` survives; IRIX reaches multiuser in the simulator with
and without `--no-dcache`, and then on the board on more than one run.

A named RTL defect with the trace that shows it is also a good outcome even if
the fix has to be deferred - that is a strictly better position than tonight's,
and it is what the first experiment is designed to produce.

**What is not success**: an RTL change that makes the panic go away without a
trace explaining why. There have been enough of those, and two of them cost a
working PROM.
