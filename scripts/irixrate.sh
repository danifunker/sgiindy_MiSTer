#!/usr/bin/env bash
#
# irixrate.sh [N] [--wait S] [--tag NAME] - launch the core N times with the
# saved SCSI slots attached, let IRIX boot each time, and classify how each
# boot ended: PANIC (the kernel's panicstr is set - the message is printed),
# X-UP (X owns the screen: login or desktop), BOOTING/UNKNOWN at the deadline.
#
# THE NUMBER IS THE MEASUREMENT (scripts/bootrate.sh says why). Build 24's
# `init died (why = 2, what = 0xb)` is intermittent - two clean desktops, then
# a panic - and a virtually indexed instruction cache's alias needs an
# uncoloured page to land on a reused one, so one boot proves nothing either
# way. Ten boots of the candidate against ten of the control on the same
# image is the comparison (docs/47).
#
# The verdict is read ON THE DEVICE by tools/misterdeploy/irixstate.py:
# `panicstr` out of main memory (exact) and the frame buffer's index
# histogram (the boot panel vs X). Memory is zeroed before every launch so a
# previous boot's panicstr cannot be read while the PROM is still running,
# and the frame buffer is marked so a stale picture cannot count.
#
# Each launch goes through launch_unstable_core.py (framework API reboot,
# then the OSD) exactly like bootrate.sh, so the framework re-attaches the
# saved disk slot itself (scripts/mount.sh sets it; run that once first).
# A boot ends early on PANIC or X-UP; otherwise it is polled every 20 s up
# to --wait seconds (default 420: fsck of a dirty 2 GB EFS plus rc2 and X
# take 4-6 minutes on the board).
#
#   bash scripts/irixrate.sh 10 --tag b25
#
# --fresh PRISTINE.img (ON THE DEVICE, absolute path) copies that image over
# the attached one before EVERY launch (copy to a temp name, then rename over
# it, so the core still holding the old file keeps its old inode). THIS IS
# NOT OPTIONAL FOR A RATE. An `init died` panic leaves /etc/ioctl.syscon,
# /var/adm/utmp and /var/adm/utmpx ZERO bytes long - init truncates them at
# start and rewrites them only if it lives - and the next init dies on them,
# every time, on every build: build 25 panicked 3/3 and build 24 2/2 at the
# same 80 s on the image left behind by the 09:17 panic, while the seven
# files init executes (/etc/init, rld, libc, sh, inittab, bcheckrc, /unix)
# were byte-identical to the pristine image (docs/47). Without --fresh the
# tally after the first panic measures that loop, not the core.
# The copy is 2 GB on the SD card (a few minutes); the deadline clock starts
# after it.
#
#   bash scripts/irixrate.sh 10 --tag b25 --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img
#
# Output: one line per boot and a tally, also appended to
# tests/out/hw/irixrate-<tag>.log.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"

N=10; WAIT=420; TAG="run"; FRESH=""
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --wait)  WAIT="$2"; shift ;;
        --tag)   TAG="$2"; shift ;;
        --fresh) FRESH="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        [0-9]*) N="$1" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" \
            "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
             "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py; do push "$f"; done

mkdir -p tests/out/hw
LOG="tests/out/hw/irixrate-$TAG.log"
RBFMD5=$(rsh "md5sum /media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE" | cut -c1-32)
IMGDESC="as left by the previous boot"; [ -n "$FRESH" ] && IMGDESC="restored from $FRESH before each launch"
echo "=== $(date '+%F %T') $TAG: $N launches, deadline ${WAIT}s, rbf md5 $RBFMD5, image $IMGDESC ===" | tee -a "$LOG"
declare -A TALLY
for i in $(seq 1 "$N"); do
    if [ -n "$FRESH" ]; then
        # Rename over the attached file: the core still holding the old one
        # keeps its inode, the next launch opens the fresh copy.
        TC=$(date +%s)
        rsh "cp '$FRESH' '$IMG.tmp' && mv '$IMG.tmp' '$IMG' && sync" || { echo "image restore failed" | tee -a "$LOG"; exit 1; }
        printf "  %2d/%-2d  image restored in %ds\n" "$i" "$N" "$(( $(date +%s) - TC ))" | tee -a "$LOG"
    fi
    rsh "python3 $DBG/fb_poke.py fill 0xE7" >/dev/null 2>&1
    rsh "python3 $DBG/memclear.py" >/dev/null 2>&1
    T0=$(date +%s)
    python tools/misterdeploy/launch_unstable_core.py \
        --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
        --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
        --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1
    LINE="UNKNOWN (launch never classified)"
    while :; do
        # the wait happens on the device: a foreground sleep here is refused
        # by some harnesses, and the ssh call has to be made anyway
        LINE=$(rsh "sleep 20; python3 $DBG/irixstate.py" 2>&1 | tail -1)
        K=$(echo "$LINE" | awk '{print $1}')
        [ "$K" = PANIC ] || [ "$K" = X-UP ] && break
        [ $(( $(date +%s) - T0 )) -ge "$WAIT" ] && break
    done
    EL=$(( $(date +%s) - T0 ))
    printf "  %2d/%-2d  %4ds  %s\n" "$i" "$N" "$EL" "$LINE" | tee -a "$LOG"
    K=$(echo "$LINE" | awk '{print $1}')
    TALLY[$K]=$(( ${TALLY[$K]:-0} + 1 ))
done

echo "=== tally over $N launches ($TAG) ===" | tee -a "$LOG"
for k in "${!TALLY[@]}"; do printf "  %-11s %d\n" "$k" "${TALLY[$k]}" | tee -a "$LOG"; done
