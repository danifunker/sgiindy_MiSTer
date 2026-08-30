#!/usr/bin/env bash
#
# run-cputest-hw.sh - run the IRIS CPU test suite on the DE10-Nano and read the
# result out of the machine's memory.
#
#   tests/run-cputest-hw.sh                 build, deploy, run, print, restore
#   tests/run-cputest-hw.sh --no-build      use the boot.rom already built
#   tests/run-cputest-hw.sh --keep          leave the suite on the card
#   tests/run-cputest-hw.sh --wait 240      give it longer
#   tests/run-cputest-hw.sh --load          run it with the memory busy
#
# WHY THIS EXISTS. tests/run-cputest.sh runs the same suite under Verilator, and
# that is the ratchet - but it only ever proves the RTL is self-consistent with
# a simulator that was told how the RTL behaves. The suite's whole point is that
# it is an oracle: it also runs on real SGI hardware, and where the answers
# differ, the silicon is right. This is the third place it can run, and the
# first that exercises what Quartus actually built - inferred M10K read-during-
# write behaviour, real DDR3 latency, real clock domains. None of those exist
# in a simulation, and every one of them has already produced a bug on this
# project that no simulator saw.
#
# It also runs where Verilator cannot: rtl/scsi/scsi.v defeats Verilator 5.020,
# which takes the simulated suite off the table entirely on some machines.
#
# HOW THE ANSWER GETS OUT. Not over serial - this machine's SCC has never put a
# start bit on the wire. tests/hw-cputest patches a memory sink into the suite's
# console and reads it back over ssh with ddr3_peek, which is the same trick
# that makes the frame buffer inspectable. See tests/hw-cputest/read_log.py.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"

BUILD=1; KEEP=0; WAIT=180; LOAD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --keep)     KEEP=1 ;;
        --load)     LOAD=1 ;;
        --wait)     WAIT="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

export MSYS_NO_PATHCONV=1
log() { echo "[$(date +%H:%M:%S)] $*"; }
DBG="/media/fat/sgidbg"
ROM="tests/out/hw-cputest/boot.rom"
rsh() { ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
            "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
             "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }

if [ "$BUILD" = 1 ]; then
    bash tests/hw-cputest/build.sh "$ROM" || exit 2
fi
[ -f "$ROM" ] || { echo "no $ROM (drop --no-build)" >&2; exit 2; }

# ZERO MAIN MEMORY FIRST, and this is not optional. The log is read out of RAM
# by looking for a magic word, DDR3 survives a core reload, and the guest's own
# memory clear is a stub that moves nothing - so without this a run that never
# started would hand back the PREVIOUS run's log and look like a pass. That
# exact confusion, in the frame buffer rather than in RAM, cost an evening.
log "zeroing main memory so a stale log cannot be read as a new one"
rsh "mkdir -p $DBG"
push tools/misterdeploy/memclear.py
push tools/misterdeploy/ddr3_peek.py
push tests/hw-cputest/read_log.py
rsh "python3 $DBG/memclear.py" | tail -1

log "deploying the suite as the boot PROM"
bash scripts/deploy.sh --rom-only --rom "$ROM" 2>&1 | tail -2 || exit 2

log "launching"
python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
    --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" 2>&1 | tail -1

# THE LOAD STARTS HERE AND NOT EARLIER, and the first version of this got it
# wrong. `launch_unstable_core.py` REBOOTS the MiSTer, so anything started
# before it is killed by that reboot - the run came back a clean pass with no
# contention on it at all, which is the most expensive kind of green. Starting
# it after the launch is the only order that works, and the empty log the first
# attempt left behind is why this now checks that it is actually running.
if [ "$LOAD" = 1 ]; then
    push tools/misterdeploy/hammer.py
    # Shorter than the wait, so it has finished and written its summary by the
    # time the log is read. busybox has no pgrep, so the check is the log line
    # the generator prints on startup.
    rsh "rm -f /tmp/hammer.log; (setsid python3 $DBG/hammer.py $((WAIT - 20)) >/tmp/hammer.log 2>&1 &); sleep 3; cat /tmp/hammer.log"         | sed 's/^/  /'
fi

# The suite is thousands of times more work than a PROM boot and every
# uncached access is a DDR3 round trip. Under Verilator it is 3.5M clocks with
# the caches on and 17M with them off; at 50 MHz that is well under a second of
# machine time, but the FPU and TLB groups are not what dominates - waiting is
# cheap and a truncated log is not.
log "waiting ${WAIT}s"
sleep "$WAIT"

OUT="tests/out/hw-cputest"
mkdir -p "$OUT"
log "=== reading the log out of RAM ==="
rsh "python3 $DBG/read_log.py" 2>&1 | tee "$OUT/hw-cputest.log"
rc=${PIPESTATUS[0]}

if [ "$KEEP" = 0 ]; then
    log "putting the machine's own PROM back"
    bash scripts/deploy.sh --rom-only 2>&1 | tail -1
fi

if [ "$LOAD" = 1 ]; then
    H=$(rsh "cat /tmp/hammer.log 2>/dev/null | tail -1")
    case "$H" in
        hammered*) log "contention generator: $H" ;;
        *)         log "!! NO COMPLETION LINE FROM THE CONTENTION GENERATOR ($H)"
                   log "!! treat this run as UNLOADED - it proves nothing about contention" ;;
    esac
fi

echo
grep -E "RESULT:|IRIS-CPUTEST-DONE" "$OUT/hw-cputest.log" || \
    log "no RESULT line - the suite did not finish; see $OUT/hw-cputest.log"
log "full log: $OUT/hw-cputest.log"
exit $rc
