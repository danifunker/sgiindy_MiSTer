# Installing IRIX 5.3

This core runs SGI's own boot PROM, so IRIX goes onto it the way it went onto
a real Indy: from the IRIX CD, with the PROM's *Install System Software*. The
difference is that the disk and the CD are image files on the MiSTer's SD
card, mounted from the OSD.

Everything below was done on a DE10-Nano with the release in `releases/`
(SGIIndy_20260918) and the IRIX 5.3 CD image described next, on 2026-09-18.
Allow about an hour and a half: a few minutes to partition the disk and start
the installer, about an hour for `inst` to copy the software, and the rest for
its post-install steps.

## What you need

- **The IRIX 5.3 CD as an ISO image.** The procedure here was tested with
  *IRIX 5.3 with XFS* (the CD's `RELEASE.info` reads "Silicon Graphics Software
  Release 5.3 1725920"), a 536 MB image. Any IRIX 5.3 CD that boots an Indy
  should work the same way. The core needs a plain image of the CD's data
  (`.iso`, 2048-byte sectors); the core does not read MAME's `.chd` format, so
  a CD kept as a `.chd` has to be extracted back to a plain image first.
- **An empty disk image** for the system disk. **2 GB** is what this was
  tested with, and leaves plenty of room after the standard selection for
  users and more software. On a Linux or macOS machine:

  ```sh
  dd if=/dev/zero of=irix53.img bs=1M count=2048
  ```

  or on the MiSTer itself (over ssh, about three minutes on the SD card):

  ```sh
  dd if=/dev/zero of=/media/fat/games/SGIIndy/irix53.img bs=1M count=2048
  ```

Put both files in `/media/fat/games/SGIIndy/`, next to `boot.rom`.

## The core's SCSI IDs

| OSD slot | SCSI ID | what goes there | IRIX name |
|---|---|---|---|
| **SCSI ID1** | 1 | the system disk - IRIX installs onto it and boots from it | `dks0d1` |
| **SCSI ID2** | 2 | an optional second disk | `dks0d2` |
| **SCSI ID6 CD** | 6 | the CD-ROM drive | `dks0d6` |

In the PROM's own notation the same devices are `dksc(0,1,N)` and
`dksc(0,6,N)`, where N is the partition: 8 is a disk's volume header, 7 the
CD's filesystem.

The PROM boots from SCSI ID 1 by default, and those defaults are what the core
always starts with (it does not keep the PROM's settings across a reload), so
**always use ID 1 for the system disk.**

## 1. Mount the disk and the CD

1. Load the core. The PROM starts, finds nothing to boot on the empty disk and
   says so:

   ```
   Cannot load /sash.
   No default device and path in environment.
   Unable to boot; press any key to continue:
   ```

   (With no disk mounted at all you only get the last line.)
2. Open the OSD (F12) and choose **SCSI ID1** -> your empty `irix53.img`, and
   **SCSI ID6 CD** -> the IRIX ISO. The slots are remembered from then on.
3. Choose **Memory: 64MB** while you are there - the most the core offers,
   and what this procedure was tested with.
4. **Reset** (from the OSD) so the machine starts with both images present,
   and press a key at the message above. You get the **System Maintenance
   Menu**: *Start System*, *Install System Software*, *Run Diagnostics*,
   *Recover System*, *Enter Command Monitor*, *Select Keyboard Layout*.

The menu answers to the number keys (1-6) as well as the mouse.

## 2. Partition the empty disk with fx

A new disk has no volume header and no partitions, and the installer needs
both. `fx`, SGI's disk utility, is on the CD.

1. Choose **Enter Command Monitor** (5). At the `>>` prompt type:

   ```
   boot -f dksc(0,6,8)sashARCS dksc(0,6,7)stand/fx.ARCS
   ```

   That loads the standalone shell (`sashARCS`, for the Indy's ARCS PROM) from
   the CD's volume header, and `fx` from the CD's filesystem. It takes about
   half a minute.
2. `fx` asks:

   ```
   Do you require extended mode with all options available? (no)
   ```

   Answer **`yes`** - the default read-only mode cannot write a new label.
3. It asks for the disk: `"device-name" = (dksc)`, `ctlr# = (0)`,
   `drive# = (1)`. **Press Enter three times**; the defaults are exactly the
   disk at SCSI ID 1. `fx` opens it, reports `volume header not valid` and
   `Scsi drive type == MiSTer VIRTUAL DISK1`, and creates a default label by
   itself.
4. At the `fx>` prompt, repartition it as a single root disk:

   ```
   fx> r
   fx/repartition> ro
   fx/repartition/rootdrive: type of data partition = (xfs) efs
   ... Continue? yes
   ```

   `rootdrive` makes one root filesystem the size of the disk (partition 0)
   plus a swap partition (1); the default layout gives root only 25 MB, which
   IRIX 5.3 does not fit in. **EFS** is the traditional IRIX filesystem and the
   one this project's disk tools read; the CD also offers XFS, but this guide
   was tested with EFS.
5. Leave `fx`: type `..` (back to the main menu) and then `exit`. You are back
   at the System Maintenance Menu.

## 3. Install

1. Choose **Install System Software** (2). The dialog shows *Local CD-ROM*
   selected and lists **Local SCSI CD-ROM drive 6**. Press Enter (*Install*).
2. *Insert the installation CD-ROM now.* It is already in: press Enter
   (*Continue*).
3. The PROM copies the installation program (the miniroot) from the CD to the
   disk's swap partition and boots it. Within a minute you see `IRIX Release
   5.3`, a few lines about hardware the Indy does not have (`xpi0: not an FDDI
   board`, `gtr0: missing` - both harmless), and:

   ```
   No valid file system found on: /dev/dsk/dks0d1s0
   Make new file system on /dev/dsk/dks0d1s0 [yes/no/sh/help]: yes
   Are you sure? [y/n] (n): y
   Do you want an EFS or an XFS filesystem? [efs/xfs]: efs
   ```

   Answer as shown (match the type you chose in `fx`). `mkfs` takes about a
   minute.
4. `inst` starts with the CD already selected:

   ```
   Default distribution to install from: /CDROM/dist
   Inst>
   ```

   A fresh install has the standard selection pre-chosen and no conflicts
   to resolve. Type **`go`**. `inst` checks dependencies and space (a few
   minutes) and then installs, printing a percentage as it goes through the
   subsystems. That takes about an hour.
5. **Known issue: at about 79 % `inst` stops with a checksum error** on one
   file, `/usr/share/data/sounds/prosonus/sfx/alarm_clock.aiff` in
   `dmedia_tools.data`, and offers an Error/Interrupt Menu. This is a bug in
   the core, not in your CD image - see *Known bug* in the
   [README](../README.md). The file is one sound effect. Type **`continue`**
   and the install carries on.
6. At 100 % `inst` removes orphaned directories and runs its exit commands
   (about eight minutes), checks dependencies again and reports `Errors
   occurred during the installation - check log` - that is the one file
   above. Other CDs could be installed now with `from`; type **`quit`**.
7. `inst` then runs `rqs` over the installed programs ("Invoking rqs(1) on
   necessary dynamic ELF objects"), which is slow on this CPU - leave it -
   and finally asks whether to restart the system. Answer **`yes`**.

## 4. First boot

The machine restarts into the PROM, which boots the new system from SCSI ID 1
on its own. On a new installation IRIX reconfigures its kernel on the first
boot before it comes up; after that you get the graphical login, where `root`
logs in with no password. Set a root password, and shut down properly before
leaving the core (see the tips below).

The test run this guide was written from was stopped during `rqs`, so the
first boot of a CD-installed system has not yet been watched on the core.

## Using an existing installation instead

Any raw image of an Indy system disk with IRIX 5.3 on it works: mount it at
**SCSI ID1** and start the core. That includes a disk installed under an
emulator (MAME's `indy_4610`, or IRIS) - convert a MAME hard-disk `.chd` to a
raw image first with

```sh
chdman extractraw -i indy.chd -o irix53.img
```

and dumps of real Indy disks.

## Tips

- **Keep a copy of the freshly installed image.** It is the fastest way back
  from anything that goes wrong.
- **Shut IRIX down before you reset or load another core** (*System > Shut
  Down*, or `init 0`), and wait for the PROM menu. IRIX keeps filesystem
  changes in memory.
- More software from the same CD, or from other IRIX 5.3 CDs, installs later
  from a root shell: mount the CD image in the ID6 slot and run `inst -f
  /CDROM/dist`.
