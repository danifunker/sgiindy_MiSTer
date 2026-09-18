#!/usr/bin/env bash
#
# saverprobe.sh [--tag T] [--fresh PRISTINE.img] [--no-boot] [--only LIST]
#
# Does the screen saver draw? Boots IRIX, logs in as root by perfprobe.sh's
# recipe, walks the pointer into the Console and runs each of the desktop's
# savers in turn, grabbing the monitor three times through each one so that a
# still picture can be told from a moving one.
#
# WHY THE SAVERS ARE THE TEST. /usr/lib/X11/savers/defaults lists fourteen and
# they split two ways. The xlock ones - qix, swarm, rotor, pyro, flame, hop -
# draw X lines and points, which is REX3's I_LINE and F_LINE address modes and
# nothing the engine could do before build 43. The two GL ones run
# /usr/sbin/haven over /usr/demos/bin/ep (ElectroPaint) and
# /usr/demos/bin/bongo (Octahedra): shaded, dithered, blended spans into a
# 12-bit double-buffered window, which is the colour DDAs, the dither and the
# blend. Between them they cover the whole of what docs/design/rex3-rendering.md added.
#
# Each saver is started by a guest shell that also kills it after a fixed
# time, because a saver that grabs the screen and the keyboard cannot be
# stopped by typing at it. The grabs land in tests/out/hw/saver-TAG/ next to a
# log.
#
#   bash scripts/saverprobe.sh --tag b43 --fresh /media/fat/games/SGIIndy/SGIIndy53-pristine.img
#   bash scripts/saverprobe.sh --tag b43 --no-boot --only ep,bongo
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
TAG="saver"; FRESH=""; BOOT=1; ONLY=""
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)     TAG="$2"; shift ;;
        --fresh)   FRESH="$2"; shift ;;
        --img)     IMG="$2"; shift ;;
        --no-boot) BOOT=0 ;;
        --only)    ONLY="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

DBG="/media/fat/sgidbg"
OUTD="tests/out/hw/saver-$TAG"
mkdir -p "$OUTD"
LOG="$OUTD/run.log"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
wanted() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }
: > "$LOG"

rsh "mkdir -p $DBG"
for f in fb_poke.py memclear.py irixstate.py efsread.py; do push "tools/misterdeploy/$f"; done

if [ "$BOOT" = 1 ]; then
    bash scripts/setopt.sh >/dev/null || exit 1
    if [ -n "$FRESH" ]; then
        say "restoring $IMG from $FRESH (in place; see perfprobe.sh)"
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
    while :; do
        LINE=$(rsh "sleep 10; python3 $DBG/irixstate.py" 2>&1 | tail -1)
        K=$(echo "$LINE" | awk '{print $1}')
        say "+$(( $(date +%s) - T0 ))s $LINE"
        [ "$K" = X-UP ] && break
        [ "$K" = PANIC ] && { say "panicked, giving up"; exit 1; }
        [ $(( $(date +%s) - T0 )) -ge 480 ] && { say "no login screen in 480 s"; exit 1; }
    done
    say "X-UP at +$(( $(date +%s) - T0 ))s"
    rsh "sleep 15"
    say "logging in as root"
    STEPS=()
    for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
    for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
    ws "${STEPS[@]}"
    ws "text:root" "sleep:0.3" "kbdRaw:28"
    rsh "sleep 90"                      # the desktop, then Software Manager
    say "quitting Software Manager, pointer into the Console"
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
    ws "text:xset m 0 0" "sleep:0.3" "kbdRaw:28"        # 1:1 pointer from here
    rsh "sleep 1"
    ws "text:set +H" "sleep:0.3" "kbdRaw:28"           # no history expansion
    rsh "sleep 2"
    bash scripts/grab.sh "$OUTD/00-desktop.png" | tee -a "$LOG"
fi

