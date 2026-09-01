# Work item: finish the TLB/EPC fix and validate it on hardware

Paste everything below the line as the opening message of a fresh session. This
follows [25-lost-store-tlb-order.md](25-lost-store-tlb-order.md), which found
and proved the defect. **The analysis is finished and is not in doubt. What is
not finished is the fix: four attempts, each disproved by measurement, and the
fifth is in flight.**

---

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly - do not create branches in this repository.** The reference emulator
IRIS is the sibling checkout `C:\Temp\mistercore\iris`.

## The job

**The lost store that kills IRIX is a CPU exception-priority defect, fully
traced. Make the fix work, then validate it on the board more than once.**

Read [25-lost-store-tlb-order.md](25-lost-store-tlb-order.md) first - all of
it. Everything below assumes it.

## What is proven, and must not be re-derived

`/sbin/init` stores its process-table pointer in the **delay slot of a `jal`**:

```
0x7fc073b4: jal 0x7fc09ae8
0x7fc073b8: sw  v0, 0x3ef0(at)      ; *(0x7fc43ef0) = calloc(303,20)
```

The store's page and the branch target's page miss the TLB together. The
**fetch-side** fault is accepted first, sets `EXL`, and commits
`EPC = 0x7fc09ae8`. Fifty-three cycles later the store's own fault arrives,
finds `EXL` set, and the R4000 nested-exception rule - correctly implemented -
discards its `EPC`. The kernel maps the page, returns to the branch target, and
**the delay slot never runs again**.

Three independent measurements, all reproducible:

* The kernel's own trap frame: `BadVAddr = 0x7fc43ef0`, `Cause = 0x0c` (TLBS,
  `BD` clear), **`EPC = 0x7fc09ae8`**, and `v0 = 0x7fc447a8` - byte-for-byte
  IRIS's allocator result.
* `0x7fc09ae8` is `lui v0,0x7fc4`. It touches no memory, so it **cannot**
  produce that `BadVAddr`. The `EPC` is definitively wrong.
* `--epc` shows the store's fault at cycle 207884339 writing **nothing**, while
  `nextEPC_1` holds the correct `0x7fc073b4` continuously from cycle 236 to 340.

**The correct value is never lost. It is only ever discarded by the `EXL`
guard.** The fix has nothing to compute.

### The ordering is structural, not a race

```vhdl
EXETLBDataAccess <= ... when (... and stall = 0 and ...) else '0';
```

An instruction in EXECUTE **cannot request its translation while the pipeline
is stalled**, and the stall in question is the *fetch* stall from the
instruction-TLB walk. Measured (`dbg_cop0`):

```
[207884236] COP0 TLBINSTR              stall=01  nextEPC_1=..73b4
[207884286] COP0 excStage1 EXL         stall=01     <- fetch fault taken
[207884288] COP0 EXL dReq              stall=04     <- store only NOW asks
[207884339] COP0 exc savedEXL EXL      stall=04     <- store's fault, EXL set
```

So the fetch-side fault is **always** first. Any fix conditioned on "is a data
request outstanding when the fetch faults?" is dead on arrival - that was
attempt 3.

## Four attempts, each disproved by measurement

| # | change | result | what it ruled out |
|---|---|---|---|
| 1 | reorder cop0's TLB arbiter (data before instruction) | **bit-identical boot**, panic at the same cycle | the two arms are never both eligible at a decision; the arbiter never gets a choice |
| 2 | `if (excSavedEXL = '0' or exceptionStage1 = '1')` | did not fire | `exceptionStage1` is cleared at cycle 287, ~50 cycles before the store's fault |
| 3 | `excFetchProvisional`, set only when a data request is outstanding | condition always false | `dReq` does not exist until cycle 288, two cycles *after* the fetch fault |
| 4 | flag set unconditionally, cleared on first instruction commit | flag set at 286, **cleared at 287** | a commit-based clear fires ~70 cycles before the handler exists |

**Attempt 5 is what is in the tree now** and was still building when the
session ended:

```vhdl
if (excSavedEXL = '0' or (excFetchProvisional = '1' and
                          nextEPC_1(31) = '0')) then
   COP0_14_EPC               <= nextEPC_1;
   COP0_13_CAUSE_branchDelay <= isDelaySlot_1;
end if;
```

with the flag **set on every fetch-side TLB exception and cleared only on
`eret`**. Two independent guards:

