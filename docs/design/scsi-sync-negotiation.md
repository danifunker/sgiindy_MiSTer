# SCSI synchronous-transfer negotiation, failed in front of every command

Written 2026-09-17, resuming docs/design/cache-fill-latency.md §7's list. Its first item was the disk's
byte path; sizing that from build 38's boot profile turned up a larger item
nobody had listed: a fifth of the boot was IRIX's busy-wait loop, spent by the
disk driver in front of every SCSI command.

| | build 38 (SGIIndy_20260917), same-day re-run | build 39 |
|---|---:|---:|
| launch until the boot goes quiet (from the boot capture) | 103.1 s | **87.5 s** |
| launch to the X login screen (11 s polls) | 102 s | **90 s** |
| `us_delay` before the boot goes quiet | 21.0 s | **1.7 s** |
| `dd` 10 MB off the raw disk | 3.89 s | **2.60 s** |
| `ls -lR /usr/lib/X11` into the Console | 8.16 s | **6.04 s** |
| `xterm -e /bin/true`, cold | 1.12 s | **0.69 s** |
| `bzip2 -9` of /unix | 85.5 s | 83.4 s |

## 1. Where the boot's us_delay went

Build 38's boot capture, launch to 110 s:

| place | seconds |
|---|---:|
| user code | 26.5 |
| `us_delay` | 22.3 |
| idle | 8.7 |
| the PROM | 6.0 |
| `rex3Clear` | 3.2 |

`us_delay` is IRIX's calibrated busy loop (`1000 * n / decinsperloop`
iterations of a two-instruction loop). docs/design/cpu-speed-tlb-icache.md named its callers from a
simulator profile - the WD33C93 driver and Newport's `vdma_wait` - and no VDMA
beat reaches REX3 before X starts at 104 s, so this was the disk driver.

**~7.4 ms of us_delay per SCSI command, in every window.** Beacon word 2
counts the WD33C93's accepted Select-and-Transfers; against each capture's
us_delay seconds:

| build 38 window | commands | us_delay | per command |
|---|---:|---:|---:|
| idle desktop (15 s) | 28 | 0.21 s | 7.5 ms |
| `ls -lR` into the Console | 145 | 1.08 s | 7.4 ms |
| `dd` 10 MB off the raw disk | 158 | 1.18 s | 7.5 ms |
| login | ~686 | 5.09 s | 7.4 ms |

## 2. What the driver waits for

`/unix`'s symbol table (`tools/misterdeploy/ecoffsyms.py`) gives every call
to `us_delay`. The disk driver's are in `wait_scintr` (while CIP, then polling
for INT), `ack_msgin`, `wd93command` (a loop that only runs when dumping a
crash) and `do_trinfo`:

    880b0a94  lbu  $a1, (ASR)
    880b0aa0  andi $t3, $a1, 0x81          # DBR | INT
    880b0aa4  bnez $t3, byte
    880b0aac  jal  us_delay                # us_delay(7), up to 700 times

`do_trinfo(wd, buf, count, timeout)` is the driver's polled TRANSFER INFO:
program the count, issue 0x20, then for every byte wait for DBR and write or
read the DATA register. The PROM carries the same routine byte for byte
(boot.rom 0x9fc1cf8c). Its callers are `_sync_setup` (the synchronous-transfer
negotiation), `do_inquiry`, `handle_extmsgin`, `unex_info` and `wd93abort`.
Two details of it decide everything below:

* **Right after issuing the command it reads and DISCARDS a pending
  interrupt** (0x880b0a5c): at that moment one can only be stale.
* **After the last byte it waits for the interrupt, then resets the SCSI bus
  if ASR bit 5 is set** (0x880b0b44). On the part, bit 5 is "a Level II
  command is executing".

The whole-machine simulator with `WD_TRACE` (a new `+define` in `wd33c93.sv`:
every command, interrupt, register access and bus change outside DMA data
loops) shows the PROM's negotiation with the disk, and later the kernel's,
identical:

    53130025  W COMMAND 06 (SELECT with ATN)     -> INT 11, INT 8E (MESSAGE OUT)
    53130730  count = 6
    53130868  W COMMAND 20 (TRANSFER INFO)
    53130888  INT 1A: six bytes already on the bus, target in COMMAND
    53131008  status read - the driver's discard
              ASR polled, us_delay(7) x 700
    53196426  the target leaves the bus (its COMMAND-phase timeout, scsi.v)
    53216806  W COMMAND 01 (ABORT)
    53231046  W COMMAND 04 (DISCONNECT)         -> INT 85

