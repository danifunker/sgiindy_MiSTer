#!/usr/bin/env bash
#
# cdread.sh --mode on|off [--mb N] [--tag T] [--fresh PRISTINE.img] - read N
# megabytes off the CD-ROM under IRIX on the board and report what the SCSI
# block cache did with it (docs/49 §6).
#
# The recipe is scripts/hinv.sh's: boot IRIX, wait for the login chooser,
# park the pointer by the docs/45 recipe, log in as root, and type into the
# desktop's Console window - here
#
#     dd if=/dev/rdsk/dks0d6vol of=/dev/null bs=65536 count=N*16
#
# a raw sequential read of the disc on SCSI ID 6, which is what an install
# does. The command's output is invisible (the console is the frame buffer);
# the MEASUREMENT is the DDR3 beacon's disk-time counters (bcnread.py
# --stats), sampled every 5 s until the DATA-phase byte count stops moving:
# the deltas are the read's bytes, hps_io transactions, target wait, bus and
# DATA-phase seconds, and cache hits/misses; the wall time is the span of the
# polls that saw the count move. --mode sets the OSD switch first
# (scripts/setopt.sh scsicache=), so the same bitstream measures both ways.
# The machine is halted (init 0) at the end so the image stays clean.
#
# --sum copies the read into /tmp/cd.bin on the disk, runs IRIX's `sum` on
# it into /cdsum.txt, lifts that file off the image after the halt
# (efsread.py) and compares it with the same checksum computed over the
# ISO's first N MB on the device: the one proof that the bytes the guest got
# through the cache are the disc's. (Not a pipe: a `|` typed through the
# ws API never reaches IRIX's shell as one - two runs with `dd ... | sum`
# moved no CD bytes at all, 2026-09-08.) 16 MB is plenty for that.
#
#   bash scripts/cdread.sh --mode on  --tag b27 --mb 64
#   bash scripts/cdread.sh --mode off --tag b27 --mb 64
#   bash scripts/cdread.sh --mode on  --tag b27 --mb 16 --sum
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
MODE=""; MB=64; TAG="cd"; FRESH=""; SUM=0
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)  MODE="$2"; shift ;;
        --mb)    MB="$2"; shift ;;
        --tag)   TAG="$2"; shift ;;
        --fresh) FRESH="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        --sum)   SUM=1 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
