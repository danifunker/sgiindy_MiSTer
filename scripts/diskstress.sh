#!/usr/bin/env bash
#
# diskstress.sh [--copies N] [--wait S] [--out FILE] [--keep] - does a write ever
# land somewhere it was not sent? Restores the image, boots IRIX, logs in as
# root, and copies /unix N times (each copy synced) while `ls -lR /usr` reads
# directories and inodes in the background; halts; then
# tools/misterdeploy/efsdiff.py compares the whole used image with the pristine
# one ON THE BOARD, block by block, before anything restores it:
#   * FOREIGN blocks - data of a file whose inode did not change (a misplaced
#     write lands on somebody else's block),
#   * every copy against /unix (the block it was meant for is left stale).
# Prints DISKSTRESS PASS / FAIL.
#
# Written after build 41's first diskcheck (2026-09-17): libX11.so.1 changed on
# the image although IRIX had read it correctly and nothing wrote it, and the
# repeat passed - one failure in eleven diskchecks, too rare for diskcheck's
# single 3 MB copy to chase.
#
#   MISTER_RBF_PATH=/tmp/SGIIndy.rbf bash scripts/diskstress.sh --out tests/out/hw/stress-b41.txt
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
COPIES=16; WAIT=300; OUT="tests/out/hw/diskstress.txt"; KEEP=0
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
PRI="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53-pristine.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --copies) COPIES="$2"; shift ;;
        --wait)   WAIT="$2"; shift ;;
        --out)    OUT="$2"; shift ;;
        --keep)   KEEP=1 ;;           # do not restore first (compare a session on top of the last)
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
TMPD="/tmp/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
pusht() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$TMPD/"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
rep() { echo "$*" | tee -a "$OUT"; }

rsh "mkdir -p $DBG $TMPD"
for f in tools/misterdeploy/fb_poke.py tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py; do push "$f"; done
for f in tools/misterdeploy/efsread.py tools/misterdeploy/efsdiff.py; do pusht "$f" || exit 1; done
rsh "cmp -s $TMPD/efsdiff.py /dev/null && exit 1; python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' $TMPD/efsdiff.py" \
    || { echo "efsdiff.py did not arrive intact on the board" >&2; exit 1; }

if [ "$KEEP" = 0 ]; then
    say "restoring $IMG from $PRI (in place, image closed first - see hinv.sh)"
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$PRI' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
RBF_ON_DEVICE="${MISTER_RBF_PATH:-/media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE}"
rep "core: $(rsh "md5sum $RBF_ON_DEVICE" | cut -c1-32) ($RBF_ON_DEVICE), $COPIES copies"
python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
    --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1

T0=$(date +%s)
while :; do
    LINE=$(rsh "sleep 20; python3 $DBG/irixstate.py" 2>&1 | tail -1)
    K=$(echo "$LINE" | awk '{print $1}')
    say "$LINE"
    [ "$K" = X-UP ] && break
    [ "$K" = PANIC ] && { rep "PANIC during boot"; rep "DISKSTRESS FAIL"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { rep "no login screen in 480 s"; rep "DISKSTRESS FAIL"; exit 1; }
done

rsh "sleep 15"
say "parking the pointer, logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
rsh "sleep 55"
say "quitting Software Manager, pointer into the Console"
STEPS=()
for i in $(seq 1 40); do STEPS+=("mouseMove:-40,-40" "sleep:0.02"); done
for i in $(seq 1 17); do STEPS+=("mouseMove:4,0" "sleep:0.02"); done
for i in $(seq 1 11); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
ws "${STEPS[@]}"
ws "mouseBtn:left" "sleep:1.5"                      # File, at (68,44)
STEPS=()
for i in $(seq 1 57); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
ws "${STEPS[@]}"
ws "mouseBtn:left" "sleep:3"                        # Quit, at (68,272)
STEPS=()
for i in $(seq 1 108); do STEPS+=("mouseMove:4,0" "sleep:0.02"); done
for i in $(seq 1 82); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
ws "${STEPS[@]}"                                    # the Console, (500,600)
rsh "sleep 3"

# No pipes through the ws API (docs/design/scsi-block-cache.md). The background ls keeps directory and
# inode reads going while the copies write; each copy is synced so its blocks go
# out while the next one is being read.
LIST=$(seq -s ' ' 1 "$COPIES")
say "copying /unix $COPIES times inside IRIX"
ws "text:ls -lR /usr > /dev/null 2>&1 & for i in $LIST; do cp /unix /root/s\$i; sync; done; sync; sync" "sleep:0.3" "kbdRaw:28"
rsh "sleep $WAIT"
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 75"

DST=""
for i in $LIST; do DST="$DST /root/s$i"; done
say "comparing the image with pristine (efsdiff, on the board)"
rep "---- efsdiff on the board ----"
rsh "cd $TMPD; python3 efsdiff.py '$IMG' '$PRI' --max 40 --src /unix --copies /unix $DST" 2>&1 | tee -a "$OUT"
rsh "cd $TMPD; python3 efsread.py '$IMG' cat /var/adm/SYSLOG" 2>/dev/null \
    | grep -E "wd93|SCSI|scsi|resetting|dks|SYNC" | tail -20 | sed 's/^/SYSLOG: /' | tee -a "$OUT"
if grep -q "^EFSDIFF CLEAN" "$OUT"; then rep "DISKSTRESS PASS"; else rep "DISKSTRESS FAIL"; fi
say "report -> $OUT"