* the flag - "this `EXL` was set by a fetch-side fault we have not returned
  from"; `eret` provably cannot fire between cycles 286 and 340, because only
  user code is in the pipeline there;
* `nextEPC_1(31) = '0'` - the exception being reported belongs to a **user-mode
  instruction**. A handler runs in kernel space, so its own nested exception
  always has a kernel `nextEPC_1` and can never take this path. This makes a
  stale flag harmless on its own, which is what protects
  `cpu-tests: excep/exl_preserves_epc`.

**Check the result first.** Two runs were launched; the logs are
`N1-nodcache.log` and `N2-dcache.log` in the session scratchpad, and the
verdict is one line:

```
grep -E 'armed|EPC <-|EXC |PANIC' N1-nodcache.log | head
```

**Success is `EPC <- 7fc073b4` immediately after the exception at cycle
207884339.** Anything else, read the `COP0` lines - they name the signal that
betrayed the model.

## The instruments, which are new and are why this is now tractable

All committed, all validated against five runs that reproduced the pre-existing
cycle counts exactly.

* **`--epc`** - one line per change of `COP0 EPC`. `dbg_exc_epc` is driven
  continuously, so this needed no RTL. It is what showed the store's fault
  writing nothing.
* **`--cop0`** - one line per change of a twelve-signal cop0 status word
  (`exception`, `exceptionStage1`, `excSavedEXL`, `EXL`, the provisional flag,
  both TLB request/stall pairs, the arbiter state, commit, `stall`,
  `nextEPC_1`). This is what named the mechanism after three failed guesses.
  **Use it before changing anything in `cpu_cop0.vhd`.**
* **`--trace-from-pc` now arms `--exc`, `--epc` and `--pc` too.** A cycle number
  200 million cycles into a boot cannot be known in advance.
* **`bus_mem_o` / `bus_hole_o`** - the bus trace now says *who answered*
  (`ram` / `HOLE` / `dev`). A write main memory took and a write dropped into a
  MEMCFG hole were previously identical on the tap.
* **`--exc` was lying by one exception** and is fixed: cop0 raises `dbg_exc` on
  the clock it accepts and writes `EPC` on the clock after.
* **`make -C verilator wholemachine2`** builds the same model into `obj_wm2`,
  so instrumentation can be compiled while a 28-minute boot is running
  (`WM_DEFS=+define+MSG_DEBUG` passes extra defines).
* **`make -C verilator cpuonly` works again** - it had rotted against the CPU's
  newer `dbg_*` pins and needed `-Wno-PINMISSING`. It is the fast CPU
  regression gate: 364 checks in seconds, and it passes with the fix in.

### Baselines, exact and repeatable

| configuration | cycles to `PANIC: init died` |
|---|---|
| `--no-dcache` | **215,149,699** |
| caches on | **242,603,699** |

Reproduced across five runs and three separately built binaries. The model is
deterministic; A/Bs against it are trustworthy.

```sh
make -C verilator wholemachine
./verilator/obj_wm/Vsim_top --prom boot.rom --no-gfx --ram-mb 64 \
    --disk 1=/mnt/c/Temp/mistercore/iris/SGIIndy53-master.img \
    --type-on "Option?" "1\r" --stop-on "init died" --max-cycles 900000000 \
    --no-dcache --trace-from-pc 0x7fc073b8 --trace-count 40 \
    --exc --exc-count 40 --epc --epc-count 40 --cop0 --cop0-count 300
```

Run it in WSL `Ubuntu-24.04`. `--disk` (not `--disk-rw`) keeps guest writes in
memory, so a run cannot damage the image.

## Then: validate on the board, which has NOT been done

Nothing in this work has run on hardware yet. The board is reachable and the
deploy path is intact (checked: SSH to `192.168.99.94` works,
`_Unstable/SGIIndy.rbf` and `games/SGIIndy/` are in place).

1. `bash scripts/build.sh --log build-tlbfix.log` - ~20 min, detached (see
   `local-toolchain`; `Start-Process` does not work, use `Invoke-CimMethod`).
   The last clean fit was 38,659 registers with one **−83 ps** path on the HDMI
   PLL clock - watch that it does not get worse.
2. `bash scripts/hwcheck.sh --tag tlbfix1 --wait 300` - deploys and screenshots.
3. **Repeat at least three times.** docs/24 is emphatic: the board's failure
   mode varies between runs - `init died` on one, SCSI `READ(10)` timeouts on
   the next, same bitstream and same disk. One board run proves nothing.
