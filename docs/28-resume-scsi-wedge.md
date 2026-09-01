# Work item: the SCSI wedge that stops IRIX finishing fsck

Paste everything below the line as the opening message of a fresh session. This
follows [27-multiuser-on-hardware.md](27-multiuser-on-hardware.md), which got
IRIX 5.3 to multiuser on the board, and [25](25-lost-store-tlb-order.md), which
fixed the CPU defect that used to kill `init`.

Written 2026-09-01.

---

You are working on an **SGI Indy (IP24)** core for MiSTer FPGA at
`C:\Temp\mistercore\sgiindy_MiSTer`, branch `main`. **Commit to `main`
directly - do not create branches.** The reference emulator IRIS is the sibling
checkout `C:\Temp\mistercore\iris`.

## The job

**IRIX 5.3 reaches multiuser on the board, but only on a filesystem that does
not need checking. Any unclean shutdown makes the next boot run `fsck`, and
`fsck` wedges the SCSI subsystem permanently. Find it and fix it.**

That makes this the blocker for a usable machine: every reboot dirties the
filesystem, so the working state cannot survive its own reset.

## The failure, exactly

Partway into `fsck` Phase 1 the board stops dead and never recovers:

```
  ** Phase 1 - Check Blocks and Sizes
WARNING: wd93 SCSI Bus=0 ID=1 LUN=0: SCSI cmd=0x28
timeout after 60 sec.  Resetting SCSI bus                  (forever)
dks0d1s0: SCSI driver error: Command timed out
fsck: I/O error       CAN NOT READ: BLK 1006
```

`cmd=0x28` is READ(10). It is always **`BLK 1006`**, on every image tried.

## What is PROVEN, and must not be re-derived

### 1. The core stops asking the HPS for blocks. The ARM side is innocent.

This is the one measurement that matters. The FPGA does not read the disk
image - it raises `sd_rd`/`sd_wr` and MiSTer, on the ARM, does the `read()`.
So MiSTer's own counters are a free readout of whether the core is still
asking. While wedged they are **frozen solid**, and the file offset is pinned
at byte 2,858,496 (LBA 5583):

```sh
bash scripts/diskio.sh --seconds 10
#   VERDICT: FROZEN over 10s - the core has stopped asking the HPS.
```

So the wedge is inside the SCSI RTL. There is no point looking at `hps_io`,
the ARM, MiSTer, or the image contents as the *cause*.

### 2. It is NOT accumulated disk corruption.

The first theory was that the board's image had rotted over days of crashed
runs. It had not. **A pristine image plus exactly one unclean reset wedges
identically, at the same block.** The reproducer is:

> restore the pristine image -> boot (clean, no fsck, reaches multiuser) ->
> reset the board -> boot -> fsck runs -> wedge, in about 5 minutes.

Two reproducer images are kept on the board and must not be deleted:

| file | what it is |
|---|---|
| `/media/fat/games/SGIIndy/SGIIndy53-wedged-fsck.img` | pristine + ONE unclean reset. **Use this one.** |
| `/media/fat/games/SGIIndy/SGIIndy53-dirty-20260901.img` | the older accumulated-damage image |
| `/media/fat/games/SGIIndy/SGIIndy53.img.zip` | the pristine source; `unzip -o -j` restores it in ~4.5 min |

A copy of the first is in WSL at `/home/dani/wedged.img` (2 GB) for simulator
runs.

### 3. A SCSI bus reset DOES reach the target.

This was a live hypothesis and it is dead. `rst` in `scsi.v` is the only thing
that clears `io_rd_d`/`io_wr`/`wr_pending`, and it is driven from
`wd33c93.sv`'s `scsi_rst`, whose timer is loaded **only** by the HPC3 channel's
`chip_reset` - which itself pulses only on the **falling edge** of `ch_reset`
(`hpc3_scsi_dma.sv`: `if (ctrl_reset && !pio_wdata[6])`). It looked fragile.
It is not: the new `SCSI_BUS_RESET` watchdog fires **18 times** in a boot, e.g.

```
SCSI_BUS_RESET ID=1 phase=1 io_rd_d=0 io_wr=0 wr_pending=0 io_ack=0
```

