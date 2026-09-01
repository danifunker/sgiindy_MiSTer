# The lost store: two TLB faults, taken in the wrong order

**Work item: [24-fix-lost-store-prompt.md](24-fix-lost-store-prompt.md), which
followed [23-init-divergence.md](23-init-divergence.md).**

**Status: the defect is FOUND and PROVEN. The fix is NOT yet working.** It is
in the CPU's exception ordering, not in the memory path - `r4300_bus.sv`,
`ram_arb.sv` and `sgi_memmap.sv` are all innocent, and the store never reaches
them. Four fix attempts have each been disproved by measurement; the fifth was
still building when the session ended. **Nothing has run on hardware yet.**
[26-resume-tlb-epc-fix.md](26-resume-tlb-epc-fix.md) is the work item that
carries it forward and lists what each attempt ruled out.

Written 2026-09-01.

---

## The short version

`/sbin/init` stores its process-table pointer in the **delay slot of a `jal`**:

```
0x7fc073b4: 0ff026ba  jal 0x7fc09ae8
0x7fc073b8: ac223ef0  sw  v0, 0x3ef0(at)      ; *(0x7fc43ef0) = calloc(303,20)
```

Two TLB faults happen at once on that pair:

* the **store** at `0x7fc073b8` misses on `0x7fc43ef0` - a data-side fault, and
* the **fetch of the branch target** `0x7fc09ae8` misses too - an
  instruction-side fault.

The **fetch-side** exception is accepted first, sets `SR.EXL`, and writes
`EPC = 0x7fc09ae8`. Fifty-three cycles later the store's own fault arrives,
finds `EXL` already set, and - by the R4000 rule the file already implements
correctly - **declines to overwrite `EPC`**. MIPS reports the *oldest*
instruction's exception; this reports the youngest's.

