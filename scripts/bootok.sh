#!/usr/bin/env bash
#
# bootok.sh [--disk1 P] [--disk2 P] [--cd P] [--tries N] [--wait S]
#
# Launch the core until it reaches a HEALTHY boot, then stop and leave it there.
#
# WHY. About one boot in three panics in the SCSI driver for reasons that have
# nothing to do with whatever is being tested (scripts/bootrate.sh measures the
# rate; docs/20 has the fault). So a hardware experiment that launches once and
# reads the screen is measuring the panic as often as it is measuring itself.
# Every run that means to conclude something has to start from a boot that is
# known to have reached the prompt, and that means looping.
#
# It exits 0 with the machine sitting at the diskless prompt, or 1 having given
# up, and it prints the classification of every attempt so a run that took six
# tries does not silently read as one that took one.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
export MSYS_NO_PATHCONV=1

TRIES=6; ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tries) TRIES="$2"; shift ;;
        --disk1|--disk2|--cd) ARGS="$ARGS $1 \"$2\""; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

rsh() { ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
            "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }

i=1
while [ "$i" -le "$TRIES" ]; do
    eval bash scripts/mount.sh $ARGS >/dev/null 2>&1
    # classify.py samples, waits 20 s and samples again, which is also the
    # settling time this machine needs - the boot screen takes about 30 s.
    R=$(rsh 'sleep 20; python3 /media/fat/sgidbg/classify.py' 2>&1)
    echo "  try $i/$TRIES: $R"
    case "$R" in
        healthy*) exit 0 ;;
    esac
    i=$((i + 1))
done
echo "gave up after $TRIES attempts"
exit 1
