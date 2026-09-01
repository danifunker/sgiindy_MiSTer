# Where IRIX's initialisation diverges: `init`'s table allocation returns NULL

**Work item: [22-iris-init-diff-prompt.md](22-iris-init-diff-prompt.md). Status of
this document: the divergence is named and the failing instruction is identified
down to the opcode. The step that makes the pointer NULL is not yet proven.**

Written 2026-09-01. Nothing in `rtl/` was changed to produce it.

---

## The short version

Two divergences were found. They are independent findings and only one of them
is the thing that kills `init`.

**1. The proximate cause of the panic, named exactly.** `/sbin/init` faults at
its own instruction `0x7fc07ca4`, which is `sw zero, 12(v0)` with `v0 == 0`.
`v0` is a table pointer that lives in the first word of `init`'s `.bss`
(`0x7fc43ef0`). There is exactly one instruction in the whole of `init` that
writes that pointer, and it stores the return value of an allocator called with
`(count, 20)`. **So the allocation returned NULL, `init` did not check it, and
it walked off a null pointer.** `init` blocks SIGSEGV, so the kernel could not
deliver the signal, killed the process to break the trap loop, and panicked
because the dead process was pid 1. That is `why = 2` (CLD_KILLED),
`what = 0x9` (SIGKILL), exactly as printed.

**2. A real, separate device-level divergence.** Immediately before that, the
board's kernel logged

```
<5>NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus
```