The kernel is handed `BadVAddr = 0x7fc43ef0` (the store's address) with
`EPC = 0x7fc09ae8` (the branch target) and `Cause.BD = 0`. It maps the page,
`eret`s to `0x7fc09ae8`, the callee runs, returns to `0x7fc073bc` - and **the
delay-slot store is never retried**.

`init`'s `.bss` starts as zero and stays zero. Later it reads the pointer back
at `0x7fc07c8c`, gets `0`, and faults dereferencing it at `0x7fc07ca4`. `init`
blocks SIGSEGV, so the kernel kills it and panics on the death of pid 1:
`PANIC: init died (why = 2, what = 0x9)`.

**Nothing in the memory path drops anything.** The store is never issued,
because the instruction that would have issued it is never executed a second
time.

---

## The measurement

Two whole-machine Verilator runs, one with the primary caches off and one with
them on. Both reproduce the panic on the cycle
[23-init-divergence.md](23-init-divergence.md) recorded, so they are directly
comparable to it.

The decode-stage PC trace, collapsed so a stalled instruction is one line
(`--trace-from-pc 0x7fc073b8 --pc --exc`, which arms all three logs on the store):

**Caches on** - 242,603,699 cycles to the panic:

```
[235877674..235877724] PC 7fc073b8  ksu=2   (x51)   <- the store, USER mode,
                                                       stalled on its TLB walk
[235877725]  *** EXC TLBL  code=02 badvaddr=7fc09ae8   <- the FETCH's fault,
                                                          taken first
[235877727..235877777] PC 7fc09ae8  ksu=0   (x51)   <- now the data walk runs
[235877778]  *** EXC TLBS  code=03 badvaddr=7fc43ef0 epc=7fc09ae8
                                                    <- the STORE's own fault,
                                                       EPC already spoken for
[235877798]            PC 80000180                  <- first handler instruction
```

**Caches off** - 215,149,699 cycles, same shape:

```
[207884235..207884285] PC 7fc073b8  ksu=2   (x51)
[207884286]  *** EXC TLBS  code=03 badvaddr=7fc09ae8
[207884288..207884338] PC 7fc09ae8  ksu=0   (x51)
[207884339]  *** EXC TLBS  code=03 badvaddr=7fc43ef0 epc=7fc09ae8
[207884359]            PC 80000180
```

Two things to read carefully in those lines, both instrument artefacts of the
binary they were taken with and both fixed since:

* **`epc=` is one exception late** - see
  [the instrument note](#the-exception-log-was-lying-by-one-exception) below.
  That is exactly why the store's line carries `epc=7fc09ae8`: it is the value
  the *fetch's* exception wrote, which is the whole point.
* **`code=` on the FIRST line is not reliable either**, for the same reason one
  level down: the instruction-side arm writes `Cause.ExcCode` on the clock
  *after* it raises `dbg_exc`, so what prints is whatever the previous
  exception left there - `TLBL` in one run, `TLBS` in the other, from the same
  event. **`badvaddr=` is the field that settles it**, because it IS written on
  the pulse: `7fc09ae8` is an instruction address, so that first exception is a
  fetch-side fault in both runs.

**Not one instruction of the handler is fetched between the two exceptions** -
the first PC at `0x80000180` is 20 cycles *after* the second one. From
software's point of view this is a single trap, and the machine hands it the
wrong half.

### The kernel's own trap frame says the same thing

The bus trace catches IRIX writing `init`'s register context into its u-area.
Registers land 8 bytes apart with `r0` at `0x0835d1d8`, which puts `ra` at
`0x0835d2d0` and the CP0 fields after it:

| address | value | field |
|---|---|---|
| `0835d1e0` | `0x7fc40000` | `at` - built by `lui at,0x7fc4` at `0x7fc073b0` |
| `0835d1e8` | `0x7fc447a8` | **`v0` - the allocator's return value** |
| `0835d210` | `0x7fc45f54` | `a3` - `0x7fc447a8 + 6060`, the end of the block |
| `0835d2d0` | `0x7fc073bc` | `ra` - the `jal`'s link, so the branch did execute |
| `0835d2d8` | `0x0000ff13` | `SR` |
| `0835d2f0` | `0x7fc43ef0` | **`BadVAddr` - the store's address** |
| `0835d2f8` | `0x0000000c` | **`Cause`** - ExcCode 3 = TLBS, `BD` clear |
| `0835d300` | `0x7fc09ae8` | **`EPC`** |

`v0 = 0x7fc447a8` is **the same pointer IRIS returns** at the same instruction.
So the allocator was never the problem, and [23](23-init-divergence.md)'s heap
forensics were right: the block was handed out and only the copy in `.bss` is
missing.

### `0x7fc09ae8` cannot be the faulting instruction

This is what makes the reading airtight rather than an inference from offsets:

```
0x7fc09ae8: 3c027fc4  lui v0,0x7fc4
0x7fc09aec: 8c42005c  lw  v0,92(v0)      ; reads 0x7fc4005c, not 0x7fc43ef0
```

`lui` touches no memory at all. **No instruction at `EPC` can produce
`BadVAddr = 0x7fc43ef0`.** The only instruction in the whole binary that
addresses that word is the delay-slot store - [23](23-init-divergence.md)
established that by scanning all 216 KB of `init`'s text, and a second scan
here agrees: 253 instructions reach page `0x7fc43000` and exactly one of them
writes `0x7fc43ef0`.

---

### Every write to EPC, which is what finally settled it

Two fix attempts failed before this one, both because the *mechanism* was
right and the *place to intervene* was guessed. `dbg_exc_epc` is driven
continuously rather than only at an exception, so a `--epc` flag logs every
change of EPC with no RTL change at all - and that ends the guessing:

```
[207884235] trace armed at PC 7fc073b8
[207884236] EPC <- 7fc1128c   (was 00000000)     <- a previous trap's, irrelevant
[207884286] EXC TLBS badvaddr=7fc09ae8           <- the FETCH's fault
[207884288] EPC <- 7fc09ae8   (was 7fc1128c)     <- and it commits its EPC here
[207884339] EXC TLBS badvaddr=7fc43ef0           <- the STORE's own fault...
                                                    ...and NOTHING follows it
[207889506] EXC TLBS badvaddr=7fc09ae8           <- the kernel returns to the
                                                    branch target and refaults
```

**The store's exception writes nothing at all.** `excSavedEXL` is 1 by then, so
the guard below discards it. And the correct value is not merely computable -
it is already sitting in a register: `nextEPC_1` is latched at cycle 288 from
`pcOld1 = 0x7fc073b8` with the delay-slot flag set, giving `0x7fc073b4`, and
the 51-cycle stall then freezes it right through to 339.

So the fix has nothing to compute. It only has to stop the guard throwing the
value away.

### And the cop0 state word, which is what finally named the mechanism

`--epc` said the store's fault writes nothing. It did not say *why* the two
attempts to let it write had both missed. A `dbg_cop0` status word - twelve
signals out of `cpu_cop0.vhd`, observability only - does:

```
[207884236] COP0 TLBINSTR              stall=01  nextEPC_1=..73b4
[207884284] COP0                       stall=01  nextEPC_1=..73b4
[207884286] COP0 excStage1 EXL         stall=01  nextEPC_1=..73b4
[207884287] COP0 excStage1 EXL         stall=00  nextEPC_1=..73b4
[207884288] COP0 EXL dReq              stall=04  nextEPC_1=..73b4
[207884289] COP0 EXL TLBDATA           stall=04  nextEPC_1=..73b4
[207884339] COP0 exc savedEXL EXL      stall=04  nextEPC_1=..73b4
```

Read the third and fifth lines together. **At cycle 286, when the fetch-side
exception is accepted, the store has not even ASKED for its translation** -
`dReq` is clear and does not appear until 288. So "was a data request
outstanding when the fetch faulted?" is always no, and any fix conditioned on
it does nothing.

The reason is structural, and it is the real shape of the bug:

```vhdl
EXETLBDataAccess <= ... when (EXETLBMapped = '1' and exception = '0'
                             and stall = 0 and ...) else '0';
```

**An instruction in EXECUTE cannot request its translation while the pipeline
is stalled**, and `stall=01` there is the *fetch* stall - the instruction-TLB
walk for the branch target. So the fetch-side walk always runs first, always
faults first, and always sets `EXL` before the older instruction is even
allowed to try. The ordering is not a race that sometimes goes the wrong way;
it is guaranteed.

And `nextEPC_1` is `..73b4` on every one of those lines: the correct EPC exists
continuously from cycle 236 to 340. Nothing has to be computed or recovered -
only permitted.

## The defect, in the RTL

The two exceptions interact through `SR.EXL`, in
[`cpu_cop0.vhd`](../rtl/cpu/r4300/cpu_cop0.vhd):

```vhdl
if (excSavedEXL = '0') then
   COP0_14_EPC               <= nextEPC_1;
   COP0_13_CAUSE_branchDelay <= isDelaySlot_1;
end if;
```

That guard is **correct** and was added deliberately - the R4000 freezes `EPC`
and `Cause.BD` for a nested exception, and IRIX nests one on every TLB miss
taken inside a handler. It just cannot tell a genuine nested exception from a
**second fault in the same trap**, and the fetch stage running ahead of execute
manufactures the latter: the fetch-side fault is accepted first, sets `EXL`,
and the older instruction's fault then arrives to find `EXL` set and keeps the
younger instruction's `EPC`.

`nextEPC_1` and `isDelaySlot_1` were both **right** the whole time: they are
latched only while `stall = 0`, so the 51-cycle TLB walk freezes them at the
store's values, `0x7fc073b4` and `1`. The correct `EPC` was sitting in a
register and was never written out.

The fix is one term plus the flag that qualifies it:

```vhdl
if (excSavedEXL = '0' or excFetchProvisional = '1') then
```

`excFetchProvisional` is set whenever a fetch-side TLB exception is accepted,
and cleared as soon as the machine **executes a kernel instruction** -
`stall4Masked = 0 and executeNew = '1' and pcOld1(31) = '1'`. That is precisely
"the handler has started and software has seen this trap".

Between the two faults nothing but user PCs executes - the exception vector is
not fetched until cycle 359, twenty cycles *after* the store's fault - so the
flag survives exactly the window it is meant to. A genuinely nested exception,
taken inside a running handler, always sees it clear, so the `EXL` rule keeps
protecting the outer `EPC` exactly as before (cpu-tests:
`excep/exl_preserves_epc`).

Two earlier attempts are recorded below because each ruled something out.

### The arbiter is NOT the place, and that took a run to establish

The obvious reading is that `cpu_cop0.vhd`'s TLB arbiter picks wrong. It does
serve the fetch side first:

```vhdl
elsif (TLB_Instr_fetchReq_saved = '1' or TLB_Instr_fetchReq = '1') then
   ...                                       -- the FETCH stage
elsif (TLB_Data_fetchReq_saved = '1' or TLB_Data_fetchReq = '1') then
   ...                                       -- the EXECUTE stage
```

and a data-side request always belongs to an older instruction than a
fetch-side one, so serving the fetch first inverts the architectural order.
Swapping the two arms, and additionally refusing to start a fetch-side walk on
a clock when the execute stage was asking for one (`TLB_Stall` out of
`cpu_TLB_data` is combinational and high on exactly that clock), looks like the
fix.

**It is not, and the measurement is unambiguous: with both changes in, the boot
was bit-identical - `PANIC: init died` at 215,149,699 cycles, the same trace,
the same two exceptions in the same order on the same cycles.** Over 207
million cycles of IRIX booting, with the TLB busy throughout, reordering those
two arms changed *nothing at all*. That can only mean the two arms are never
both eligible at a decision: **the fetch-side request is always registered
first**, because the fetch stage is always ahead. The arbiter never gets to
choose, so it cannot be made to choose better.

That is why the fix is at the point where the two exceptions actually meet -
the `EXL` guard - and not at the point where their TLB walks are scheduled.
Both changes were reverted.

### What happens after the fix

The fetch-side fault is still taken first and still sets `EXL`; nothing about
the ordering changes. But when the store's own fault arrives 53 cycles later,
`exceptionStage1` is still set, so it writes `EPC = 0x7fc073b4` with
`Cause.BD = 1` - the `jal`, as the architecture requires - over the top of the
branch target. `Cause.ExcCode` and `BadVAddr` are already the store's, because
the data-side path writes those outside the `EXL` guard. The frame the kernel
reads is then coherent for the first time: `EPC` = the branch, `BD` = 1,
`Cause` = TLBS, `BadVAddr` = `0x7fc43ef0`.

The kernel maps the page and returns to the `jal`; the pair re-executes; the
store lands. The fetch-side fault on `0x7fc09ae8` is discarded, which is
correct - that fetch was squashed by the trap, and after `eret` the branch
target is fetched again and faults again, to be handled on its own.

## What this retires from the open list

* **`r4300_bus.sv`, `ram_arb.sv`, `sgi_memmap.sv` are cleared.** The store never
  reaches them. The bus tap was extended to say *who answered* each cycle
  (`ram` / `HOLE` / `dev`, from new `bus_mem_o` / `bus_hole_o` observability in
  `sgi_indy.sv`) specifically so that a write dropped into a MEMCFG hole could
  be told apart from a write main memory took - they are otherwise the same
  address, data and ack. No such write appears; there is no write at all.
* **`docs/23`'s "one inconsistency, recorded rather than explained away"** now
  has a candidate explanation, *offered as a hypothesis rather than a
  measurement*. That inconsistency is the final crash frame reporting `CAUSE=8`
  (TLBL) with `BADVADDR=0` for a store to `0xc`. The instruction-side arm
  writes `COP0_13_CAUSE_exceptionCode <= x"2"` and `BadVAddr` **outside** the
  `excSavedEXL` guard that protects `EPC`, so a fetch fault arriving behind a
  data fault overwrites both while leaving `EPC` alone - which is a `CAUSE` and
  a `BadVAddr` that belong to a different instruction from the `EPC` beside
  them. That is the right shape for what `icrash` printed, and the same
  mechanism as the defect above. **It has not been traced**, and it is a
  separate question from the lost store: the exception-code path is untouched
  by this fix.
* **`DATACACHEFORCEWEB` stays untried**, and is now understood to have been a
  red herring: a write-through switch cannot help a store that is never issued.

## The cpu-tests suite cannot reach this, and that is worth writing down

`cpu-tests/tests/tlb` is thorough - 10 tests covering entry round-trips, page
sizes, ASIDs, the refill vector, and both the Invalid and Modified exceptions -
and none of them could ever have caught this. The suite's own header says why:

> These tests are only safe because the suite runs from KSEG0, which is
> unmapped: rewriting all 48 entries cannot unmap the code doing the rewriting.

**Unmapped code never takes an instruction-TLB miss**, so the suite cannot
produce the one condition this defect needs: a fetch-side and an execute-side
translation outstanding at the same moment. A delay-slot `EPC`/`BD` test would
be worth adding regardless, but it would have *passed* both before and after
this fix, because with no competing fetch miss the existing logic already gets
`EPC` right - `nextEPC_1` and `isDelaySlot_1` were correct the whole time.

The regression guard for this one is the whole-machine boot, which is now 28
minutes and deterministic.

## What this does NOT explain

* **The board sizing memory 4 MB smaller than IRIS** (`234` against `303` in
  `var`, 10240 against 11264 pages). Still board-only, still unexplained, still
  not what kills `init` - the simulator computes `303` and panicked anyway.
* **The SCSI synchronous-transfer negotiation failure.** Independent and still
  present - but no longer a hypothesis. `+define+MSG_DEBUG` (now reachable with
  `make -C verilator wholemachine2 WM_DEFS=+define+MSG_DEBUG`) prints both ends
  of the exchange, and the PROM's own negotiation during POST looks like this:

  ```
  [INI] XFER bsy=1 req=1 phase=110 cnt=6 atn=1
  [TGT1] MSG_OUT atn=1 stb_adv=1 din=03 extra=1     (x4, cnt 5..2)
  [INI] XFER bsy=1 req=1 phase=110 cnt=1 atn=1
  [TGT1] MSG_OUT atn=0 stb_adv=1 din=03 extra=1     <- ATN drops on the last byte
  sc0,1,0: SYNC negotiation error, resetting SCSI bus
  ```

  `phase=110` is `{msg,cd,io}` = MESSAGE OUT. So **every part of the initiator's
  side is correct**: six bytes, and ATN negated before the last one exactly as
  SCSI-2 requires. `msg_extra` - the flag `scsi.v` already sets when a message
  byte arrives with bit 7 clear, i.e. something other than IDENTIFY - is high
  from the second byte on. The target takes all six, sees ATN drop, and goes to
  COMMAND without answering. **That is the whole defect, and it is the target's
  half**, exactly as [23](23-init-divergence.md) reasoned from the IRIS trace.

  The reply has somewhere to come from: `PHASE_MESSAGE_OUT` (which is the SCSI
  MESSAGE **IN** phase, despite the name - every phase name in that file reads
  from the target's side) already drives `msg`/`cd`/`io` = 1/1/1 with a working
  `dout` mux and a `message_sent` handshake, and `wd33c93.sv` already decodes
  MESSAGE IN (`S_XFER_MSG_IN`, `CP_COMPLETE_MSG`). What is missing is a
  MESSAGE REJECT byte and two edges in the phase machine.

  **Read `scsi.v`'s comments before changing that arm**: a MESSAGE REJECT was
  tried once and made things worse, and going to COMMAND unconditionally cost
  the PROM its boot. The difference now is that both effects are ten minutes
  away instead of a Quartus fit.
* **Why the board's failure mode varies between runs.** The simulation is
  deterministic; the board is not, and that is unchanged.

---

## Instrument changes made to get here

Three, all in the harness and its observability, none of them behavioural - the
five baseline runs below reproduce the pre-existing cycle counts exactly.

* **`bus_mem_o` / `bus_hole_o`** out of `sgi_indy.sv`, wired through
  `sim_top.sv`, tagging every traced transaction `ram` / `HOLE` / `dev`. A write
  main memory took and a write dropped because MEMCFG has no bank covering it
  are identical on the old three-signal tap, and only the second is a lost
  store. Needed before the first experiment could be read at all.
* **`--trace-from-pc` now arms `--exc` and `--pc` as well.** A cycle number for
  something that happens 200 million cycles into a boot cannot be known in
  advance, and "the first 200 exceptions of the boot" is timer interrupts.
  This is what made the two traces above one command each.
* **`make -C verilator wholemachine2`** builds the same model into `obj_wm2`.
  Overwriting a running executable fails with `ETXTBSY`, so an instrumentation
  change could not be compiled while a 28-minute boot was running out of
  `obj_wm`; serialising the two cost half an hour every iteration.

### The exception log was lying by one exception

`cpu_cop0.vhd` raises `dbg_exc` on the clock it **accepts** an exception and
writes `EPC` on the clock **after** (`if (exception = '1') then COP0_14_EPC <=
nextEPC_1`). Sampled on the pulse, `epc=` was therefore the **previous**
exception's - a plausible-looking address that belongs to something else, which
is the worst kind of instrument. `Cause` and `BadVAddr` do settle with the
pulse. The harness now latches those on the pulse and emits the line one clock
later, with an `EPC` that belongs to it.

The traces quoted above were taken with the old binary, so their `epc=` fields
still read one exception late - which is *why* the store's line shows
`epc=7fc09ae8`: that is the value the fetch-side exception wrote, and it is
precisely the point.

---

## Reproducing

Baselines, all measured on 2026-09-01 and all exact:

| run | configuration | cycles to `PANIC: init died` |
|---|---|---|
| A | `--no-dcache` | 215,149,699 |
| C | `--no-dcache`, + `--exc --pc` | 215,149,699 |
| E | `--no-dcache`, + `--ramdump` | 215,149,699 |
| D | caches on | 242,603,699 |

Three independent no-dcache runs across two separately built binaries agree to
the cycle, and the caches-on figure matches
[23-init-divergence.md](23-init-divergence.md). The model is deterministic and
A/Bs against it are trustworthy.

```sh
make -C verilator wholemachine
./verilator/obj_wm/Vsim_top \
    --prom boot.rom --no-gfx --ram-mb 64 \
    --disk 1=/path/to/SGIIndy53.img \
    --type-on "Option?" "1\r" --stop-on "init died" \
    --max-cycles 3000000000 \
    --trace-from-pc 0x7fc073b8 --trace-count 500 \
    --exc --exc-count 200 --pc --pc-count 500
```

`--disk` (not `--disk-rw`) keeps guest writes in memory, so a run cannot damage
the image. Add `--no-dcache` for the second configuration. Run it in WSL
`Ubuntu-24.04`; Verilator 5.020 is only there.

**If you touch any CPU VHDL, regenerate `rtl/cpu/generated/r4300_wrap.v` before
believing a Verilator result** - it is gitignored, Quartus never reads it, and a
stale copy fails with `PINNOTFOUND` on nine `dbg_*` pins long after you have
stopped suspecting it. The script needs GHDL's llvm shim, and it is checked out
with CRLF endings on Windows, so it needs a de-CRLF'd copy *inside* `tools/`
(it derives `$ROOT` from `$BASH_SOURCE`):

```sh
mkdir -p /tmp/llvmshim
ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1 /tmp/llvmshim/libLLVM-18.so.18.1
export LD_LIBRARY_PATH=/tmp/llvmshim
sed 's/\r$//' tools/gen_r4300_verilog.sh > tools/.gen_r4300_verilog.unix.sh
chmod +x tools/.gen_r4300_verilog.unix.sh && tools/.gen_r4300_verilog.unix.sh
```
