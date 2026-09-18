#!/bin/bash
# saverrun43.sh - stage build 43b on the board and run every screen saver.
cd /c/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e || exit 1
. scripts/local.env
export MSYS_NO_PATHCONV=1
RBF=output_files/sgiindy-b43b-seed2.rbf
scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$RBF" \
    "$MISTER_SSH_USER@$MISTER_HOST:/tmp/SGIIndy.rbf" || exit 1
export MISTER_RBF_PATH=/tmp/SGIIndy.rbf
exec bash scripts/saverprobe.sh --tag b43 \
     --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img
