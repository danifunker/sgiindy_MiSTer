#!/usr/bin/env bash
#
# perfprobe.sh [--tag T] [--fresh PRISTINE.img] [--no-boot] [--skip LIST]
#
# Where does an IRIX session's time go on this core? Boots IRIX with the
# beacon profiler running (tools/misterdeploy/prof.py), logs in as root by the
# hinv.sh recipe, then types a fixed set of workloads into the desktop's
# Console, each timed by bash's `time` into /root/bench.txt and each profiled
# on the board until the machine has been idle for a few seconds:
#
#   fork    60 x /bin/ls / - fork/exec/exit, what the rc scripts do
#   perl    an interpreter loop - user-space CPU
#   bzip2   bzip2 -9 of /unix - CPU over a large working set
#   rawdisk 10 MB off the raw root partition - the SCSI byte path
#   scroll  ls -lR /usr/lib/X11 into the Console - X drawing text and scrolling
#   xterm   an xterm started, drawn and closed, twice - an application start
#           (xwsh detaches, so its `time` measures nothing)
#   xdpy    xdpyinfo to /dev/null - X client start and protocol round trips
#
# Software Manager opens by itself ~30 s after a root login, ON TOP of the
# Console, and takes typed keys; it is quit through its File menu and the
# pointer is walked into the Console in 4-pixel steps (1:1, below X's
# acceleration threshold) before anything is typed. The screen is grabbed to
# screen-ready.png so a run can be checked. `bcnread.py --perf` readings of
# the performance counters (beacon ver 10, docs/design/cpu-speed-tlb-icache.md) go into perf.log around
# every workload; tools/misterdeploy/perfdiff.py turns two into a breakdown.
#
# Then `init 0`, and /root/bench.txt comes off the image with efsread.py. The
# captures land in tests/out/hw/perf-TAG/ with profan.py's report beside each
# (set SO_LOCATIONS to a copy of the image's /usr/lib/so_locations to name
# user text). Nothing here needs a fit: the beacon's word 10 has carried the
# PC and the pipeline's stall vector since build 12.
#
#   bash scripts/perfprobe.sh --tag b27 --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
TAG="perf"; FRESH=""; BOOT=1; SKIP=""
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)     TAG="$2"; shift ;;
        --fresh)   FRESH="$2"; shift ;;
        --img)     IMG="$2"; shift ;;
        --no-boot) BOOT=0 ;;
        --skip)    SKIP="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
OUTD="tests/out/hw/perf-$TAG"
mkdir -p "$OUTD"
LOG="$OUTD/run.log"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
pull() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST:$1" "$2"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
skipped() { case ",$SKIP," in *",$1,"*) return 0 ;; esac; return 1; }

rsh "mkdir -p $DBG"
for f in ddr3_peek.py fb_poke.py memclear.py irixstate.py bcnread.py efsread.py prof.py; do
    push "tools/misterdeploy/$f"
done