# name, the command line typed into the Console, seconds between grabs.
saver() {
    local name="$1" cmd="$2" gap="${3:-9}"
    if ! wanted "$name"; then say "skipping $name"; return; fi
    local live=$(( gap * 3 + 6 ))
    say "saver $name (${live}s): $cmd"
    # THE SAVER KILLS ITSELF. A saver that grabs the screen and the keyboard
    # cannot be stopped by typing at it, and haven does exactly that - so the
    # guest gets a shell that starts it, waits, and kills it.
    #
    # THE SINGLE QUOTES ARE NOT DECORATION. Root's shell on this image is an
    # interactive bash, which does history expansion BEFORE it parses the
    # line - so a bare `$!` became `-bash: !: event not found` and the saver
    # never ran at all, three times through every mode, with the screen
    # sitting on the desktop looking exactly like a rasteriser that draws
    # nothing. Single quotes are one of the two things that quote the history
    # character, and `sh -c` then reads what is inside them. `set +H` is sent
    # once as well, for the shell that gets this wrong anyway.
    ws "text:sh -c '$cmd > /root/s-$name.log 2>&1 & SP=\$!; sleep $live; kill \$SP' &"        "sleep:0.3" "kbdRaw:28"
    local i
    for i in 1 2 3; do
        sleep "$gap"
        bash scripts/grab.sh "$OUTD/$name-$i.png" | tee -a "$LOG"
    done
    sleep 12                                            # let it die by itself
    ws "kbdRaw:1" "sleep:0.3"                           # Escape, if it grabbed
    sleep 3
    bash scripts/grab.sh "$OUTD/$name-after.png" >/dev/null 2>&1
}

# FIRST A CONTROL THAT CANNOT FAIL QUIETLY. xclock's analogue face is drawn
# with lines and arcs and its second hand moves every update, so if these
# three grabs differ the line path works and anything that follows and does
# NOT move is that program's problem rather than the rasteriser's. It is the
# cheapest way to tell "REX3 draws nothing" from "the saver never started",
# which is a distinction two runs of this script have already got wrong.
saver xclock '/usr/bin/X11/xclock -update 1 -geometry 300x300+420+140'

# WHAT X THINKS IT IS RUNNING ON. The first run that got this far showed the
# GL demos drawing correct geometry in wrong colours, and the colours changing
# under each other - the pixel indices stable, the colour map not. That is a
# visual/colormap question and these two answer it: how many bits Xsgi gave
# itself and which visuals it offers, and what the gfx driver thinks the board
# is. Both print and exit, so the grabs around them are incidental.
saver xdpy   '/usr/bin/X11/xdpyinfo' 2
saver gfxinf '/usr/gfx/gfxinfo' 2
saver xlsvis '/usr/bin/X11/xdpyinfo -queryExtensions' 2

# The 2D savers: X lines and points, which is I_LINE and F_LINE. Plain first,
# then the form the desktop's saver framework actually uses - -besaver makes
# xlock expect to be a child of ssaver, and it is worth knowing which of the
# two is the one that does not run.
saver qixw   '/usr/bin/X11/xlock -mode qix -nolock'
saver qix    '/usr/bin/X11/xlock -mode qix -besaver'
saver swarm  '/usr/bin/X11/xlock -mode swarm -besaver'
saver rotor  '/usr/bin/X11/xlock -mode rotor -besaver'

# The GL ones. Run DIRECTLY as well as through haven: haven is the saver
# wrapper that makes the full-screen window, so a demo that draws on its own
# and not under haven says the wrapper is the problem, not GL.
saver bongo  '/usr/demos/bin/bongo'
saver ep     '/usr/demos/bin/ep'
saver butter '/usr/demos/bin/buttonfly'
saver havep  '/usr/sbin/haven -n /usr/demos/bin/ep -S'

say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 75"

# WHAT EACH ONE SAID. The guest is halted, so these come out of the image
# with efsread rather than off a running machine - and they are the whole
# difference between "it drew nothing" and "it never started".
say "what each client printed:"
for f in $(rsh "cd $DBG && python3 efsread.py '$IMG' ls /root 2>/dev/null | awk '/ s-.*\\.log/ {print \$3}'"); do
    echo "---- $f ----" | tee -a "$LOG"
    rsh "cd $DBG && python3 efsread.py '$IMG' cat /root/$f" 2>&1 | head -20 | tee -a "$LOG"
done
say "done -> $OUTD"
