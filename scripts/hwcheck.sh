#!/usr/bin/env bash
# hwcheck.sh [--no-deploy] [--wait N] [--tag NAME] [opt=value ...]
#
# One command for the bring-up loop: set the OSD options, put the build on the
# board, wait for the machine to boot and draw, then take BOTH views of the
# result - a checked-fresh screenshot of what the scaler is showing, and a
# histogram of what is actually in the frame buffer, read from the ARM.
#
# THE TWO VIEWS ANSWER DIFFERENT QUESTIONS AND THAT IS THE POINT. The screen
# is everything from the frame buffer to the pixel; the histogram is everything
# up to it. A black screen with a drawn frame buffer is a display fault; an
# empty frame buffer is the rasteriser's. Guessing which from a photograph is
# how the first evening here was spent.
#
#   bash scripts/hwcheck.sh --tag splash
#   bash scripts/hwcheck.sh --tag raw viddbg=raw
#   bash scripts/hwcheck.sh --no-deploy --tag again      # relaunch only
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"

DEPLOY=1; WAIT=180; TAG="hw"; OPTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-deploy) DEPLOY=0 ;;
        --wait) WAIT="$2"; shift ;;
        --tag)  TAG="$2";  shift ;;
        *=*)    OPTS+=("$1") ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export MSYS_NO_PATHCONV=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
OUT="tests/out/hw"; mkdir -p "$OUT"

log "options: ${OPTS[*]:-(all defaults)}"
bash scripts/setopt.sh "${OPTS[@]}" >/dev/null || exit 1

if [ "$DEPLOY" = 1 ]; then
    bash scripts/deploy.sh 2>&1 | tail -3
else
    python tools/misterdeploy/launch_unstable_core.py \
        --host "$MISTER_HOST" --folder "$MISTER_CORE_FOLDER" \
        --core "$RBF_REMOTE" --ssh-key "$MISTER_SSH_KEY" 2>&1 | tail -1
fi

# THE DRAWING IS SLOW NOW AND THAT IS EXPECTED. REX3 waits for each write to be
# acknowledged, so a pixel costs a DDR3 round trip; a screen clear is over a
# million of them. Waiting too little and calling it black is a real risk.
log "waiting ${WAIT}s for POST and the boot screen"
sleep "$WAIT"

bash scripts/grab.sh "$OUT/$TAG.png" || true

log "=== what is actually in the frame buffer ==="
scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
    tools/misterdeploy/ddr3_peek.py "$MISTER_SSH_USER@$MISTER_HOST:/media/fat/sgidbg/" 2>/dev/null
ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" 'python3 - <<PYEOF
import importlib.util
from collections import Counter
spec = importlib.util.spec_from_file_location("p","/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W,H,S,FB = 1280,1024,2048,0x34000000
hist=Counter()
for y in range(0,H,4):
    hist.update(m.read_phys(FB+(y*S)*8, W*8)[0::8])
tot=sum(hist.values())
print(f"  {len(hist)} distinct colour indices over {tot} sampled pixels")
for v,c in hist.most_common(10):
    print(f"    index {v:3d} (0x{v:02x}): {c:8d}  {100.0*c/tot:5.1f}%")
PYEOF'
log "done: $OUT/$TAG.png"
