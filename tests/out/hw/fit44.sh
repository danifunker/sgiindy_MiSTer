#!/bin/bash
# fit44.sh - build 44 (43b + docs/56 phase 1: the display window, GL's
# register interface, the host read path, the VDMA start byte), SEED=2.
cd /c/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e || exit 1
export SEED=2
bash scripts/build.sh --log b44.log </dev/null > b44.console 2>&1
rc=$?
[ -f output_files/sgiindy.rbf ] && cp output_files/sgiindy.rbf output_files/sgiindy-b44-seed2.rbf
for r in fit sta; do
    [ -f output_files/sgiindy.$r.rpt ] && cp output_files/sgiindy.$r.rpt output_files/sgiindy-b44.$r.rpt
done
echo "fit44 done rc=$rc" >> b44.console
