#!/bin/bash
# scripts/regression.sh TAG RBF [--cpu] [--disk] [--no-perf] [--perf-skip LIST]
#
# The board regression for a new bitstream. Stages RBF in the board's RAM
# (no copy to the SD card, no reboot), then optionally:
#   --cpu    the R4600 cpu-tests suite run AS the PROM (tests/run-cputest-hw.sh,
#            ~5 min; the real PROM is put back afterwards)
#   --disk   scripts/diskcheck.sh on a freshly restored pristine image
#            (~13 min: IRIX sums its own kernel and libraries and they are
#            compared with the image read straight off the card)
# and then scripts/perfprobe.sh (~20 min, the speed measurement) unless
# --no-perf. SYSLOG is pulled after each boot. Logs go to tests/out/hw/.
#
#   bash scripts/regression.sh b44 output_files/sgiindy.rbf --cpu --disk --no-perf
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. scripts/local.env
export MSYS_NO_PATHCONV=1
TAG=$1; RBF=$2; shift 2
CPU=0; DISK=0; PERF=1; PSKIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cpu) CPU=1 ;;
        --disk) DISK=1 ;;
        --no-perf) PERF=0 ;;
        --perf-skip) PSKIP="$2"; shift ;;
    esac
    shift
done
OUT=tests/out/hw
LOG=$OUT/boardrun-$TAG.txt
IMG=/media/fat/games/SGIIndy/SGIIndy53.img
PRISTINE=/media/fat/games/SGIIndy/SGIIndy53-pristine.img
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
syslog() {
    rsh "mkdir -p /tmp/sgidbg && cp /media/fat/sgidbg/efsread.py /tmp/sgidbg/ && python3 /tmp/sgidbg/efsread.py $IMG get /var/adm/SYSLOG /tmp/SYSLOG-$1.txt" >> "$LOG" 2>&1
    scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST:/tmp/SYSLOG-$1.txt" "$OUT/syslog-$TAG-$1.txt"
    say "SYSLOG $1: $(grep -c . "$OUT/syslog-$TAG-$1.txt") lines; SCSI notices today:"
    grep -iE "wd93|scsi|sync|resetting|dks|timeout" "$OUT/syslog-$TAG-$1.txt" | tail -12 | tee -a "$LOG"
}
: > "$LOG"
say "board run $TAG: $RBF ($(md5sum "$RBF" | cut -c1-32))"
rsh "df -h /media/fat | tail -1" | tee -a "$LOG"
scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$RBF" "$MISTER_SSH_USER@$MISTER_HOST:/tmp/SGIIndy.rbf" || { say "scp failed"; exit 1; }
say "staged: $(rsh 'md5sum /tmp/SGIIndy.rbf' | cut -c1-32)"
export MISTER_RBF_PATH=/tmp/SGIIndy.rbf
if [ $CPU = 1 ]; then
    say "cpu-tests as the PROM"
    bash tests/run-cputest-hw.sh --no-build --wait 240 > $OUT/cputest-run-$TAG.txt 2>&1
    cp tests/out/hw-cputest/hw-cputest.log $OUT/cputest-r4600-$TAG.log 2>/dev/null
    say "cpu-tests: $(grep RESULT $OUT/cputest-run-$TAG.txt | tail -1)"
    say "PROM back: $(md5sum releases/boot.rom | cut -c1-32) / board $(rsh 'md5sum /media/fat/games/SGIIndy/boot.rom' | cut -c1-32)"
fi
if [ $DISK = 1 ]; then
    say "diskcheck"
    bash scripts/diskcheck.sh --fresh $PRISTINE --out $OUT/diskcheck-$TAG.txt > $OUT/diskcheck-run-$TAG.txt 2>&1
    say "diskcheck: $(grep -E 'DISKCHECK (PASS|FAIL)' $OUT/diskcheck-$TAG.txt $OUT/diskcheck-run-$TAG.txt | tail -1)"
    syslog disk
fi
if [ $PERF = 0 ]; then
    say "perfprobe skipped (--no-perf)"
    say "done"
    exit 0
fi
say "perfprobe"
if [ -n "$PSKIP" ]; then
    bash scripts/perfprobe.sh --tag $TAG --fresh $PRISTINE --skip "$PSKIP" > $OUT/perfprobe-run-$TAG.txt 2>&1
else
    bash scripts/perfprobe.sh --tag $TAG --fresh $PRISTINE > $OUT/perfprobe-run-$TAG.txt 2>&1
fi
say "perfprobe rc=$?: $(grep -E 'X-UP at' $OUT/perfprobe-run-$TAG.txt | tail -1)"
syslog perf
say "done"
