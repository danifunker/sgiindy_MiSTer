#!/usr/bin/env bash
#
# mount.sh [--disk1 PATH] [--disk2 PATH] [--cd PATH] [--no-launch]
#
# Mount SCSI images and launch the core, without touching the OSD.
#
# WHY NOT THE OSD. The screenshot API does not capture it, so a blind keystroke
# sequence into the OSD cannot be verified - a miscounted row mounts the wrong
# file, or nothing, and looks identical to success. That is the same reason
# scripts/setopt.sh writes the CFG file directly instead of driving the menu.
# MiSTer's own answer for this is an MGL: a file that names the core and the
# images, loaded in one shot through /dev/MiSTer_cmd.
#
# THE PATHS IN AN MGL MUST BE ABSOLUTE. A relative `games/SGIIndy/disk.img`
# mounts NOTHING and reports nothing - the core comes up, the boot looks
# ordinary, and there is no disk. That cost a round of confusion here, so this
# script refuses a path that does not start with a slash.
#
# HOW TO TELL IT WORKED, since /tmp/ACTIVEGAME stays empty for disk-slot mounts
# and is not a mount record: the boot screen changes. With no media the PROM
# prints only "Unable to boot; press any key to continue:". With a bootable
# device it tries the standalone shell first:
#
#     Cannot load /sash.
#     No default device and path in environment.
#     Unable to load bootfile: invalid argument
#
# That "Cannot load /sash" is the machine telling you it found the device.
#
#   bash scripts/mount.sh --disk1 "/media/fat/games/SGIIndy/indy1GB.img" \
#                         --cd    "/media/fat/games/SGIIndy/IRIX 5.3 XFS.iso"
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"

DISK1=""; DISK2=""; CD=""; LAUNCH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --disk1) DISK1="$2"; shift ;;
        --disk2) DISK2="$2"; shift ;;
        --cd)    CD="$2";    shift ;;
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
        *) echo "ERROR: '$p' is not absolute - an MGL with a relative path mounts nothing" >&2
           exit 2 ;;
    esac
done

# hps_io slot numbers, from CONF_STR in sgiindy.sv: S1 = SCSI ID1, S2 = SCSI
# ID2, S3 = SCSI ID6, which CDROM_IDS elaborates as a CD-ROM rather than a disk.
MGL="/media/fat/$MISTER_CORE_FOLDER/SGIIndy_SCSI.mgl"
CORE="${RBF_REMOTE%.rbf}"
{
    echo "<mistergamedescription>"
    echo "	<rbf>$MISTER_CORE_FOLDER/$CORE</rbf>"
    [ -n "$DISK1" ] && echo "	<file delay=\"2\" type=\"s\" index=\"1\" path=\"$DISK1\"/>"
    [ -n "$DISK2" ] && echo "	<file delay=\"1\" type=\"s\" index=\"2\" path=\"$DISK2\"/>"
    [ -n "$CD" ]    && echo "	<file delay=\"1\" type=\"s\" index=\"3\" path=\"$CD\"/>"
    echo "</mistergamedescription>"
} > /tmp/sgiindy_scsi.mgl

scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
    /tmp/sgiindy_scsi.mgl "$MISTER_SSH_USER@$MISTER_HOST:$MGL" || exit 1
log "wrote $MGL"
sed 's/^/    /' /tmp/sgiindy_scsi.mgl

for f in tools/misterdeploy/memclear.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/ddr3_peek.py; do
    scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
        "$f" "$MISTER_SSH_USER@$MISTER_HOST:/media/fat/sgidbg/" 2>/dev/null
done

[ "$LAUNCH" = 0 ] && { log "--no-launch: stopping here"; exit 0; }

# Start from a known state, the same as every other measurement here does.
rsh "python3 /media/fat/sgidbg/memclear.py >/dev/null; \
     python3 /media/fat/sgidbg/fb_poke.py fill 0xE7 >/dev/null; \
     echo 'load_core $MGL' > /dev/MiSTer_cmd"
log "loaded - give it about 40 seconds, then read the screen"