4. Read the crash dump off the disk afterwards with
   `python tools/misterdeploy/efsread.py IMAGE cat /var/adm/crash/analysis.0`.

**Set expectations honestly.** This fix should remove the `init died` panic. It
does **not** touch the two other measured defects, and either could be the next
wall:

* **The SCSI target never answers the SDTR negotiation.** Measured this session
  with `+define+MSG_DEBUG`: the initiator's half is entirely correct - six
  bytes, ATN negated before the last one exactly as SCSI-2 requires, and
  `scsi.v`'s own `msg_extra` flag high from the second byte. The target takes
  all six and goes to COMMAND **without presenting MESSAGE IN**. A drafted
  patch is in the session scratchpad as `scsi_reject.py`, deliberately not
  applied. `PHASE_MESSAGE_OUT` (which *is* SCSI MESSAGE IN, despite the name)
  already drives `msg`/`cd`/`io` = 1/1/1 with a working `dout` mux and a
  `message_sent` handshake, and `wd33c93.sv` already decodes MESSAGE IN. **Read
  `scsi.v`'s comments first** - a MESSAGE REJECT was tried once and made things
  worse, and going to COMMAND unconditionally cost the PROM its boot. Both are
  recorded there. It reproduces in ten minutes.
* **The board sizes memory 4 MB smaller than IRIS and the simulator** (`234` vs
  `303`; 10240 vs 11264 pages). It does **not** reproduce in a model that
  replaces DDR3 and `ram_arb` with `sim_ram.v`, so it lives on the real memory
  path. Read it live with
  `python3 /media/fat/sgidbg/guestmem.py 0x881c5ef8 0x80`.

## Nearly-finished work worth ten minutes

**`tests/tlborder/`** is a bare-metal reproduction of this exact condition -
`jal` to an invalid page with a store to another invalid page in its delay
slot - that would turn a 25-minute IRIX boot into a **one-second** check. The
`.S` assembles and links and the snippet disassembles correctly. It fails at
load:

```
ELF load failed: segment 2 at vaddr 00400000 -> phys 00400000 (232 bytes)
is outside RAM [08000000, 0c000000)
```

`ld` emits a second `PT_LOAD` for the ELF headers at its default text address;
`PHDRS` alone did not suppress it. Untried: `-N` (omagic), or giving the
headers to the text segment with `. = 0x88001000 + SIZEOF_HEADERS;` and
`:text FILEHDR PHDRS`. **cpu-tests cannot host this case at all** - that suite
runs unmapped from KSEG0, so its fetches never miss the TLB, which is exactly
why ten thorough TLB tests never caught this.

## Traps paid for this session

* **`tools/gen_r4300_verilog.sh` fails silently if GHDL cannot run.** The
  Debian `ghdl-llvm` needs a shim
  (`ln -sf /usr/lib/llvm-18/lib/libLLVM.so.18.1 /tmp/llvmshim/libLLVM-18.so.18.1`,
  `LD_LIBRARY_PATH=/tmp/llvmshim`), `/tmp` gets cleared, and the failure shows
  up five minutes later as Verilator reporting "Nothing to be done" - **so the
  model you then measure is the one from before your change.** That cost a full
  verification cycle. The script now checks `ghdl --version` actually runs.
* **Delete a run's log before relaunching.** A waiter grepping for `armed`
  matched the *previous* run's leftover content and reported a result for a
  build that no longer existed. Caught by timestamps. `chain4.sh` now `rm -f`s
  first.
* **`pkill -f Vsim_top` matches its own shell's command line** and kills the
  script issuing it. Use `pkill -x`.
* **Everything is checked out CRLF.** It breaks bash scripts, GNU make and the
  MIPS assembler. Scripts deriving `$ROOT` from `$BASH_SOURCE` also break when
  run from a de-CRLF'd copy elsewhere - `gen_r4300_verilog.sh` and
  `tests/tlborder/build.sh` both have this trap, the latter now honouring an
  inherited `ROOT`.
* **A verilator rebuild that only relinks is a warning sign** - check the
  generated file's timestamp against `cpu_cop0.vhd` before believing a result.
  `chain4.sh` refuses to run on a stale one.
* **`DATACACHEFORCEWEB` stays untried** and is now understood to be a red
  herring: a write-through switch cannot help a store that is never issued.

## What success looks like

`EPC <- 7fc073b4` after the store's fault; `init` survives; the panic is gone
in both simulator configurations; and then the board, boots more than once,
reported honestly - including if it gets further and stops somewhere new.