**IRIS booting the same operating system from the same image never emits any
"negotiation" message at all** (measured: zero matches in both the guest console
log and the emulator's own log). Our SCSI target does not implement SDTR, and
[`rtl/scsi/scsi.v`](../rtl/scsi/scsi.v) already says in its own comments that
this is expected to hurt IRIX specifically. So this *is* a genuine divergence in
device behaviour, it *is* on the initialisation path, and it *is* visible to the
guest.

**What is not established is that (2) causes (1).** They are both true; the
causal link is not proven and this document does not claim it. See
[Not yet proven](#not-yet-proven).

---

## How `init` dies, instruction by instruction

The board wrote its own post-mortem to its own disk and it was still there. The
crash report (`/var/adm/crash/analysis.0`, generated on the machine at
`Mon Aug 31 20:48:47 2026`) contains the trap frame:

```
<4>WARNING: Process [init] 1 generated trap, but has signal 11 held or ignored
Process has been killed to prevent infinite loop

STACK TRACE FOR PROCESS 1 (init, PID=1):
 0 syncreboot[../os/printf.c: 904, 0x88033a38]
 1 icmn_err[../os/printf.c: 282, 0x88031488]
 2 cmn_err[../os/printf.c: 108, 0x88031044]
 3 exit[../os/exit.c: 112, 0x8805ad94]
 4 psig[../os/sig.c: 1394, 0x88035b0c]
 5 trapend[../os/trap.c: 1116, 0x8803bdc0]
 6 trap[../os/trap.c: 1022, 0x8803bbe4]
 7 VEC_trap[../ml/locore.s: 4045, 0x88010f18]
       r2/v0:0000000000000000   r4/a0:000000007fc43ef0   r6/a2:0000000000000014
       r1/at:0000000000000001  r24/t8:0000000000001248  r25/t9:0000000000001248
      r28/gp:000000007fc48b70  r29/sp:000000007fffa5a8  r31/ra:000000007fc20fc4
      EPC=7fc07ca4, CAUSE=8, SR=ff13, BADVADDR=0
```

`signal 11` is SIGSEGV. So this is not a mysterious kill: `init` segfaulted,
had SIGSEGV blocked, and the kernel killed it rather than loop forever
re-running the faulting instruction.

### The address space is `init`'s own

`/sbin/init` on this disk is `ELF32 MSB EXEC`, **statically linked** (three
program headers, no `PT_INTERP`), and linked at a fixed high address:

```
init: type=2 mach=8 entry=0x7fc051f0
   LOAD vaddr=0x7fc00000 filesz=0x36000 memsz=0x36000 off=0x0 flags=5   (r-x)
   LOAD vaddr=0x7fc40000 filesz=0x2000  memsz=0x47a0  off=0x36000 flags=6 (rw-)
sections: .rodata@0x7fc000c0 .text@0x7fc051f0 .init@0x7fc35fb0
          .data@0x7fc40000 .sdata@0x7fc40b90 .sbss@0x7fc419c0 .bss@0x7fc43ef0
```

`EPC = 0x7fc07ca4` is therefore inside `init`'s own `.text`, at file offset
`0x7ca4`. **`init` is statically linked, so `rld` is not involved in this at
all** - which rules the runtime loader, and with it the "rld patches
relocations and jumps in with no flush" story, out of *this* failure. `rld` is
linked at `0x0fb60000` and `libc.so.1` at `0x5ff20000`; neither is anywhere
near the faulting PC.

### The faulting instruction and the loop around it

Disassembling `init` at that offset:

```
0x7fc07c74: 24a50000  addiu a1, a1, 0        ; a1 = 0x7fc40000  (.data)
0x7fc07c78: 8caf0000  lw    t7, 0(a1)        ; t7 = element count
0x7fc07c7c: 24060014  addiu a2, zero, 20     ; a2 = 20           <- a2 in dump
0x7fc07c80: 01e60019  multu t7, a2           ; LO = count * 20
0x7fc07c84: 3c047fc4  lui   a0, 0x7fc4
0x7fc07c88: 24843ef0  addiu a0, a0, 0x3ef0   ; a0 = 0x7fc43ef0   <- a0 in dump
0x7fc07c8c: 8c820000  lw    v0, 0(a0)        ; v0 = *(.bss[0]) = the table ptr
0x7fc07c90: 0000c012  mflo  t8               ; t8 = count * 20   <- t8 in dump
0x7fc07c94: 0302c821  addu  t9, t8, v0       ; t9 = end          <- t9 in dump
0x7fc07c98: 0059082b  sltu  at, v0, t9       ; at = 1            <- at in dump
0x7fc07c9c: 1020000c  beq   at, zero, +12    ; skip loop if size == 0
0x7fc07ca0: 00000000  nop
0x7fc07ca4: ac40000c  sw    zero, 12(v0)     ; *** FAULTS: v0 == 0 ***
0x7fc07ca8: a4400008  sh    zero, 8(v0)
0x7fc07cac: 8ca80000  lw    t0, 0(a0)
0x7fc07cb0: 8c8a0000  lw    t2, 0(a0)
0x7fc07cb4: 01060019  multu t0, a2
0x7fc07cb8: 24420014  addiu v0, v0, 20       ; next 20-byte record
0x7fc07cbc: 00004812  mflo  t1
0x7fc07cc0: 012a5821  addu  t3, t1, t2
0x7fc07cc4: 004b082b  sltu  at, v0, t3
0x7fc07cc8: 1420fff6  bne   at, zero, -10    ; loop back to 0x7fc07ca4
```

**This reconstruction is not a guess.** Five registers in the crash dump are
reproduced exactly by the instructions above: `a0 = 0x7fc43ef0` is built by the
`lui`/`addiu` pair at `0x7fc07c84`, `a2 = 0x14`, `at = 1` from the `sltu`,
and `t8 = t9 = 0x1248` from `t8 + v0` with `v0 = 0`. It is a loop that
zero-initialises an array of **`0x1248 / 20 = 234` records of 20 bytes each**,
through a base pointer taken from the first word of `.bss`, and that pointer is
zero.

There is no NULL check. `at = (v0 <u v0 + size)` is an overflow guard, and with
`v0 = 0` and a non-zero size it is *true*, so the loop is entered and stores to
address `0xc`.

*(One inconsistency, recorded rather than explained away: a store fault should
report `ExcCode` TLBS and `BadVAddr = 0xc`, and the report prints `CAUSE=8`
(`ExcCode` = 2, TLBL) with `BADVADDR=0`. The five-register agreement above is
much stronger evidence than the frame's `CAUSE`/`BadVAddr` fields, which icrash
may not be filling from the original trap.)*

### Where the pointer comes from - exactly one place

Scanning all 216 KB of `init`'s text for instructions that form or use
`0x7fc43ef0` gives nine references, of which **exactly one is a store**:

```
  0x7fc073b8  ac223ef0  sw    v0, 0x3ef0(at)
```

and its context is unambiguous:

```
0x7fc073a0: lui   a0, 0x7fc4
0x7fc073a4: lw    a0, 0(a0)        ; a0 = *(0x7fc40000) = element count
0x7fc073a8: jal   0x7fc10b40       ; ptr = alloc(count, 20)      <-- calloc-shaped
0x7fc073ac: addiu a1, zero, 0x14   ; a1 = 20            (delay slot)
0x7fc073b0: lui   at, 0x7fc4
0x7fc073b4: jal   0x7fc09ae8
0x7fc073b8: sw    v0, 0x3ef0(at)   ; *(0x7fc43ef0) = ptr (delay slot)
```

A two-argument allocator called with `(nelem, size)` whose result is stored
straight into the table pointer. **The allocation returned NULL.**

The element count is itself read from a file a few instructions earlier:

```
0x7fc07378: jal   0x7fc123a0       ; read(fd, sp+0x7c, 128)
0x7fc0737c: addiu a2, zero, 0x80
0x7fc07384: bne   v0, at, ...      ; only if it read exactly 128 bytes
0x7fc0738c: lw    t6, 0x9c(sp)     ; count = word at offset 0x20 of that record
0x7fc07394: sw    t6, 0(at)        ; *(0x7fc40000) = count
```

The count compiled into the binary is **200** (`0xc8` at file offset `0x36000`);
the value in the crashing process was **234**. So the count had been replaced
from that 128-byte record before the allocation ran.

---

## The IRIS side

IRIS was built and run on **the same disk image, the same PROM file, and the
same memory size** as the board, so the two sides are comparable:

| | board | IRIS |
|---|---|---|
| PROM | `boot.rom`, md5 `11bb4acd…` | `prom.bin`, **the same file**, and IRIS's own embedded PROM is the same revision (`PROM0709101011`) |
| disk | `games/SGIIndy/SGIIndy53.img` | a copy of `SGIIndy53.img.zip` from beside it on the same SD card |
| RAM | `MEM_MB = 64` (`rtl/sgi/sgi_indy.sv:41`) | `banks = [64, 0, 0, 0]` |

Reproduce with `iris-diff.toml` and `scripts/indy_boot.py` on the IRIS branch
`irix-init-trace`.

**Result 1 - the faulting instruction is never executed.** With a PC breakpoint
armed on `0x7fc07ca4` from before the CPU was started, IRIS booted through
`fsck`, root remount, `init`, and the whole automatic kernel reconfiguration
(`lboot`) **without the breakpoint ever firing.** So a healthy `init` does not
reach that loop at all on this boot path; the board is taking a code path IRIS
does not.

**Result 2 - IRIS never reports a SCSI negotiation problem.** Zero matches for
"negotiation" in either the guest console log or IRIS's own log, across the
whole boot.

---

## The SCSI divergence, and why it was already predicted

The board's kernel putbuf, in order, with the negotiation error as the *second*
thing the kernel ever printed:

```
pb 0: ysAD parity is enabled.
pb 1: <5>NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus
pb 2:
pb 3: <4>WARNING: time of day clock behind file system time--resetting time
pb 4: <4>WARNING: clock gained 11158 days
pb 5: <4>WARNING: CHECK AND RESET THE DATE!
pb 6: <4>WARNING: Process [init] 1 generated trap, but has signal 11 held or ignored
pb 7: Process has been killed to prevent infinite loop
pb 9: <0>PANIC: init died (why = 2, what = 0x9)
```

`rtl/scsi/scsi.v` already describes this failure mode in its own comments,
written before this evidence existed:

> THAT READING IS TRUE OF THE PROM AND FALSE OF IRIX, which sends IDENTIFY+SDTR
> and then a CDB in one connection, so this is very probably why a drive never
> finishes attaching under IRIX.

and

> A real disk would also answer MESSAGE REJECT to a message it does not
> implement. […] IRIS does not send one either - it swallows the message and
> reports COMMAND phase - so this target does the same.

The current code resolves the PROM-versus-IRIX ambiguity with `cmd_timeout`:
go to COMMAND after MESSAGE OUT and wait, because IRIX's CDB arrives in
microseconds and the PROM's never does. **The board's log shows that this is
still not enough for IRIX's own driver**: `wd93` ran its synchronous-transfer
negotiation, did not get an answer it accepted, and reset the bus. IRIS never
has to answer that question, because its WD33C93A model *is* the target - there
is no bus-level target, no REQ/ACK, no phase machine - which is exactly the
limitation [22-iris-init-diff-prompt.md](22-iris-init-diff-prompt.md) warns
about, and it is why IRIS cannot be the oracle for this particular divergence.

---

## Not yet proven

* **That the SCSI bus reset causes the NULL allocation.** The negotiation error
  is putbuf entry 1, i.e. very early - plausibly during the driver's initial
  probe, long before `init` runs. A bus reset aborts outstanding I/O and IRIX
  retries; the boot demonstrably continues (root is fsck'd and mounted after
  it). A plausible chain exists - a reset corrupts or truncates a read, `init`
  reads a bad 128-byte record, gets a bad count, and the allocation fails - but
  it is a hypothesis, not a measurement.
* **Whether the allocation failed or never ran.** The faulting loop is in the
  function at `0x7fc07c4c`; the allocation is in a *different* function
  containing `0x7fc073b8`. `init` walking the table before the function that
  allocates it has run would produce the identical crash. Distinguishing these
  needs the board to be caught in the act.
* **Determinism.** [21-icache-bug.md](21-icache-bug.md) records two runs of one
  bitstream failing in completely different places, and the same disk's
  `/var/adm/SYSLOG` shows boots of this image that reached full multiuser
  userland, `inetd`, `sendmail` and an X session. So `init died` is **not** the
  only outcome this core produces, and no conclusion here should be drawn from
  a single run.

## The obvious next experiment

Everything above says where to put the probe, and it is a small one:

1. On the board, arrange to catch `init` at `0x7fc073b8` - the single store -
   and record `v0`. That answers "did the allocator return NULL, or did this
   code never run" in one measurement.
2. If it returned NULL, walk into the allocator at `0x7fc10b40` and find
   whether the `brk`/`sbrk` under it failed, or whether the count fed to it
   (`*(0x7fc40000)`, 234 on the board against 200 compiled in) was already
   wrong - which would point straight back at the 128-byte record read at
   `0x7fc07378`, and therefore at the disk path.
3. Independently of `init`: make the SCSI target answer SDTR the way a real
   disk does, and check whether `wd93` stops resetting the bus. That is worth
   doing on its own merits whatever it does to this panic - **but note the two
   measured traps in `scsi.v`'s comments before touching it**, because both
   obvious changes there have already cost the PROM its boot once each.

## Tooling this produced

Three things that did not exist before and make the next pass cheaper:

* **`tools/misterdeploy/efsread.py`** - reads files straight out of an EFS
  filesystem in a disk image on the host, with nothing emulated: `ls`, `cat`,
  `get`, `find`. Everything in this document about the crash came out of the
  board's own disk through it. The existing `efspeek.py` could not do this: it
  decodes an EFS extent as `{bn:24, ex:8}{offset:24, nbytes:8}` when the real
  layout is `{magic:8, bn:24}{length:8, offset:24}`, and it reads the inode's
  extents at offset 20 when they are at `0x20`, so it reads a zero-length
  directory block and stops.
* **`make -C verilator wholemachine`** - the whole-machine Verilator model
  **now builds on this box**, which
  [22-iris-init-diff-prompt.md](22-iris-init-diff-prompt.md) and
  `local-toolchain` both record as impossible. It needed a stale generated file
  regenerated (`rtl/cpu/generated/r4300_wrap.v` was missing the nine `dbg_*`
  ports `sgi_indy.sv` connects, so elaboration failed with `PINNOTFOUND` long
  before the V3Gate crash everyone remembered) plus three flags found by
  building it: `-fno-gate`, `-O0` (every higher level dies in an internal fault
  with no location, in `np_rex3.sv`), and `--unroll-count 2048` for the
  128-entry reset loop at `sgi_hpc3.sv:339`. It runs at ~175k cycles/s, which
  is too slow for a whole IRIX boot but ample for the PROM and early kernel.
* **`scripts/indy_boot.py`** (on the IRIS branch `irix-init-trace`) - drives an
  IRIS run over plain TCP (monitor 8888, serial console 8881), so it works on
  Windows without the `--ci` Unix socket, and deliberately without `--ci`'s
  "speed-favoring fidelity shortcuts".

## Reproducing

```sh
# host-side forensics on any image copy, no emulator needed
python tools/misterdeploy/efsread.py IMAGE cat /var/adm/crash/analysis.0
python tools/misterdeploy/efsread.py IMAGE cat /var/adm/SYSLOG
python tools/misterdeploy/efsread.py IMAGE get /sbin/init ./init

# the IRIS oracle (in ../iris, branch irix-init-trace)
python scripts/indy_boot.py --config iris-diff.toml --launch --boot --wait-login
```
