#!/usr/bin/env bash
#
# screen.sh [NAME] [--crop X,Y,W,H] [--scale S] [--mode text|grey] [--full]
#
# Read the machine's screen. The PROM's console is drawn into the frame buffer
# once Newport is fitted, so the only way to know what the machine SAID is to
# read the pixels back out of DDR3 - the HDMI screenshot API scales, and it
# never captures the OSD at all.
#
# This grabs the 1280x1024 colour-index plane off the board, brings it here and
# renders it. Default is the console band binarised on index 7, which is the
# rendering you can actually read words in.
#
#   bash scripts/screen.sh hinv
#   bash scripts/screen.sh boot --mode grey --full --scale 0.5
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
export MSYS_NO_PATHCONV=1

NAME="screen"; CROP="260,290,780,480"; SCALE="1.6"; MODE="text"
while [ $# -gt 0 ]; do
    case "$1" in
        --crop)  CROP="$2"; shift ;;
        --scale) SCALE="$2"; shift ;;
        --mode)  MODE="$2"; shift ;;
        --full)  CROP="" ;;
        -*) echo "unknown argument: $1" >&2; exit 2 ;;
        *)  NAME="$1" ;;
    esac
    shift
done

OUTDIR=tests/out/hw
mkdir -p "$OUTDIR"
ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
    "$MISTER_SSH_USER@$MISTER_HOST" 'python3 /media/fat/sgidbg/fbgrab.py' >/dev/null || exit 1
scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
    "$MISTER_SSH_USER@$MISTER_HOST:/tmp/fb.raw" "$OUTDIR/$NAME.raw" || exit 1

ARGS="--mode $MODE --scale $SCALE"
[ -n "$CROP" ] && ARGS="$ARGS --crop $CROP"
python tools/misterdeploy/fbpng.py "$OUTDIR/$NAME.raw" "$OUTDIR/$NAME.png" $ARGS 2>/dev/null