if [ "$BOOT" = 1 ]; then
    bash scripts/setopt.sh >/dev/null || exit 1
    if [ -n "$FRESH" ]; then
        say "restoring $IMG from $FRESH"
        # Restore IN PLACE, with the image closed first. Renaming a fresh copy over
        # the attached image (what every --fresh restore did until 2026-09-16) left
        # the old file unlinked while MiSTer still held it open, and the board's exFAT
        # driver never gave those clusters back: after two weeks of runs ~37 GB of the
        # 59 GB card belonged to no file, a reboot did not return it, and a restore
        # failed with ENOSPC (docs/design/cpu-speed-tlb-icache.md). Loading the menu core closes the image - so a
        # guest still running cannot write into the fresh copy either - and the copy
        # then overwrites the same file, needing no free space.
        rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$FRESH' '$IMG' && sync" || exit 1
    fi
    rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
    RBF_ON_DEVICE="${MISTER_RBF_PATH:-/media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE}"
    say "launching $(rsh "md5sum $RBF_ON_DEVICE" | cut -c1-32) ($RBF_ON_DEVICE)"
    python tools/misterdeploy/launch_unstable_core.py \
        --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
        --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
        --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1
    T0=$(date +%s)
    # The whole boot at 250 Hz, in the background on the board; it stops by itself.
    rsh "cd /tmp; nohup python3 $DBG/prof.py --out /tmp/perf-boot.bin --secs 360 --hz 250 --quiet >/dev/null 2>&1 &"
    say "core launched; boot profile running"
    while :; do
        LINE=$(rsh "sleep 10; python3 $DBG/irixstate.py" 2>&1 | tail -1)
        K=$(echo "$LINE" | awk '{print $1}')
        say "+$(( $(date +%s) - T0 ))s $LINE"
        [ "$K" = X-UP ] && break
        [ "$K" = PANIC ] && { say "panicked, giving up"; exit 1; }
        [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s"; exit 1; }
    done
    say "X-UP at +$(( $(date +%s) - T0 ))s after the launch returned"
    rsh "sleep 15"
    say "parking the pointer, logging in as root (login profile until idle)"
    STEPS=()
    for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
    for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
    ws "${STEPS[@]}"
    TL=$(date +%s)
    ws "text:root" "sleep:0.3" "kbdRaw:28"
    rsh "python3 $DBG/prof.py --out /tmp/perf-login.bin --secs 240 --min 45 --until-idle 8 --hz 500" 2>&1 | tee -a "$LOG"
    say "login settled after $(( $(date +%s) - TL )) s"
    rsh "sleep 5"
    say "quitting Software Manager, pointer into the Console"
    # into the top-left corner (clamped), then 4-pixel steps: 1:1
    STEPS=()
    for i in $(seq 1 40); do STEPS+=("mouseMove:-40,-40" "sleep:0.02"); done
    for i in $(seq 1 17); do STEPS+=("mouseMove:4,0" "sleep:0.02"); done
    for i in $(seq 1 11); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
    ws "${STEPS[@]}"
    ws "mouseBtn:left" "sleep:1.5"                      # File, at (68,44)
    STEPS=()
    for i in $(seq 1 57); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
    ws "${STEPS[@]}"
    ws "mouseBtn:left" "sleep:3"                        # Quit, at (68,272)
    STEPS=()
    for i in $(seq 1 108); do STEPS+=("mouseMove:4,0" "sleep:0.02"); done
    for i in $(seq 1 82); do STEPS+=("mouseMove:0,4" "sleep:0.02"); done
    ws "${STEPS[@]}"                                    # the Console, (500,600)
    rsh "sleep 3"
    bash scripts/grab.sh "$OUTD/screen-ready.png" >/dev/null 2>&1
fi

rsh "python3 $DBG/prof.py --out /tmp/perf-idle.bin --secs 15 --hz 500" 2>&1 | tee -a "$LOG"

# name, the line typed into the Console, and the least number of seconds to
# profile before an idle machine may end the capture (a disk read leaves the
# CPU idle while it waits, which would otherwise look like the end)
run_bench() {
    local name="$1" line="$2" mins="${3:-4}"
    if skipped "$name"; then say "skipping $name"; return; fi
    say "bench $name: $line"
    rsh "python3 $DBG/bcnread.py --perf" 2>&1 | sed "s/^/$name before: /" >> "$OUTD/perf.log"
    ws "text:echo == $name >> /root/bench.txt; { time $line ; } 2>> /root/bench.txt" "sleep:0.3" "kbdRaw:28"
    local t=$(date +%s)
    rsh "python3 $DBG/prof.py --out /tmp/perf-$name.bin --secs 600 --min $mins --until-idle 4 --hz 1000" 2>&1 | tee -a "$LOG"
    say "bench $name idle after $(( $(date +%s) - t )) s (host clock, includes typing and 4 s of idle)"
    rsh "python3 $DBG/bcnread.py --perf" 2>&1 | sed "s/^/$name after: /" >> "$OUTD/perf.log"
    rsh "sleep 3"
}

run_bench fork    'for i in $(/usr/tgcware/bin/seq 1 60); do /bin/ls / > /dev/null; done'
run_bench perl    "/usr/bin/perl -e 'for(\$i=0;\$i<200000;\$i++){\$s+=\$i%7}'"
run_bench bzip2   '/usr/tgcware/bin/bzip2 -9 -c /unix > /tmp/unix.bz2'
run_bench rawdisk '/bin/dd if=/dev/rdsk/dks0d1s0 of=/dev/null bs=65536 count=160' 25
run_bench scroll  '/bin/ls -lR /usr/lib/X11'
run_bench xterm   '/usr/bin/X11/xterm -e /bin/true'
run_bench xterm2  '/usr/bin/X11/xterm -e /bin/true'
run_bench xdpy    '/usr/bin/X11/xdpyinfo > /dev/null'
bash scripts/grab.sh "$OUTD/screen-after-bench.png" >/dev/null 2>&1

say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 75"
rsh "cd $DBG; python3 efsread.py '$IMG' cat /root/bench.txt" > "$OUTD/bench.txt" 2>&1
say "bench.txt:"; cat "$OUTD/bench.txt" | tee -a "$LOG"

for f in boot login idle fork perl bzip2 rawdisk scroll xterm xterm2 xdpy; do
    if rsh "test -f /tmp/perf-$f.bin"; then
        pull "/tmp/perf-$f.bin" "$OUTD/perf-$f.bin"
        python tools/misterdeploy/profan.py "$OUTD/perf-$f.bin" --series 10 > "$OUTD/perf-$f.txt" 2>&1
    fi
done
say "done -> $OUTD"