The model sent the count's worth of whatever the DATA register held - no DBR
at all - and interrupted twenty clocks after the command, before the driver's
loop existed. The driver then waited out every timeout it has and gave up,
leaving the target unnegotiated. `wd93command` asks for a negotiation in
front of any command but INQUIRY while the target's state has none of
"synchronous", "asynchronous" or "negotiation disabled" set, and a
negotiation ending this way sets none of them: on the board, the 7.4 ms of §1
in front of every command. (The simulator's kernel negotiated three times in
303 commands and did not repeat; its route through the failure differs
somewhere the trace does not show. The board's counters leave no doubt, and
the fix removes the failure itself.)

## 3. TRANSFER INFO as the part does it

`rtl/scsi/wd33c93.sv`:

* **One DBR handshake per byte.** On REQ - after `PIO_SETTLE` clocks, so a
  REQ still showing from the last byte is not taken for the next - DBR goes
  up and the sequencer waits in the new `ST_XFER_DBR` for the driver to write
  or read the DATA register; then ACK. A byte from the target is re-latched
  every clock until it is read. MESSAGE OUT drops ATN before its last ACK, as
  before.
* **No CIP.** `wd93cmd_lci` spins on CIP right after writing a command, and
  this command cannot finish until that same driver supplies bytes.
* **ASR bit 5** is `pio_xfer || (bus BSY && !sat_paused && !pio_done)`: set
  while the transfer runs, clear once it has finished - until the next command
  other than NEGATE ACK, or the end of the connection. Everywhere else it is
  the bus, which is what the PROM's abort cleanup needs (docs/31).
* **Completion waits for the target's next phase**: 0x18 | phase, or 0x48 |
  phase if the target moves before the count is spent, or 0x85.
* **The last byte of a MESSAGE IN holds ACK** and interrupts 0x20; NEGATE ACK
  releases it and waits (`ST_NACK`) for 0x85 or 0x88 | phase.
* 0xA0, TRANSFER INFO with the single-byte-transfer bit, is the same command
  with a count of one.

The same stretch of the simulator's PROM boot, fixed:

    53130868  W COMMAND 20   (count 6)
              W DATA 80 01 03 01 32 0a          IDENTIFY, SDTR 200 ns / offset 10
    53131942  INT 1A         -> no answer to SDTR: _sync_setup marks the target
                                asynchronous and closes the connection itself
    53160251  W COMMAND 20   (count 6, COMMAND phase)
              W DATA 12 00 00 00 00 00          INQUIRY, allocation length 0
    53161141  INT 1B -> status byte 00 -> INT 1F -> message byte 00
    53162153  INT 20 (ACK held) -> W COMMAND 03 (NEGATE ACK) -> INT 85
    53162663  W COMMAND 04 -> INT 85

32,600 clocks against 101,000 for the failure, once per target: the kernel's
two negotiations (the disk and the CD-ROM) complete the same way, and no
ABORT appears anywhere in the kernel's window.

Gates: `run-scsi`, `run-scsiwr`, `run-dma`, `run-cdrom` PASS.

## 4. Beacon ver 13: who called it

§1's attribution took counters, a simulator trace and a disassembly. Build 39
carries the answer in the beacon:

* `cpu.vhd` keeps register 31 as the retiring instructions leave it
  (`dbg_ra`) - after a JAL, the return address. A sample inside a leaf routine
  has its caller's call site + 8 there.
* `sgi_indy`'s performance word 10 is `{dbg_ra, the PC last retired}`, beacon
  word 40 (41 words, version 0x0D).
* `prof.py` records word 40 with every sample (`SGIPROF3`); `profan.py` breaks
  the top kernel places down by the routine and offset register 31 points
  into, and labels PROM addresses `(PROM)` rather than the last kernel symbol
  below them.

Build 39's boot, as the report prints it:

    0.9 %  bzero        <- page_zero+0xb4 30%, tlbinit+0x9c 29%, fuexarg+0x274 12%, seg_pte+0x68 8%
    0.9 %  rex3Clear    <- newportInit+0x104 100%
    0.8 %  bcopy        <- page_copy+0x140 53%, copyout+0x34 6%, setuctxt+0x28 3%
    0.5 %  us_delay     <- wd93edtinit+0xa8 41%, initClock+0x64c 12%, initClock+0x370 12%

