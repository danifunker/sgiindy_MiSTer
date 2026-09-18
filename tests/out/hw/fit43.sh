#!/bin/bash
# fit43.sh - build 43b (build 42 + the rest of REX3's command set), SEED=2.
cd /c/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e || exit 1
export SEED=2
exec bash scripts/build.sh --log b43b.log </dev/null > b43b.console 2>&1
