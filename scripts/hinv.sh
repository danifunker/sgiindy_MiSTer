#!/usr/bin/env bash
#
# hinv.sh [--fresh PRISTINE.img] [--out FILE] - boot IRIX on the board, log in
# as root, run `hinv`, halt, and bring the output back.
#
# The Indy's console is the frame buffer and the machine has no serial link
# out, so the only channel for a command's OUTPUT is the disk: hinv writes
# /hinv.txt, `init 0` flushes it, and efsread.py lifts it off the image after
# the halt. Input goes in through the MiSTer Remote ws API (ws_send.py): the
# login chooser has the "Login name:" field focused, so `root` + Enter logs
# in (no password on this image); the desktop's Console window then appears
# under a pointer parked by the docs/45 recipe (slam to the top-left corner,
# then 39 steps of 7,10), and X's focus-follows-pointer sends the typed
# command there. The +35 s wait is what the desktop needs before Software
# Manager maps and steals the focus.
#
# --fresh restores the pristine image first (recommended: /hinv.txt then
# lands on a known image and the boot cannot be a crash-looped one, docs/47).
#
#   bash scripts/hinv.sh --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img --out tests/out/hw/hinv-b25.txt
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
FRESH=""; OUT="tests/out/hw/hinv.txt"
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh) FRESH="$2"; shift ;;
        --out)   OUT="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py \
         tools/misterdeploy/efsread.py; do push "$f"; done

if [ -n "$FRESH" ]; then
    say "restoring $IMG from $FRESH"
    rsh "cp '$FRESH' '$IMG.tmp' && mv '$IMG.tmp' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
say "launching $(rsh "md5sum /media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE" | cut -c1-32)"
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
    [ "$K" = PANIC ] && { say "panicked, giving up"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s"; exit 1; }
done

# Let the chooser finish drawing its icons before touching it.
rsh "sleep 15"
say "parking the pointer, logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
rsh "sleep 35"
say "typing hinv"
ws "text:hinv > /hinv.txt" "sleep:0.3" "kbdRaw:28"
rsh "sleep 6"
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 75"
mkdir -p "$(dirname "$OUT")"
rsh "cd $DBG; python3 efsread.py '$IMG' cat /hinv.txt" > "$OUT" 2>&1
say "hinv output ($(wc -l < "$OUT") lines) -> $OUT"
cat "$OUT"
