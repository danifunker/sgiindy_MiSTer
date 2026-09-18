#!/usr/bin/env bash
#
# clockprobe.sh [--fresh PRISTINE.img] [--gap SECONDS] [--out FILE] - boot IRIX
# on the board, log in as root, and ask IRIX the time twice, GAP seconds apart
# by the host's clock. Answers two separate questions about the machine's clock:
#
#   * what date IRIX believes at boot - the DS1386 has no battery here, so this
#     is whatever the core seeds it with (docs/design/r4600-accuracy-clock-disk.md);
#   * whether IRIX's time ADVANCES at real speed: the two readings' difference
#     against the host's GAP, to about 1 s in GAP (the readings are whole
#     seconds and the typing is timed on the host).
#
# The output channel is the disk, as in hinv.sh: each `date` appends a line to
# /root/clock.txt, `init 0` flushes it, efsread.py lifts it off the image. The host's
# UTC time at each keystroke goes into the same report.
#
#   bash scripts/clockprobe.sh --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img --gap 600
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
FRESH=""; GAP=600; OUT="tests/out/hw/clockprobe.txt"
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh) FRESH="$2"; shift ;;
        --gap)   GAP="$2"; shift ;;
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
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
rep() { echo "$*" | tee -a "$OUT"; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py \
         tools/misterdeploy/efsread.py; do push "$f"; done

if [ -n "$FRESH" ]; then
    say "restoring $IMG from $FRESH (in place, image closed first - see hinv.sh)"
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$FRESH' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
RBF_ON_DEVICE="${MISTER_RBF_PATH:-/media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE}"
rep "core: $(rsh "md5sum $RBF_ON_DEVICE" | cut -c1-32) ($RBF_ON_DEVICE)"
rep "MiSTer clock at launch: $(rsh 'date; date -u' | tr '\n' ' ')"
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

rsh "sleep 15"
say "parking the pointer, logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
# Software Manager opens by itself ~30 s after a root login, on top of the
# Console, and takes every typed key - it ate this probe's first run. Let it
# open and settle, quit it through its File menu, and walk the pointer into the
# Console, exactly as perfprobe.sh does (4-pixel steps are 1:1 under X).
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

# The command line is typed in full first and Enter is timed on its own, so
# the host timestamp is the moment the shell runs `date`.
say "first reading"
ws "text:date >> /root/clock.txt"
sleep 1
H1=$(date -u +%s.%N); ws "kbdRaw:28"
rep "host UTC at first Enter:  $(date -u -d @${H1%.*} '+%Y-%m-%d %H:%M:%S') ($H1)"
say "waiting ${GAP}s by the host clock"
sleep "$GAP"
say "second reading"
ws "text:date >> /root/clock.txt; cat /etc/TIMEZONE >> /root/clock.txt"
sleep 1
H2=$(date -u +%s.%N); ws "kbdRaw:28"
rep "host UTC at second Enter: $(date -u -d @${H2%.*} '+%Y-%m-%d %H:%M:%S') ($H2)"
rep "host gap: $(python -c "print('%.2f' % ($H2 - $H1))") s"
rsh "sleep 6"
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 75"
rep "---- /root/clock.txt from the image ----"
rsh "cd $DBG; python3 efsread.py '$IMG' cat /root/clock.txt" 2>&1 | tee -a "$OUT"
say "report -> $OUT"
