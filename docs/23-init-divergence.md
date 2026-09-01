# Where IRIX's initialisation diverges: `init`'s table allocation returns NULL

**Work item: [22-iris-init-diff-prompt.md](22-iris-init-diff-prompt.md). Status:
the divergence is named to a single instruction and a single register, and both
sides were measured at that instruction. What makes the register differ is not
yet proven.**

Written 2026-09-01. Nothing in `rtl/` was changed to produce it.

---

## The short version

**The divergence is one instruction and one register.**

`/sbin/init` stores the result of its first heap allocation at
**`0x7fc073b8`** (`sw v0, 0x3ef0(at)`), into the first word of its own `.bss`.
Stopping both machines on that exact instruction:

| | `v0` at `0x7fc073b8` | outcome |
|---|---|---|
| **IRIS** | `0x7fc447a8` | boots to full multiuser |
| **this core** | `0` | `init` walks off the null pointer and the kernel panics |

`init` reads that pointer back at `0x7fc07ca4` (`sw zero, 12(v0)`), faults on
the null, and because it blocks SIGSEGV the kernel kills it to break the trap
loop and panics on the death of pid 1 - `why = 2` (CLD_KILLED), `what = 0x9`
(SIGKILL), exactly as printed on the screen.

**The allocation was for 4680 bytes, by pid 1, at the start of the boot, on a
machine with tens of megabytes free.** It should not have been able to fail, and
nothing else had failed - `init` had just read kernel memory through
`/dev/kmem` successfully. The leading hypothesis is therefore **not** "malloc
failed" but **a lost store**: `.bss` starts as zero, so a write to that word
that never lands is indistinguishable from an allocator returning NULL. That
would also explain why turning every cache off changes nothing, which is the
fact [21-icache-bug.md](21-icache-bug.md) could not account for.

**Two further divergences, both measured, neither proven to be the cause:**

**A. The kernel sizes the machine differently.** Same kernel binary, same disk:
`init` reads a machine-derived count of **303** from `/dev/kmem` under IRIS and
**234** on the board, and the board's own dump header says `physical mem: 48
megabytes` where the core is built for `MEM_MB = 64`. This happens *before*
`init` runs.

**B. SCSI synchronous-transfer negotiation fails.** The board's kernel logged

```
<5>NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus
```

**IRIS booting the same operating system from the same image never emits any
"negotiation" message at all** (measured: zero matches in both the guest console
log and the emulator's own log). Our SCSI target does not implement SDTR, and
[`rtl/scsi/scsi.v`](../rtl/scsi/scsi.v) already says in its own comments that
this is expected to hurt IRIX specifically.

**Neither A nor B is shown to cause the NULL.** All three are true; the causal
links are not proven and this document does not claim them. See
[Not yet proven](#not-yet-proven).

**But B is worse than "a NOTICE at boot", and the second board run tonight
showed it.** `tests/out/hw/initdiff2.png`, 2026-09-01 00:38, same bitstream,
same disk, is not the `init` panic at all - it is the SCSI path failing
outright:

```
NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus
...
The root file system, /dev/dsk/dks0d1s0, is being checked automatically.
  fsck: checking /dev/dsk/dks0d1s0
  ** Phase 1 - Check Blocks and Sizes
WARNING: wd93 SCSI Bus=0 ID=1 LUN=0: SCSI cmd=0x28
timeout after 60 sec.  Resetting SCSI bus            (x4)
dks0d1s0: SCSI driver error: Command timed out
fsck: I/O error
  CAN NOT READ: BLK 1006
  CONTINUE?  yes
