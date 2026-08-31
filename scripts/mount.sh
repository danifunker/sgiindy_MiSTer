#!/usr/bin/env bash
#
# mount.sh [--disk1 PATH] [--disk2 PATH] [--cd PATH] [--no-launch]
#
# Attach SCSI images to the core and launch it, without touching the OSD.
#
# THE MOUNT IS SAVED, NOT SCRIPTED, AND THAT IS THE WHOLE DESIGN. The CONF_STR
# slots in sgiindy.sv are `SC1`/`SC2`/`SC3` rather than `S1`/`S2`/`S3`, and the
# C makes the framework keep them: it writes a chosen image's path to
# /media/fat/config/<core>.s<n> (Main_MiSTer menu.cpp:2782) and mounts it again
# from there at EVERY core start (user_io.cpp:977-1006), with no OSD
# interaction, the same way boot.rom arrives at index 0. So this script writes
# those files and then starts the core normally. Nothing has to re-attach
# anything afterwards, and a reload from the OSD, a reset or a power cycle all
# come up with the same disk in the machine.
#
# WHY NOT THE OSD. The screenshot API does not capture it, so a blind keystroke
# sequence into the OSD cannot be verified - a miscounted row mounts the wrong
# file, or nothing, and looks identical to success. That is the same reason
# scripts/setopt.sh writes the CFG file directly instead of driving the menu.
#
# WHY NOT AN MGL EITHER, WHICH IS WHAT THIS USED TO DO. An MGL names the core
# and its images in one file and loads them through /dev/MiSTer_cmd, which
# works, but it is a one-shot: the images are attached for that launch and gone
# on the next. That made every measurement depend on remembering to launch the
# right way, and it is not how anyone would use the core by hand.
#
# THE FORMAT IS A FIXED 1024-BYTE RECORD, not a text file. FileSaveConfig writes
# the whole of menu.cpp's `char selPath[1024]`, so the path goes in
# NUL-terminated and zero-padded to that length. An all-zero record is an empty
# slot, which is how `--disk1 ""` detaches one.
#
# THE PATHS MUST BE ABSOLUTE. A relative path attaches nothing and reports
# nothing - the core comes up, the boot looks ordinary, and there is no disk.
#
# HOW TO TELL IT WORKED, since /tmp/ACTIVEGAME stays empty for disk slots and is
# not a mount record: the boot screen changes. With no disk the PROM prints only
# "Unable to boot; press any key to continue:". With one it says what it found
# on it first - "Cannot load /sash" on a blank disk, or
# "Boot file not found on device: scsi(0)disk(1)rdisk(0)partition(8)/sash" once
# the disk has a volume header. Either line is the disk answering.
#
#   bash scripts/mount.sh --disk1 "/media/fat/games/SGIIndy/indy1GB.img" \
#                         --cd    "/media/fat/games/SGIIndy/IRIX 5.3 XFS.iso"
#   bash scripts/mount.sh --disk1 ""        # detach the disk, keep the rest
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"

LAUNCH=1
SET1=0; SET2=0; SET3=0
DISK1=""; DISK2=""; CD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --disk1) DISK1="$2"; SET1=1; shift ;;
        --disk2) DISK2="$2"; SET2=1; shift ;;
        --cd)    CD="$2";    SET3=1; shift ;;
        --no-launch) LAUNCH=0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

export MSYS_NO_PATHCONV=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
rsh() { ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
            "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }

for p in "$DISK1" "$DISK2" "$CD"; do
    case "$p" in
        ""|/*) ;;
        *) echo "ERROR: '$p' is not absolute - a relative path attaches nothing" >&2
           exit 2 ;;
    esac
done

# hps_io slot numbers, from CONF_STR in sgiindy.sv: 1 = SCSI ID1, 2 = SCSI ID2,
# 3 = SCSI ID6, which CDROM_IDS elaborates as a CD-ROM rather than a disk.
CORE="${RBF_REMOTE%.rbf}"
rsh "mkdir -p /media/fat/config /media/fat/sgidbg" >/dev/null 2>&1

setslot() {   # setslot SLOT PATH
    rsh "python3 -c \"
import sys
p = sys.argv[1].encode()
open('/media/fat/config/$CORE.s$1','wb').write(p + b'\\0' * (1024 - len(p)))
\" '$2'" || exit 1
    if [ -n "$2" ]; then log "slot $1 -> $2"
    else                log "slot $1 detached"; fi
}

[ "$SET1" = 1 ] && setslot 1 "$DISK1"
[ "$SET2" = 1 ] && setslot 2 "$DISK2"
[ "$SET3" = 1 ] && setslot 3 "$CD"
if [ "$SET1$SET2$SET3" = "000" ]; then
    log "no slots named; leaving the saved mounts as they are"
fi
rsh "ls -la /media/fat/config/$CORE.s* 2>/dev/null" | sed 's/^/    /'

for f in tools/misterdeploy/memclear.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/ddr3_peek.py tools/misterdeploy/imgdiff.py \
         tools/misterdeploy/sgivh.py; do
    scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
        "$f" "$MISTER_SSH_USER@$MISTER_HOST:/media/fat/sgidbg/" 2>/dev/null
done

[ "$LAUNCH" = 0 ] && { log "--no-launch: stopping here"; exit 0; }

# Start from a known state, the same as every other measurement here does.
rsh "python3 /media/fat/sgidbg/memclear.py >/dev/null; \
     python3 /media/fat/sgidbg/fb_poke.py fill 0xE7 >/dev/null; \
     echo 'load_core /media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE' > /dev/MiSTer_cmd"
log "loaded - give it about 40 seconds, then read the screen"
