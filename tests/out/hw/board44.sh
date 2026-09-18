#!/bin/bash
# board44.sh - build 44 on the board (docs/56 phase 1: the display window,
# GL's register interface, the host read path, the VDMA start byte).
#   1. saverprobe: every saver, the GL ones (ep, bongo, buttonfly) first in
#      importance - build 43b drew nothing of theirs but stale planes;
#   2. textprobe: the Console filled with known text, the screen grab and the
#      frame buffer both pulled - the scaler must drop no column now;
#   3. the regression: cpu-tests as the PROM, diskcheck, perfprobe.
# Launch detached; the steps' own logs land in tests/out/hw/.
cd /c/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e || exit 1
. scripts/local.env
export MSYS_NO_PATHCONV=1
RBF=output_files/sgiindy-b44-seed2.rbf
PRISTINE=/media/fat/games/SGIIndy/SGIIndy53-pristine.img
OUT=tests/out/hw
LOG=$OUT/board44.txt
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
: > "$LOG"
[ -f "$RBF" ] || { say "no $RBF"; exit 1; }
say "build 44: $RBF ($(md5sum "$RBF" | cut -c1-32))"
scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$RBF" \
    "$MISTER_SSH_USER@$MISTER_HOST:/tmp/SGIIndy.rbf" || { say "scp failed"; exit 1; }
export MISTER_RBF_PATH=/tmp/SGIIndy.rbf

say "saverprobe"
bash scripts/saverprobe.sh --tag b44 --fresh "$PRISTINE" > "$OUT/saverprobe-run-b44.txt" 2>&1
say "saverprobe rc=$?"

say "textprobe"
bash "$OUT/textprobe.sh" b44 > "$OUT/textprobe-run-b44.txt" 2>&1
say "textprobe rc=$?"

say "regression (cpu-tests, diskcheck, perfprobe)"
bash "$OUT/boardrun39.sh" b44 "$RBF" --cpu --disk > "$OUT/boardrun-run-b44.txt" 2>&1
say "regression rc=$?"
say "BOARD44 DONE"