[ "$MODE" = on ] || [ "$MODE" = off ] || { echo "--mode on|off is required" >&2; exit 2; }
export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p tests/out/hw
LOG="tests/out/hw/cdread-$TAG-$MODE.log"; [ "$SUM" = 1 ] && LOG="tests/out/hw/cdread-$TAG-$MODE-sum.log"
stats() { rsh "python3 $DBG/bcnread.py --stats" 2>&1 | tail -1; }
# the DATA-phase byte count out of a stats line, in whole bytes
bytes_of() { echo "$1" | sed -n 's/.*data=[0-9.]*s \([0-9.]*\)MB.*/\1/p' | awk '{printf "%d", $1 * 1000000}'; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py \
         tools/misterdeploy/bcnread.py tools/misterdeploy/efsread.py; do push "$f"; done

bash scripts/setopt.sh scsicache=$MODE >/dev/null || exit 1
if [ -n "$FRESH" ]; then
    say "restoring $IMG from $FRESH"
    rsh "cp '$FRESH' '$IMG.tmp' && mv '$IMG.tmp' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
say "launching $(rsh "md5sum /media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE" | cut -c1-32), cache $MODE" | tee -a "$LOG"
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
    [ "$K" = PANIC ] && { say "panicked, giving up" | tee -a "$LOG"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s" | tee -a "$LOG"; exit 1; }
done
rsh "sleep 15"
say "parking the pointer, logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
rsh "sleep 35"

S0=$(stats); B0=$(bytes_of "$S0")
say "before: $S0" | tee -a "$LOG"
say "typing the read: $MB MB off dks0d6vol"
if [ "$SUM" = 1 ]; then
    ws "text:dd if=/dev/rdsk/dks0d6vol of=/tmp/cd.bin bs=65536 count=$((MB * 16)); sum /tmp/cd.bin > /cdsum.txt; rm /tmp/cd.bin" "sleep:0.3" "kbdRaw:28"
else
    ws "text:dd if=/dev/rdsk/dks0d6vol of=/dev/null bs=65536 count=$((MB * 16))" "sleep:0.3" "kbdRaw:28"
fi
TT=$(date +%s); TFIRST=0; TLAST=0; PREV=$B0; STILL=0
# The desktop reads a little on its own (a megabyte or so after a login), so
# the read counts as STARTED only once 8 MB more than the "before" sample has
# crossed the bus; it is DONE after two quiet polls following that.
while :; do
    S=$(stats); B=$(bytes_of "$S"); NOW=$(date +%s)
    if [ "$B" -gt "$PREV" ] && [ $((B - B0)) -ge 8000000 ]; then
        [ "$TFIRST" = 0 ] && TFIRST=$NOW
        TLAST=$NOW; STILL=0
    elif [ "$TFIRST" != 0 ]; then
        STILL=$((STILL + 1))
    fi
    PREV=$B
    [ "$TFIRST" != 0 ] && [ "$STILL" -ge 2 ] && break
    [ "$TFIRST" = 0 ] && [ $((NOW - TT)) -ge 120 ] && { say "no CD traffic in 120 s - wrong device name, or the console did not take the line" | tee -a "$LOG"; break; }
    [ $((NOW - TT)) -ge 900 ] && break
    rsh "sleep 5"
done
S1=$(stats); B1=$(bytes_of "$S1")
say "after:  $S1" | tee -a "$LOG"
python - "$S0" "$S1" "$TT" "$TFIRST" "$TLAST" "$MB" "$MODE" <<'PY' | tee -a "$LOG"
import re, sys
s0, s1, tt, tf, tl, mb, mode = sys.argv[1:]
def parse(s):
    m = re.search(r"rd=(\d+) wr=(\d+) busy=([\d.]+)s \| target wait=([\d.]+)s \| bus busy=([\d.]+)s data=([\d.]+)s ([\d.]+)MB .*hits=(\d+) misses=(\d+) writes=(\d+)", s)
    if not m: sys.exit("cannot parse: " + s)
    v = [float(x) for x in m.groups()]
    return dict(rd=v[0], wr=v[1], hps=v[2], wait=v[3], bus=v[4], data=v[5], mb=v[6], hits=v[7], misses=v[8], writes=v[9])
a, b = parse(s0), parse(s1)
d = {k: b[k] - a[k] for k in a}
wall = (int(tl) - int(tt)) if int(tf) else 0
print("cdread %s MB cache %s: DATA %.2f MB in %.1f s of DATA phase (%.2f MB/s on the bus); "
      "wall ~%d s (%.2f MB/s to the guest, polled at 5 s); hps_io rd=%d wr=%d, HPS busy %.1f s; "
      "target wait %.1f s; bus busy %.1f s; cache hits=%d misses=%d"
      % (mb, mode, d["mb"], d["data"], (d["mb"] / d["data"]) if d["data"] else 0.0,
         wall, (d["mb"] / wall) if wall else 0.0, d["rd"], d["wr"], d["hps"], d["wait"], d["bus"],
         d["hits"], d["misses"]))
PY
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 60"
if [ "$SUM" = 1 ]; then
    # what the guest computed, and what the disc holds: IRIX's sum(1) is the
    # System V algorithm (a 16-bit sum with the carries folded in, and the
    # size in 512-byte blocks); the BSD -r form is printed too in case the
    # image's sum is that one
    GUEST=$(rsh "cd $DBG; python3 efsread.py '$IMG' cat /cdsum.txt" 2>&1 | tr -d '\r' | tail -1)
    ISO=$(rsh "tr -d '\\0' < /media/fat/config/SGIIndy.s3")
    HOST=$(rsh "python3 - \"\$(tr -d '\\0' < /media/fat/config/SGIIndy.s3)\" $((MB * 1048576))" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read(n)
s = sum(data)
r = (s & 0xffff) + (s >> 16)
sysv = (r & 0xffff) + (r >> 16)
bsd = 0
for b in data:
    bsd = ((bsd >> 1) | ((bsd & 1) << 15)) & 0xffff
    bsd = (bsd + b) & 0xffff
print("sysv %d %d | bsd %d %d" % (sysv, (len(data) + 511) // 512, bsd, (len(data) + 1023) // 1024))
PY
)
    say "guest sum: $GUEST" | tee -a "$LOG"
    say "disc  sum: $HOST  ($ISO, first $MB MB)" | tee -a "$LOG"
    G1=$(echo "$GUEST" | awk '{print $1}')
    case "$HOST" in *"sysv $G1 "*|*"bsd $G1 "*) say "CHECKSUM MATCH" | tee -a "$LOG" ;; *) say "CHECKSUM MISMATCH" | tee -a "$LOG" ;; esac
fi
say "done -> $LOG"
