# IRIX 5.3 reaches multiuser on hardware

**Follows [25-lost-store-tlb-order.md](25-lost-store-tlb-order.md), which fixed
the lost store that killed `init`.** Written 2026-09-01.

**Status: the board runs IRIX 5.3 at run level 2.** The desktop does not draw,
and there is one unexplained SCSI defect that is no longer being triggered.
Both are written up below rather than left implicit.

---

## What the board does now

With the TLB/EPC fix (`1a7299a`) and a **clean disk image**, the board boots
IRIX 5.3 all the way to multiuser. Evidence, strongest first:

* **`syslogd` is appending to `/var/adm/SYSLOG` live** - 30,427 -> 30,639 ->
  30,851 bytes over a few minutes, in syslogd's own `1A:IRIS unix:` format.
  IRIX starts syslogd from `/etc/rc2.d`; it does **not** run in single-user.
  That is the proof that rc2 ran.
* The guest clock advances on its own: `18:48:03 -> 18:48:56 -> 18:49:32`.
* Sustained disk traffic - 111 MB read / 57 MB written and climbing, against
  19 MB / 4.9 MB when it was wedged.
* The frame buffer is cleared to a marker before every launch
  (`scripts/hwcheck.sh`), and the marker is gone, so the X cursor on screen was
  drawn by *this* boot.
* `/var/adm/utmpx` contains `run-level 2`. **Weak on its own** - utmpx records
  are updated in place, so that string cannot be dated, and `wtmpx` shows no
  new boot record. It is listed for completeness, not relied on.

`ec0: no carrier: check Ethernet cable` every ~45 s is the only recurring
complaint, and it is expected: there is no Ethernet in this core.

## The disk image mattered, and it was a confound

The board and the simulator were **not running the same experiment**. The
simulator boots `iris/SGIIndy53-master.img`; the board's `SGIIndy53.img` had
been written by every crashed run since 2026-08-30, so its filesystem was dirty
and IRIX ran `fsck` on it at every boot. On a clean image `fsck` is skipped and
the boot proceeds.

The pristine image was restored on the board from the `SGIIndy53.img.zip` that
was already sitting beside it. **The dirty image is preserved, not deleted**,
as `/media/fat/games/SGIIndy/SGIIndy53-dirty-20260901.img` - it is the only
known reproducer for the defect below.

Note the zip is a **backup of a working system**, not a vendor image: its
`/var/adm/SYSLOG` carries entries from 2026-08-31 18:40 that belong to an
earlier session, including `sendmail` starting. Those lines are *not* evidence
about this core's boot and must not be read as such. They are still useful as a
forecast of the next walls - see below.

## The SCSI wedge: real, measured, and STILL OPEN

On the dirty image the board wedges partway into `fsck` and never recovers:

```
  ** Phase 1 - Check Blocks and Sizes
WARNING: wd93 SCSI Bus=0 ID=1 LUN=0: SCSI cmd=0x28
timeout after 60 sec.  Resetting SCSI bus                  (forever)
dks0d1s0: SCSI driver error: Command timed out
fsck: I/O error       CAN NOT READ: BLK 1006
```

**It is NOT about accumulated corruption, and that was worth finding out.**
The first reading here was that the board's image had rotted over days of
crashed runs. It has not: a **pristine image plus exactly one unclean reset**
wedges just the same, in the same place, at the **same block - `BLK 1006`**.
So the trigger is a specific read pattern `fsck` Phase 1 issues, and it is
reproducible on demand:

> restore the pristine image -> boot (clean, no fsck, reaches multiuser) ->
> reset the board -> boot -> fsck runs -> wedge.

That image is kept on the board as
`/media/fat/games/SGIIndy/SGIIndy53-wedged-fsck.img`. It is a far better
reproducer than the old `SGIIndy53-dirty-20260901.img` beside it, because it is
one reset away from a known-good filesystem rather than an unknown pile of
damage.

**The one hard measurement, and it is the useful one:** while wedged, the
MiSTer process's I/O counters are frozen solid across 5 s - `rchar`, `wchar`,
`read_bytes`, `write_bytes` all identical - and its file position is pinned at
byte 2,858,496 (LBA 5583).

`scripts/diskio.sh` is that check, packaged:

```sh
bash scripts/diskio.sh --seconds 10
#   VERDICT: FROZEN over 10s - the core has stopped asking the HPS.
```

**Read `read_bytes`/`write_bytes`, not `rchar`.** `rchar` climbs at a flat
~400 KB/min on an idle board - that is MiSTer polling its input devices, not
disk - and reading it as progress will tell you a wedged machine is healthy.

So **the FPGA stops asking the HPS for blocks entirely**. `sd_rd` is never
asserted again. The ARM side is innocent; the wedge is inside the SCSI RTL.
It is permanent, and IRIX's repeated bus resets do not clear it.

### What has been ruled out

Each of these was checked and is **not** the cause:

| hypothesis | why not |
|---|---|
| the write path is broken / image read-only | writes land - the image's mtime moves, and MiSTer holds the fd `rw` |
| a stuck `io_wr` flush surviving a bus reset | `rst` **does** clear `io_rd_d`/`io_wr`/`wr_pending` (`scsi.v` ~1868), and `scsi.v`'s `rst` is wired to `wd33c93.sv`'s `scsi_rst` via `b_rst` |
| `mounted` dropping | it only clears on an `img_mounted` pulse with `img_blocks == 0`, or a CD eject; neither happens |
| a clock-domain miss on `sd_ack` | `hps_io` and `sgi_indy` both run on `clk_sys` - one domain |
| **the simulator reproducing it** | **it does not.** Both whole-machine runs pass the same point on the master image and carry on through `fsck` |

