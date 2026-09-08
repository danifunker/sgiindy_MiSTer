#!/usr/bin/env bash
# diskpair.sh RBF [--tag T] [--boots N] - the SCSI block cache's board
# measurement (docs/49): deploy RBF, then boot IRIX from the pristine image
# with the cache ON and again with it OFF, logging the disk-time counters at
# every 20 s poll (scripts/irixrate.sh --stats). The stats line at X-UP is
# the boot's disk time; the elapsed column is the boot.
#
# Detach it - two fresh boots are ~20 minutes:
#   Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
#     CommandLine = '"C:\Program Files\Git\bin\bash.exe" -c "exec bash scripts/diskpair.sh output_files/sgiindy-b26a-seed2.rbf --tag b26a </dev/null >b26a-pair.console 2>&1"';
#     CurrentDirectory = '<repo>' }
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
RBF="${1:?rbf}"; shift
TAG="b26"; N=1
PRISTINE="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53-pristine.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)   TAG="$2"; shift ;;
        --boots) N="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
say() { echo "[$(date +%H:%M:%S)] $*"; }
say "deploying $RBF ($(md5sum "$RBF" | cut -c1-32))"
bash scripts/deploy.sh --rbf "$RBF" --no-launch || exit 1
for mode in on off; do
    say "=== SCSI cache $mode: $N boot(s) from $PRISTINE"
    bash scripts/setopt.sh scsicache=$mode || exit 1
    bash scripts/irixrate.sh "$N" --tag "$TAG-$mode" --fresh "$PRISTINE" --stats
done
say "done"