WARNING: wd93 SCSI Bus=0 ID=1 LUN=0: SCSI cmd=0x28
timeout after 60 sec.  Resetting SCSI bus            (and on, and on)
```

`cmd=0x28` is READ(10). **Ordinary disk reads are timing out after a full 60
seconds and the driver is resetting the bus over and over.** So the SCSI target
does not merely decline to negotiate: under IRIX it sometimes stops answering
commands altogether.

**That also settles the determinism question, and not in the direction
`docs/22` assumed.** Two runs tonight, one bitstream, one disk: run 1 was
`init died`, run 2 was SCSI command timeouts in `fsck`. `init died` is *not*
what this core does every time, and the common factor across both runs is the
SCSI path, not `init`.

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
straight into the table pointer.

### The allocation definitely ran, and it asked for 4680 bytes

The whole enclosing function, from its prologue, settles the "did it even run"
question:

```
0x7fc072fc: addiu sp, sp, -0x648
0x7fc0732c: addiu a0, zero, 8
0x7fc07330: jal   0x7fc12320       ; sysmp-shaped: kernel address of `var`
0x7fc07334: addiu a1, zero, 2
0x7fc0733c: beq   v0, at, 0x7fc073a0   ; failed?  -> jump PAST, to the alloc
0x7fc07344: lui   a0, 0x7fc0
0x7fc07348: addiu a0, a0, 0x620    -> "/dev/kmem"
0x7fc0734c: jal   0x7fc0aa10       ; open("/dev/kmem", 0)
0x7fc07354: bltz  v0, 0x7fc073a0   ; failed?  -> jump PAST, to the alloc
0x7fc07364: jal   0x7fc12370       ; lseek(fd, kernel_addr, 0)
0x7fc0736c: bne   v0, s0, 0x7fc07398   ; failed? -> skip the read
0x7fc07378: jal   0x7fc123a0       ; read(fd, sp+0x7c, 128)
0x7fc0737c: addiu a2, zero, 0x80
0x7fc07384: bne   v0, at, 0x7fc07398   ; not 128? -> skip
0x7fc0738c: lw    t6, 0x9c(sp)     ; count = word at +0x20 of the kernel record
0x7fc07394: sw    t6, 0(at)        ; *(0x7fc40000) = count
0x7fc07398: jal   0x7fc0f790       ; close(fd)
0x7fc073a0: <the allocation, above>     <-- every path above lands here
```

`init` is reading the kernel's process-table size straight out of `/dev/kmem`.
**Every early exit branches *forward* to `0x7fc073a0`, the allocation itself.**
There is no path through this function that skips it. So "the allocation never
ran" is ruled out: it ran, and it returned NULL.

It also tells us the `/dev/kmem` path *succeeded* on the board. The count
compiled into the binary is **200** (`0xc8` at file offset `0x36000`); the value
in the crashing process was **234**. 234 can only have come from the kernel
record, so `sysmp`, `open`, `lseek` and a 128-byte `read` of kernel memory all
worked moments before the allocation did not.

### And that makes "out of memory" very hard to believe

`calloc(234, 20)` is **4680 bytes**. This is `init`, pid 1, at the very start of
the boot, on a machine whose own dump header says it has 48 MB. A 4.6 KB
allocation does not fail on such a machine for want of memory, and nothing else
had failed - the process had just read kernel memory successfully.

So the interesting possibilities are narrower than "malloc failed":

* **The store was lost.** `0x7fc073b8` writes the pointer into `init`'s `.bss`;
  `0x7fc07c8c` reads it back later. `.bss` starts as zero, so *a dropped write
  to that word is indistinguishable from an allocator that returned NULL* - and
  it produces exactly this crash. This is the hypothesis that fits a core whose
  memory path is not yet proven, and it is the one to test first.
* The allocator's own bookkeeping was corrupted, so it took a failure path.
* `brk`/`sbrk` returned an error for some reason other than exhaustion.

Note what the first of these would mean for
[21-icache-bug.md](21-icache-bug.md): a lost *store* is not an instruction-cache
problem and would not be fixed by turning the caches off, which is exactly the
observed behaviour.

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

**Result 3 - the same instruction, side by side.** Booting the pristine image
with a PC breakpoint armed on `0x7fc073b8` - *the* store of the allocator's
return value - from before the CPU was started, IRIS stops there with:

```
PC: 0x000000007fc073b8
v0  ($02): 0x000000007fc447a8     <- the allocation's return value
a0  ($04): 0x000000007fc447a8
gp  ($28): 0x000000007fc48b70     <- same gp as the board's crash frame
CP0 Status: 0x0000ff11 (K:U IE)   <- user mode, as expected