Word 40 is written 30 beacon slots (1,920 clocks, 38 us) after word 10, so a
sample's two words can straddle a call; for a loop that repeats the same call
for milliseconds, the attribution is the loop's.

## 5. Build 39 on the board

Build 39 = build 38 + §3 + §4, SEED=5: 37,371 ALMs (89 %), 45,848 registers,
483 / 553 M10K; core clock +1.810 ns, **HDMI PLL -0.028 ns** - a measurement
build, not a release. `output_files/sgiindy-b39-seed5.rbf`, md5
`cf6a7720727ffd5228b8f2cca01798e7`.

cpu-tests as the PROM 2415 / 0 (255 tests); diskcheck PASS. A same-day re-run
of build 38 (`perf-b38ctl2`) matched last night's build 38 within noise - fills
18.5 / 20.2 clocks, the display holding the port 70.8 %, X at 102 s - so the
board had not drifted.

| workload | build 38, re-run | build 39 |
|---|---:|---:|
| boot quiet / X login screen | 103.1 s / 102 s | **87.5 s / 90 s** |
| boot: `us_delay` over the 360 s capture | 28.8 s | **1.8 s** |
| login: `us_delay` / idle in the 45 s capture | 4.86 s / 46.0 % | **0 / 55.8 %** |
| `dd` 10 MB raw / `ls -lR` / xterm cold | 3.89 / 8.16 / 1.12 s | **2.60 / 6.04 / 0.69 s** |
| `bzip2 -9` / fork / xterm warm | 85.5 / 3.88 / 0.41 s | 83.4 / 3.85 / 0.41 s |
| perl | 12.0 s | 13.8 s - instruction-cache placement: 18.1 fills per 1000 instructions against 5.2 |

The boot's clocks per instruction rose (1.54 -> 1.64) because 20 s of a
two-instruction cached loop left the average; nothing got slower.

**One notice per boot, and four bus resets.** Both of build 39's boots logged

    NOTICE: wd93 SCSI Bus=0 ID=1: SYNC negotiation error, resetting bus

in the kernel's first second, and the boot window counts four SCSI bus
resets, four channel resets and six Reset commands where build 38 counts
none, none and two. See §6.

## 6. Builds 40 and 41: the COMMAND phase that gave up too early

**Build 40** = build 39 + `claude/fill-comb` (docs/design/cache-fill-latency.md §5: a data line fill's
words reach the cache in the clock they come off the bus) + beacon ver 14,
which splits every DATA-phase clock by whose turn it is: the target's (a byte
to fetch or store behind `scsi.v`, the block cache and the HPS) or the
initiator's (the WD33C93 model, the DMA engine and DDR3). SEED=2: 37,499 ALMs,
core clock +2.075 ns, HDMI +0.136 ns; cpu-tests as the PROM 2415 / 0.

| | build 39 | build 40 | build 41 |
|---|---:|---:|---:|
| boot quiet / X login screen | 87.5 s / 90 s | 84.6 s / 90 s | 86.4 s / 91 s |
| data line fill on the bus | 20.2 clocks | **19.2** | 19.2 |
| `dd` 10 MB raw / `ls -lR` / xterm cold | 2.60 / 6.04 / 0.69 s | 2.84 / 6.19 / 0.69 s | 2.60 / 6.03 / 0.69 s |
| `bzip2 -9` / fork / perl | 83.4 / 3.85 / 13.8 s | 83.6 / 4.26 / 11.8 s | 82.5 / 3.83 / 11.3 s |

The fill-comb clock is there. Build 40's fork (4.26 s) did not repeat on build
41, which carries the same change - noise; perl moves with instruction-cache
placement as it did in §5.

Ver 14's split, build 40: the boot's DATA IN spent 4.50 s waiting on the
initiator and 6.01 s on the target, DATA OUT 0.61 s and 1.71 s; `dd` off the
raw disk 0.86 s and 0.60 s; the login 1.07 s and 1.29 s. Neither side is small:
the byte path costs about as much on the WD33C93's side as on the disk's.