The simulator not reproducing it is the important negative: it means the
trigger is something the board has and the model does not - real DDR3 behind
`ram_arb` (the sim swaps in `sim_ram.v`), `hps_io`'s real timing, or the disk
content itself.

**A trap worth recording:** the two sim runs froze at an identical byte count
for ~12 minutes and were briefly read here as a reproduction. They were not -
`fsck` does long stretches of in-memory work between reads, and two runs
sitting at the same place is determinism, not a shared hang. Check that a sim
has *resumed* before concluding it is wedged.

### Instruments that exist for the next attempt

`scsi.v` already carries purpose-built watchdogs, all behind
`ifdef SIMULATION` (pure observability - two blocks, both plusarg-gated
`$display`s, no behavioural change). **They are compiled OUT of the whole-machine
build**: `V_DEFINE` carries `+define+SIMULATION=1` but the `wholemachine`
targets do not use it. Build them in with:

```sh
make -C verilator wholemachine2 WM_DEFS="+define+SIMULATION=1"
./verilator/obj_wm2/Vsim_top ... +scsi_stall_debug
```

* `SCSI_PHASE` - every phase change with `cmd`/`tlen`/`lba`
* `SCSI_STALL` - `data_cnt` not advancing for 300k cycles, with the full
  handshake (`req`/`ack`/`io_busy`/`io_rd`/`io_ack`/`data_phase_complete`)
* `SCSI_FLUSH_STUCK` - `io_wr` pending while the bus is idle; **not**
  plusarg-gated. Its own comment calls it the candidate mechanism for
  "forensically-observed LOST write commands"
* `+tb_debug` traces the Toolbox pseudo-device, **not** the disk - it is
  inherited Mac-core machinery and is not the block-fetch path for a target

**Do not line-buffer a long run onto `/mnt/c`.** `stdbuf -oL` onto DrvFs costs a
write syscall per line and starved a boot to 15% CPU. Write to the WSL
filesystem instead.

## The next walls, named

* **Newport pixel DMA.** X starts and draws its cursor; nothing else renders.
  The backup's own log already names it:
  `WARNING: ng1 pixel dma write timeout` / `ng1: pixel dma timeout!`. This is
  the reason a multiuser system shows a black screen.
* **`wd93 ID=6 cmd=0xc9` timeouts** - the CD-ROM target, a vendor-specific
  opcode, 10 s timeouts. Also from the backup log.
* **Ethernet** is not implemented; `ec0: no carrier` is expected.

## Reading the guest's filesystem

Two tools, and the second is better:

```sh
# on the MiSTer - no copy needed, reads the image in place
python3 /media/fat/sgidbg/efsread.py /media/fat/games/SGIIndy/SGIIndy53.img \
        cat /var/adm/SYSLOG
```

`rb-cli` (from the sibling `rusty-backup` checkout, installed at
`~/AppData/Local/Programs/Rusty Backup/bin/rb-cli`) has first-class EFS
support - `ls`, `get`, `tar`, `chmod`, `chown`, and an **`fsck` verb**. It is
the right instrument for asking whether the dirty image above is genuinely
damaged, which would turn the wedge into a data-corruption story rather than a
hang. It is outside this repo, which is why it went unnoticed here for a while.

## Booting single-user

The PROM's Command Monitor has a **`single`** command - see
[03-boot-prom.md](03-boot-prom.md), which lists the 27-command dispatch table.
From the boot menu choose **5** (Enter Command Monitor), then `single`.

In the **simulator** this is easy and is the recommended route: `--type-on` is
repeatable, and the PROM stops at `Option?` on its own there, so

```sh
--type-on "Option?" "5\r" --type-on ">>" "single\r"
```

**On hardware it did NOT work in this session, and the reason matters.** The
board **auto-boots**: its NVRAM carries a saved boot configuration, so the PROM
never stops at the System Maintenance menu the way the simulator does. Three
attempts to interrupt it failed:

* tapping **space** across the window (`ws_send.py kbdRaw:57`) - the machine
  booted straight through;
* tapping **Esc** (`kbdRaw:1`, which is the key the SGI prompt actually asks
  for) over t+8..t+30 s - likewise;
* tapping Esc from **before** `launch_unstable_core.py` was even called
  (it only returns once the core is already up, so the window has passed) -
  likewise.

So either the keystrokes are not reaching the guest at all, or there is no
prompt to interrupt because autoboot is configured. **That is untested and is
the first thing to establish**, e.g. by typing `hinv` at a `>>` prompt reached
some other way, per [08-resume-prompt.md](08-resume-prompt.md).

The **serial console** route was tried too and produced **0 bytes**:
`scripts/setopt.sh gfx=none` (which is what moves the console off the frame
buffer and onto the SCC), relaunch, then `scripts/console.sh --baud 9600`.
Nothing came out at 9600. 19200 was not tried, and the PROM does switch rate
partway through POST, so that is the obvious next thing rather than a
conclusion.

The clean fix is probably **NVRAM**: `setenv OSLoadOptions single` persists
(see below), so it only has to be typed once - but typing it once still needs
the Command Monitor, which is the same problem. Blanking the NVRAM so the PROM
falls back to the menu (the state the simulator is in) would break that
circle.

`setenv` persists in NVRAM ([17-nvram-persistence.md](17-nvram-persistence.md)),
so `OSLoadOptions` can be set once instead of typed every boot.

Single-user is worth having for its own sake: the *text* console renders
correctly on this core - the IRIX boot messages and `fsck` output were all
legible on screen - so single-user gives a usable IRIX shell on real hardware
without depending on the Newport path that X needs.