> m 0x7fc40000 2
0x000000007fc40000: 0x0000012f     <- the element count: 303
> m 0x7fc447a8 4
0x000000007fc447a8: 0x00000000     <- freshly zeroed, as calloc promises
```

**`v0 = 0x7fc447a8` on IRIS where the board had `v0 = 0`.** That is the
divergence, at one named instruction, in one register. `0x7fc447a8` is eight
bytes past the end of `init`'s `.bss` (`0x7fc447a0`) - the very start of the
heap, plus a malloc header - exactly where the first allocation in a fresh
process belongs.

**A second divergence falls out of the same stop: the element count.** IRIS's
`init` reads **303**; the board's read **234**. Both come from the same field
(offset `0x20`) of the same kernel `var` struct, read out of `/dev/kmem`, from
the same kernel binary on the same disk:

```
> m 0xffffffff881c5ef8 32          (the kernel address init lseek'd to)
0xffffffff881c5ef8: 0x000001fd
0xffffffff881c5f18: 0x0000012f      <- +0x20: 303, what init uses
0xffffffff881c5f30: 0x00002c00
```

That field is machine-sized in IRIX, so the same struct was read off the board
directly - it lives at a KSEG0 address, which is just physical memory, so
`tools/misterdeploy/guestmem.py` can read it from the ARM with the machine up:

```
$ python3 guestmem.py 0x881c5ef8 0x80          # on the board
  881c5ef8  00 00 01 97 ...                    # +0x00: 407
  881c5f18  00 00 00 ea 88 23 d3 70 ...        # +0x20: 234
  881c5f28  00 00 00 20 00 00 00 1f 00 00 28 00
  881c5f38  00 00 04 00 ...                    # +0x38: 0x2800 = 10240
  881c5f68  ... 00 00 02 9c                    # +0x78: 668
```

Side by side, same kernel binary, same disk, same PROM:

| offset | board | IRIS |
|---|---:|---:|
| `+0x00` | 407 | 509 |
| `+0x20` (what `init` uses) | **234** | **303** |
| `+0x30` | 32 | 32 |
| `+0x34` | 31 | 31 |
| `+0x38` | 10240 | 11264 |
| `+0x40` | 1024 | 1024 |
| `+0x78` | 668 | 806 |

**Every machine-scaled field is smaller on the board and every fixed constant
matches.** `+0x38` reads like a page count: 10240 pages is 40 MB against IRIS's
11264 pages = 44 MB, a difference of exactly **1024 pages = 4 MB**.

Two things make this solid rather than suggestive. It is **cross-run
confirmed**: 234 appears both in the 2026-08-31 crash dump and in this live
read of a different boot on 2026-09-01. And it happens **before `init` runs at
all**, in the kernel's own sizing.

**So the two machines disagree about how much memory they have, by 4 MB, at
kernel initialisation.** That is a first-order divergence in its own right and
worth chasing independently of the NULL - not least because a kernel with a
wrong idea of which pages exist is one plausible way for a store to a freshly
allocated heap page to go nowhere.

**Result 4 - IRIS reaches full multiuser on this image.** The oracle run got
all the way through `lboot`'s automatic reconfiguration to `inetd`, `sendmail`,
`timed` and `prngd`, read back out of the running image with `efsread.py`:

```
Aug 31 21:16:48 5E:IRIS lboot: Automatically reconfiguring the operating system
Aug 31 21:17:22 5E:IRIS lboot: Reboot to start using the reconfigured kernel
Aug 31 21:17:26 5B:IRIS sendmail: starting
Aug 31 21:17:30 5D:IRIS timed[171]: This machine is master
Aug 31 21:17:41 5D:IRIS prngd[617]: prngd 0.9.29 started up for user root
Aug 31 21:18:00 3B:IRIS xdm[760]: Server for display :0 terminated unexpectedly: 1
```

`init` did not fault; the only failure is `xdm`, which is expected because
`--headless` fits no Newport. Note that **no login prompt appears on the serial
line**: the PROM's `console` variable in a fresh NVRAM selects the graphics
head, so `getty`'s prompt goes to a console that headless IRIS does not have.
The machine is up regardless - `SYSLOG` is how you see it, not the console.

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
* **~~Whether the allocation failed or never ran.~~ Resolved: it ran.** The
  faulting loop is in the function at `0x7fc07c4c` and the allocation is in a
  different function, so "`init` walked the table before the allocator ever
  ran" was a live alternative. It is ruled out by the count. The value in the
  crashing process was **234**; the value compiled into the binary is **200**;
  and 234 can only have been written by the `/dev/kmem` block that sits
  *inside* the allocating function, a few instructions above the allocation
  itself. So that function ran, past the read - and since every branch in it
  goes forward to the allocation, the allocation ran too.
* **Why the allocation returned NULL** - lost store, corrupted allocator state,
  or a genuine `brk` failure. This is the open question, and experiment 1 below
  settles it.
* **Determinism.** The panic itself reproduces: a fresh run on the board on
  2026-09-01 at 00:21 produced the identical message, and this time completed
  the dump (`tests/out/hw/initdiff1.png`):

  ```
  PANIC: init died (why = 2, what = 0x9)
  Dumping to dev 0x2000011 at block 0, space: 0x27de pages
  Dumping unmapped memory from page 0x0 to page 0x295..........
  Dumping kernel pages....
  Dump complete.
  [Press reset to restart the machine.]
  ```

  That is two independent occurrences of the panic (2026-08-31 and
  2026-09-01 00:21). **But the very next run of the same bitstream on the same
  disk did something else entirely** - SCSI READ(10) timeouts in `fsck`,
  `tests/out/hw/initdiff2.png` - so `docs/22`'s "dies in the same place every
  time" does not hold, and [21-icache-bug.md](21-icache-bug.md)'s warning
  stands. The register-level trap frame quoted above comes from the 2026-08-31
  dump only; treat anything finer than "init died" as single-run until a second
  dump agrees.

  What *is* confirmed across runs is the `var` struct: 234 in the 2026-08-31
  crash dump and 234 again in a live read on 2026-09-01, and the SYNC
  negotiation NOTICE, which appears in the 2026-08-31 putbuf and on screen in
  the 2026-09-01 run.
  (The disk's `/var/adm/SYSLOG` *does* contain boots of this image that reached
  full multiuser userland - `inetd`, `sendmail`, `timed`, `prngd` - but those
  entries **cannot be attributed to the board**: a headless IRIS run of the
  same image produces a byte-for-byte similar block, `xdm` failing on
  `Display :0` included, because headless IRIS has no Newport either. Do not
  read them as the core succeeding.)

## The obvious next experiments

Everything above says where to put the probe, and the probes are small.

1. **Decide between "lost store" and "allocator really failed."** They are
   distinguishable without a debugger on the board: the allocator's return value
   is in `v0` at `0x7fc073b8` and it is *also* still in `v0` for the two
   instructions after it. Under IRIS the answer is `0x7fc447a8`, eight bytes
   past `.bss`; the same address will be handed out on the board if `brk`
   worked. So read `0x7fc43ef0` **and** the word at `0x7fc447a8-8` out of the
   board's memory: a heap that exists with a header in it, behind a `.bss` slot
   that is still zero, is a lost store and nothing else.
   `tools/misterdeploy/guestmem.py` reads guest memory from the ARM while the
   machine is up, and after the panic the machine sits at
   `[Press reset to restart the machine.]` with its memory intact - which is a
   far better moment to read it than during the boot.
2. **Chase divergence A on its own.** `physical mem: 48 megabytes` against
   `MEM_MB = 64` is a discrepancy that needs no `init` to investigate: it is
   settled by comparing MEMCFG0/MEMCFG1 after the PROM's memory sizing between
   the board and IRIS. **The whole-machine Verilator model now builds** (see
   below) and reaches the PROM's memory sizing in seconds, so this one does not
   even need the board.
3. **Treat the SCSI target as the top-priority defect, not a footnote.** Run 2
   is the argument: READ(10) timing out after 60 seconds with repeated bus
   resets is not a cosmetic negotiation complaint, it is the disk not working.
   Fix the SDTR answer on its own merits, and find why a command sometimes
   never completes - **but read the two measured traps in `scsi.v`'s comments
   first**, because both obvious changes there have already cost the PROM its
   boot once each. The whole-machine Verilator model is now available for this
   and `rtl/scsi/sgi_scsi.sv` also builds standalone with `-fno-gate`
   (see `docs/22` and the toolchain notes), which is the right unit for a target-side question -
   IRIS cannot answer it, having no bus-level target at all.

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