IRIS does the same thing (`hpc3.rs`: falling edge of `SCSI_CTRL_RESET` ->
`wd.power_on()`), so the design is right.

## The mechanism that fits, and the one suspect left

`io_busy` gates the SCSI `REQ` line:

```verilog
assign req = (phase != PHASE_IDLE) && ... && !io_busy && !data_phase_complete && ...
```

and **outside a data phase** `io_busy` is just

```verilog
io_rd_d | io_wr | wr_pending | (io_ack & ~ca_io_active)
```

Anything that leaves one of those four stuck stops the target answering the bus
at all. The COMMAND phase never transfers, every command times out at 60 s,
and - because no data phase is ever reached - **no `sd_rd`/`sd_wr` is raised
either**. That is exactly the frozen-counter signature in (1).

**`io_ack` is the leading suspect, and the reasoning is short:** a bus reset
clears the other three, resets demonstrably happen (3), and the board still
never recovers. `io_ack` is an **input** - `sd_ack` out of `hps_io` - so `rst`
cannot clear it. It is also the only one of the four driven differently
between the board and the simulator, which fits the simulator not reproducing.

If `io_ack` were stuck high, everything follows: `io_busy` is permanently 1,
REQ is suppressed, `io_wr` is held at 0 by `if(io_ack) io_wr <= 1'b0;` so no
flush is ever issued, `io_rd_d` is cleared every cycle for the same reason, and
no reset can help. **This is a hypothesis, not a measurement.**

## Ruled out, with the evidence

| hypothesis | why not |
|---|---|
| write path broken / image read-only | writes land: the image's mtime moves and MiSTer holds the fd `rw` |
| stuck `io_wr` flush surviving a reset | `rst` does clear `io_rd_d`/`io_wr`/`wr_pending` (`scsi.v` ~1868) |
| the bus reset never firing | disproven by measurement - `SCSI_BUS_RESET` fires 18x |
| `mounted` dropping | only clears on an `img_mounted` pulse with `img_blocks == 0`, or CD eject |
| `sd_ack` clock-domain crossing | `hps_io` and `sgi_indy` both run on `clk_sys` - one domain |
| accumulated disk corruption | pristine + one reset reproduces it |
| the simulator reproducing it on the master image | it does not - it sails through the same `fsck` phase |
| IRIS as an oracle | **it cannot help.** Its SCSI model is command-level (`xfer_data`, `pending_status`), with no bit-level REQ/ACK target state to get stuck. This class of bug cannot exist there |

## The instruments

### On the board

* **`scripts/diskio.sh`** - the (1) check, packaged. **Read
  `read_bytes`/`write_bytes`, never `rchar`**: `rchar` climbs at a flat
  ~400 KB/min on an idle board because MiSTer polls its input devices, and
  reading that as progress will tell you a wedged machine is healthy.
* `tools/misterdeploy/ddr3_peek.py` mmaps `/dev/mem` on the ARM and can read
  **the guest's entire main memory** (0x30000000, 64 MB) while wedged -
  including the HPC3 descriptor chain. `guestmem.py` and `efsread.py` sit on
  top of it.
* **`rb-cli`** from the sibling `rusty-backup` checkout, installed at
  `~/AppData/Local/Programs/Rusty Backup/bin/rb-cli`. First-class EFS support -
  `ls`, `get`, `tar`, and an **`fsck` verb**. Outside this repo, which is why
  it is easy to miss.

### In the simulator

`scsi.v` carries five watchdogs, all inside `ifdef SIMULATION` (pure
observability - plusarg-gated `$display`s, no behavioural change). **They are
compiled OUT of the default whole-machine build**, because `V_DEFINE` carries
`+define+SIMULATION=1` but the `wholemachine` targets do not use it:

```sh
make -C verilator wholemachine2 WM_DEFS="+define+SIMULATION=1"
./verilator/obj_wm2/Vsim_top --prom boot.rom --no-gfx --ram-mb 64 \
    --disk 1=/home/dani/wedged.img --type-on "Option?" "1\r" \
    --max-cycles 700000000 --no-dcache +scsi_stall_debug > /tmp/WEDGE.log 2>&1
```

