#!/usr/bin/env bash
#
# bootrate.sh [N] [--no-memclear] [--poison HH] - launch the core N times and
# classify how each boot ended.
#
# WHY A SCRIPT AND NOT A LOOP IN SOMEBODY'S SHELL. This core's remaining
# hardware fault is intermittent: with main memory zeroed the machine draws its
# whole boot screen every time, and then about one boot in three panics instead
# of reaching the diskless prompt. A single launch says nothing about a fault
# like that, and "I ran it a few times and it seemed better" says less. The
# number is the measurement, so it needs to be cheap to take.
#
# THE OUTCOME IS READ OUT OF THE FRAME BUFFER, NOT OFF A SCREENSHOT, and the
# two end states are trivially separable there: both draw the same boot screen
# and then a panel, and the panel's text is a few hundred pixels of
# "Unable to boot; press any key to continue:" or a few thousand of a PROM
# exception box. A photograph cannot be counted; index 7 can.
#
# Both of the board's hidden states are reset before every launch, because DDR3
# survives a core reload and neither of them resets itself:
#   - the frame buffer, marked with 0xE7, so a stale picture from the previous
#     boot cannot be counted as this one's;
#   - main memory, zeroed, because the guest's own clear is a stub that moves
#     nothing and a boot on inherited memory does not draw at all.
# --no-memclear exists to demonstrate that second one rather than to be used.
#
# --poison HH is the strict form and the one that proves the GIO64 DMA engine:
# it fills main memory with a byte pattern before EVERY launch instead of
# clearing it, so the machine has to clear its own memory to get anywhere. On
# the bitstream before that engine existed, `--poison a5` never drew once.
#
#   bash scripts/bootrate.sh 10
#   bash scripts/bootrate.sh 8 --poison a5
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"

N=10; MEMCLEAR=1; WAIT=45; POISON=""
DISK1=""; DISK2=""; CD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-memclear) MEMCLEAR=0 ;;
        --poison)      POISON="$2"; MEMCLEAR=0; shift ;;
        --wait) WAIT="$2"; shift ;;
        --disk1) DISK1="$2"; shift ;;
        --disk2) DISK2="$2"; shift ;;
        --cd)    CD="$2";    shift ;;
        [0-9]*) N="$1" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# WITH MEDIA ATTACHED THIS IS A DIFFERENT MEASUREMENT, and it has to be taken
# the same way as the one without or the two cannot be compared. It was worth
# taking: before the memory arbiter was fixed the panic rate roughly doubled
# once a SCSI target answered, because a target answering is what makes the
# HPC3 DMA engine a second master on main memory.
#
# The images are attached by writing the core's SAVED SCSI SLOTS - scripts/
# mount.sh does that and stops - and then the core is launched the ordinary
# way, because the framework re-attaches them itself at every start. So a run
# with media and a run without differ only in what is in the machine, not in
# how it was started. That is the point of the `SC` slots; an MGL, which is
# what this used to use, attaches for one launch and is gone on the next.
MEDIA=0
[ -n "$DISK1$DISK2$CD" ] && MEDIA=1

export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
            "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
             "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }

rsh "mkdir -p $DBG"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py; do push "$f"; done

# Classification runs on the device: reading 1.3 MB of frame buffer over ssh
# for every launch is the slow way to count two numbers.
rsh "cat > $DBG/classify.py" <<'PYEOF'
import importlib.util, hashlib, time
from collections import Counter
spec = importlib.util.spec_from_file_location("p", "/media/fat/sgidbg/ddr3_peek.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W, H, S, FB = 1280, 1024, 2048, 0x34000000

def sample():
    c = Counter()
    for y in range(0, H, 4):
        c.update(m.read_phys(FB + (y * S) * 8, W * 8)[0::8])
    return c

a = sample(); time.sleep(20); b = sample()
t = sum(b.values())
panel = 100.0 * b.get(10, 0) / t          # the dialog's background index
text  = b.get(7, 0)                       # its text index
mark  = 100.0 * b.get(0xE7, 0) / t        # what fb_poke left

if   mark > 50:   v = "NEVER-DREW"
elif panel < 5:   v = "NO-PANEL"
elif text > 2000: v = "PANIC"
elif text > 300:  v = "healthy"
else:             v = "UNKNOWN"
print("%-11s panel %5.1f%%  text %5d  indices %3d  marker %4.1f%%  %s"
      % (v, panel, text, len(b), mark, "moving" if a != b else "static"))
PYEOF

if [ "$MEDIA" = 1 ]; then
    # scripts/mount.sh writes the saved SCSI slots and stops. From here the
    # core is launched normally and the framework attaches them itself, so
    # a run with media and a run without differ only in what is in the
    # machine - not in how it was started, which is what makes the two
    # panic rates comparable.
    ARGS=""
    [ -n "$DISK1" ] && ARGS="$ARGS --disk1 \"$DISK1\""
    [ -n "$DISK2" ] && ARGS="$ARGS --disk2 \"$DISK2\""
    [ -n "$CD" ]    && ARGS="$ARGS --cd \"$CD\""
    eval bash scripts/mount.sh --no-launch $ARGS || exit 1
fi

echo "=== $N launches, ${WAIT}s each, memory: $([ -n "$POISON" ] && echo "POISONED 0x$POISON"       || { [ $MEMCLEAR = 1 ] && echo zeroed || echo "left as the last boot left it"; }) ==="
declare -A TALLY
for i in $(seq 1 "$N"); do
    rsh "python3 $DBG/fb_poke.py fill 0xE7" >/dev/null 2>&1
    [ "$MEMCLEAR" = 1 ] && rsh "python3 $DBG/memclear.py" >/dev/null 2>&1
    [ -n "$POISON" ]    && rsh "python3 $DBG/memclear.py 0x$POISON" >/dev/null 2>&1
    python tools/misterdeploy/launch_unstable_core.py \
        --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
        --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
        --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1
    # THE SETTLE WAITS ON THE DEVICE. classify.py samples twice 20 s apart,
    # so this is the rest of WAIT - and a foreground sleep here is refused by
    # some harnesses, while the ssh call has to be made anyway.
    LINE=$(rsh "sleep $((WAIT > 20 ? WAIT - 20 : 5)); python3 $DBG/classify.py" 2>&1 | tail -1)
    printf "  %2d/%-2d  %s\n" "$i" "$N" "$LINE"
    K=$(echo "$LINE" | awk '{print $1}')
    TALLY[$K]=$(( ${TALLY[$K]:-0} + 1 ))
done

echo "=== tally over $N launches ==="
for k in "${!TALLY[@]}"; do printf "  %-11s %d\n" "$k" "${TALLY[$k]}"; done