**The notice was `scsi.v`'s COMMAND-phase timeout.** The target let the bus go
when 2^17 clocks (2.6 ms) passed in COMMAND phase without a CDB byte - a bound
sized for the PROM's negotiation while it was broken, when no CDB ever followed
the message. With TRANSFER INFO working, `_sync_setup` gives a target that
does not answer SDTR `wait_scintr(2000)` - two milliseconds of `us_delay` -
marks it asynchronous, and only then sends its polled INQUIRY in the same
connection. On the board that gap is ~105,000-115,000 clocks, and a clock tick
inside it pushes it past 131,072: the target left in the middle of the
INQUIRY. The simulator's `us_delay` is calibrated against simulated time and
waits ~28,000 clocks, so it never showed there; forcing the simulator's
timeout down to 2^14 reproduces the PROM's `sc0,1,0: SYNC negotiation error`
(run-scsi FAIL), and 2^22 passes.

**Build 41** = build 40 + the timeout at 2^22 clocks (84 ms) + ABORT (0x06) and
BUS DEVICE RESET (0x0C) ending the connection, as on a real target: the
drivers' abort sends IDENTIFY + ABORT and resets the bus if BSY is still up
50 ms later, which the short timeout had always pre-empted. SEED=2: 37,565 ALMs
(90 %), 46,119 registers, 483 M10K; core clock +1.774 ns, HDMI +0.237 ns.
cpu-tests 2415 / 0. The notice is gone from SYSLOG, and the boot's `us_delay`
stays at 1.8 s over the 360 s capture.

## 7. One diskcheck in eleven: a file nobody wrote

Build 41's first diskcheck **FAILED**, and not in a way the change explains.
IRIX's own checksums of all four files were right - `libX11.so.1` summed
41170 / 63140, exactly pristine - but when the session was over and the image
was read from the card, `libX11.so.1` on it had changed (md5 `d92a117e...`,
sysv 33586). `/root/unix.copy` was byte-identical to `/unix`. Something wrote
over a file that was only read, and `perfprobe`'s restore erased the evidence
before it could be diffed.

`tests/out/hw/diskcmp.sh TAG RBF` is diskcheck plus a file-by-file compare with
pristine and NO restore in between:

| | verdict |
|---|---|
| build 40 (fill-comb, no `scsi.v` change) | **PASS**, six libraries identical to pristine |
| build 41, repeat | **PASS**, same |

So the fill-comb clock is cleared, and build 41's failure did not repeat: one
failure in eleven diskcheck sessions across builds 32-41. A single 3 MB copy
per session is too small a lever for that, and two candidate explanations had
to go first:

* **The pristine image is not at fault.** A read-only EFS consistency check
  over it (every in-use inode's extents against the free-block bitmap) finds
  no block owned by a file and marked free, and no block with two owners - so
  IRIX cannot have handed `libX11`'s blocks to `unix.copy` as free space.
* **An indirect extent block that changes is not corruption.** IRIX writes a
  file's indirect extent block back from its in-core copy when the inode is
  updated - an `atime` bump from `sum` is enough - and the unused tail of those
  512 bytes carries whatever the kernel's buffer held. The Sep 1 images have
  one; `libc.so.1`'s extents themselves are unchanged in it.

**The instrument.** `tools/misterdeploy/efsdiff.py` (runs on the board)
compares the whole used image with pristine block by block and gives every
differing block an owner in both images. A block belonging to a file whose
inode is identical but for its access time - same size, same extents, same
mtime - and whose data changed anyway is FOREIGN: nothing that went through
the file system wrote it. It also compares each copy with its source, because
a write that went elsewhere leaves the block it was meant for stale.
`scripts/diskstress.sh` drives a session built to provoke one: 16 copies of
`/unix`, each synced, with `ls -lR /usr` reading directories and inodes
underneath - 50 MB of writes against a diskcheck's 3 MB.

Build 41, three stress sessions: **no FOREIGN block anywhere on any of the
three images, and all 48 copies byte-identical to `/unix`** (about 102,000
blocks differ from pristine each time, every one of them owned by a file that
was written or by free space). That is 150 MB of writes against the 3 MB of the
session that failed. The 2026-09-17 evidence therefore says the fault is rare and not particular to build 41 (nothing in the change
touches a data phase; the same disk path has been in place since build 26), and
it stays an open item rather than a release blocker - with a tool that will
name the blocks and their data the next time it happens.

A trap for the next session: the MiSTer has **492 MB of RAM and no swap**. The
first `efsdiff.py` kept an owner for every allocated block - 1.9 million
entries per image - and the board stopped answering ssh for ten minutes while
it thrashed (ping and the Remote HTTP service answered throughout; the kernel
was fine, only new processes could not be started). Owners are resolved for
the differing blocks alone now, and a run takes about three minutes with
300 MB still free.