| watchdog | fires when |
|---|---|
| `SCSI_PHASE` | every phase change, with `cmd`/`tlen`/`lba` |
| `SCSI_STALL` | `data_cnt` not advancing for 300k cycles **in a DATA phase** |
| `SCSI_FLUSH_STUCK` | `io_wr` pending while the bus is idle |
| **`SCSI_REQ_STUCK`** | `io_busy` holding REQ down outside a data phase - prints all four terms. **This is the one aimed at this bug** |
| **`SCSI_BUS_RESET`** | the target actually sees a bus reset, with the four terms |

`+tb_debug` traces the **Toolbox pseudo-device**, not the disk - inherited Mac
machinery, not the block-fetch path for a target.

## Traps already paid for

* **The simulator takes ~50-60 minutes to reach `fsck`.** Budget for it.
* **A frozen log is not a wedge.** `fsck` does long stretches of in-memory work
  between reads. Two runs sitting at an identical byte count is *determinism*,
  not a shared hang - this was misread once already. Confirm a run has
  **resumed** (or that a watchdog fired) before concluding anything.
* **Do not line-buffer a long run onto `/mnt/c`.** `stdbuf -oL` onto DrvFs costs
  a write syscall per line and starved a run to 15% CPU. Write to `/tmp`.
* **Shell variables inside `wsl.exe -- bash -lc '...'` are eaten** before they
  arrive, and `/mnt/c/...` paths get mangled without `MSYS_NO_PATHCONV=1`. Put
  the work in a script file.
* `pkill -f Vsim_top` matches its own shell. Use `pkill -x`, or kill by PID.
* Everything is checked out CRLF.

## Where to go next

1. **Finish the simulator run on `/home/dani/wedged.img`.** One was in flight
   when this was written: it reached `fsck` after ~50 minutes, at 1808 phase
   changes and 302 commands, and then went quiet - the log frozen at exactly
   167,541 bytes across three checks while the process kept burning CPU at full
   speed.

   **Do not read that as a reproduction.** `SCSI_REQ_STUCK` was still **0**, and
   that watchdog fires after 200,000 cycles - about 1.6 s of wall clock at this
   model's ~128k cycles/s. Had the target been REQ-suppressed it would have
   fired many minutes earlier. So the simulator was *not* in the state the
   board is in; it was almost certainly doing `fsck`'s in-memory work between
   reads, which is the trap two entries up. Let it run to `--max-cycles` and
   check whether it finishes `fsck` cleanly.

   If it reproduces, `SCSI_REQ_STUCK` names the stuck term outright and the job
   is nearly done.
2. **If it does not reproduce, that is itself the answer**: the trigger is
   board-only, and `io_ack` is the standing explanation. Then instrument the
   board - the cheapest route is a **debug beacon**: have the core write a
   status word (the four `io_busy` terms, `phase`, `sd_rd`/`sd_wr`/`sd_ack`)
   to a fixed DDR3 address, and read it live with `ddr3_peek.py` while wedged.
   That costs one ~30-minute fit and then gives unlimited board visibility.
3. **A defensive fix is worth considering either way.** A target that can be
   parked forever by one stuck input is fragile regardless of what sticks it.
   Qualifying the `io_ack` term of `io_busy`, or timing it out, would make the
   machine recoverable by the bus reset IRIX is already issuing.

## Related, still open

* **Newport pixel DMA** - X starts and draws its cursor, nothing else renders
  (`ng1 pixel dma write timeout`). This is why a multiuser board shows a black
  screen.
* **`wd93 ID=6 cmd=0xc9` timeouts** - the CD-ROM target, vendor opcode.
* **Ethernet** is not implemented; `ec0: no carrier` is expected.
* **Single-user on hardware could not be reached** - the board auto-boots from
  saved NVRAM and never stops at the System Maintenance menu, and three
  attempts to interrupt it (space, Esc, Esc-from-before-the-launch) all failed;
  the serial-console route produced 0 bytes at 9600. Whether `ws_send.py`
  keystrokes reach the guest **at all** is untested and is the first thing to
  establish. In the simulator it is easy:
  `--type-on "Option?" "5\r" --type-on ">>" "single\r"`.
