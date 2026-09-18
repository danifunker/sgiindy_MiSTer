#!/bin/bash
# fit44.sh - build 44 (43b + docs/56 phase 1: the display window, GL's
# register interface, the host read path, the VDMA start byte), SEED=2.
cd /c/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e || exit 1
export SEED=2
touch b44.start     # an rbf older than this is not build 44's
# Queued behind any other Quartus on this box (the MacQuadra800 session's
# fits): scripts/fit_when_free.sh waits, then runs build.sh --log b44.log.
bash scripts/fit_when_free.sh b44 </dev/null > b44.console 2>&1
rc=$?
if [ "$rc" = 0 ] && [ output_files/sgiindy.rbf -nt b44.start ]; then
    cp output_files/sgiindy.rbf output_files/sgiindy-b44-seed2.rbf
    for r in fit sta; do
        [ -f output_files/sgiindy.$r.rpt ] && cp output_files/sgiindy.$r.rpt output_files/sgiindy-b44.$r.rpt
    done
fi
echo "fit44 done rc=$rc" >> b44.console
