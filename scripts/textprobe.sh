#!/bin/bash
# scripts/textprobe.sh TAG - boot the staged core, fill the Console with known text,
# and read the frame buffer back whole, to find out what a damaged glyph's
# missing pixels actually hold. Boot/login steps are saverprobe.sh's.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. scripts/local.env
export MSYS_NO_PATHCONV=1
TAG=${1:-b43}
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
export MISTER_RBF_PATH=/tmp/SGIIndy.rbf
DBG=/media/fat/sgidbg
OUTD=tests/out/hw/text-$TAG
mkdir -p "$OUTD"
LOG=$OUTD/run.log
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
pull() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST:$1" "$2"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
: > "$LOG"

for f in fb_poke.py memclear.py irixstate.py ddr3_peek.py fbgrab.py fbgrab32.py; do push "tools/misterdeploy/$f"; done
say "staged rbf: $(rsh "md5sum $MISTER_RBF_PATH" | cut -c1-32)"
bash scripts/setopt.sh >/dev/null || exit 1
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
    --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1
T0=$(date +%s)
while :; do
    LINE=$(rsh "sleep 10; python3 $DBG/irixstate.py" 2>&1 | tail -1)
    K=$(echo "$LINE" | awk '{print $1}')
    say "+$(( $(date +%s) - T0 ))s $LINE"
    [ "$K" = X-UP ] && break
    [ "$K" = PANIC ] && { say "panicked, giving up"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s"; exit 1; }
done
rsh "sleep 15"
say "logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
rsh "sleep 90"
say "quitting Software Manager, pointer into the Console"
STEPS=()
for i in $(seq 1 40); do STEPS+=("mouseMove:-40,-40" "sleep:0.02"); done
for i in $(seq 1 17); do STEPS+=("mouseMove:4,0" "sleep:0.02"); done
for i in $(seq 1 11); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
ws "${STEPS[@]}"
ws "mouseBtn:left" "sleep:1.5"
STEPS=()
for i in $(seq 1 57); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
ws "${STEPS[@]}"
ws "mouseBtn:left" "sleep:3"
STEPS=()
for i in $(seq 1 108); do STEPS+=("mouseMove:4,0" "sleep:0.02"); done
for i in $(seq 1 82); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
ws "${STEPS[@]}"
rsh "sleep 3"
ws "text:xset m 0 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 1"
ws "text:set +H" "sleep:0.3" "kbdRaw:28"
rsh "sleep 2"

# THE TEST TEXT. Output lines are drawn by the terminal as whole strings;
# the command line itself is drawn a character at a time as it is echoed.
# 'h', '6', 'p' and 'm' all have strokes in their right-hand columns, which
# is where every damaged glyph seen so far lost its pixels.
H=$(printf 'h%.0s' $(seq 1 78)); S=$(printf '6pm%.0s' $(seq 1 26))
ws "text:for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo $H; echo $S; done" "sleep:0.3" "kbdRaw:28"
rsh "sleep 20"
say "grabbing"
bash scripts/grab.sh "$OUTD/screen.png" | tee -a "$LOG"
rsh "cd /tmp && python3 $DBG/fbgrab32.py 180 360 680 415 /tmp/fb32.bin && python3 $DBG/fbgrab.py /tmp/fb.raw" | tee -a "$LOG"
pull /tmp/fb32.bin "$OUTD/fb32.bin"
pull /tmp/fb.raw "$OUTD/fb.raw"
bash scripts/grab.sh "$OUTD/screen2.png" | tee -a "$LOG"
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 60"
say "done -> $OUTD"
