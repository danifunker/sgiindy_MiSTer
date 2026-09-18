#!/usr/bin/env bash
#
# diskcheck.sh [--fresh PRISTINE.img] [--out FILE] - is the disk path moving the
# right bytes? Boots IRIX, logs in as root, and has IRIX checksum a few files
# with its own `sum` and `sum -r` (reads through the WD33C93 and the HPC3 DMA:
# DATA IN) and copy one of them (DATA OUT), then halts. On the board,
# tools/misterdeploy/sumcheck.py reads the same files straight out of the image
# with efsread.py and compares: IRIX's checksums against the bytes on disk, and
# the copy against its source, byte for byte.
#
# Written for the DMA word batching (docs/design/r4600-accuracy-clock-disk.md): a change there that loses or
# misplaces a byte shows up here as a wrong checksum or a differing copy, where
# a benchmark would only show a faster number.
#
#   MISTER_RBF_PATH=/tmp/SGIIndy.rbf bash scripts/diskcheck.sh --out tests/out/hw/diskcheck-b32.txt
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"; : "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_HTTP_PORT:=8182}"
FRESH=""; OUT="tests/out/hw/diskcheck.txt"
IMG="/media/fat/games/${MISTER_GAMES_DIR:-SGIIndy}/SGIIndy53.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh) FRESH="$2"; shift ;;
        --out)   OUT="$2"; shift ;;
        --img)   IMG="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
# The checker runs from the board's RAM. On a full card a NEW file in sgidbg
# is created empty ("No space left on device"), and python3 runs an empty
# script without a word - the first b32 run reported nothing that way.
TMPD="/tmp/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }
push() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$DBG/"; }
pusht() { scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$1" "$MISTER_SSH_USER@$MISTER_HOST:$TMPD/"; }
ws() { python tools/misterdeploy/ws_send.py --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" "$@" >/dev/null 2>&1; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
rep() { echo "$*" | tee -a "$OUT"; }

# The files IRIX checksums: the kernel (never paged in by the running kernel -
# the PROM loaded it - so every byte comes off the disk), and three shared
# libraries of different sizes. Regular files only: efsread.py returns a
# symlink's text where `sum` follows it (/usr/lib/libc.so.1 is a link to
# /lib/libc.so.1, which is how build 32's first complete run "failed").
FILES="/unix /lib/libc.so.1 /usr/lib/libX11.so.1 /usr/lib/libXm.so.1"
SRC="/unix"; COPY="/root/unix.copy"; SUMS="/root/sums.txt"

rsh "mkdir -p $DBG $TMPD"
for f in tools/misterdeploy/ddr3_peek.py tools/misterdeploy/fb_poke.py \
         tools/misterdeploy/memclear.py tools/misterdeploy/irixstate.py; do push "$f"; done
for f in tools/misterdeploy/efsread.py tools/misterdeploy/sumcheck.py; do pusht "$f" || exit 1; done
rsh "cmp -s $TMPD/sumcheck.py /dev/null && exit 1; python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' $TMPD/sumcheck.py" \
    || { echo "sumcheck.py did not arrive intact on the board" >&2; exit 1; }

if [ -n "$FRESH" ]; then
    say "restoring $IMG from $FRESH (in place, image closed first - see hinv.sh)"
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; for i in \$(seq 1 30); do ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q '$IMG\$' || break; sleep 1; done; cp '$FRESH' '$IMG' && sync" || exit 1
fi
rsh "python3 $DBG/fb_poke.py fill 0xE7; python3 $DBG/memclear.py" >/dev/null 2>&1
RBF_ON_DEVICE="${MISTER_RBF_PATH:-/media/fat/$MISTER_CORE_FOLDER/$RBF_REMOTE}"
rep "core: $(rsh "md5sum $RBF_ON_DEVICE" | cut -c1-32) ($RBF_ON_DEVICE)"
python tools/misterdeploy/launch_unstable_core.py \
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT" \
    --folder "$MISTER_CORE_FOLDER" --core "$RBF_REMOTE" \
    --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER" >/dev/null 2>&1

T0=$(date +%s)
while :; do
    LINE=$(rsh "sleep 20; python3 $DBG/irixstate.py" 2>&1 | tail -1)
    K=$(echo "$LINE" | awk '{print $1}')
    say "$LINE"
    [ "$K" = X-UP ] && break
    [ "$K" = PANIC ] && { rep "PANIC during boot"; exit 1; }
    [ $(( $(date +%s) - T0 )) -ge 480 ] && { rep "no login screen in 480 s"; exit 1; }
done

rsh "sleep 15"
say "parking the pointer, logging in as root"
STEPS=()
for i in $(seq 1 30); do STEPS+=("mouseMove:-60,-60" "sleep:0.05"); done
for i in $(seq 1 39); do STEPS+=("mouseMove:7,10" "sleep:0.05"); done
ws "${STEPS[@]}"
ws "text:root" "sleep:0.3" "kbdRaw:28"
# Software Manager: let it open, quit it, pointer into the Console - see
# clockprobe.sh / perfprobe.sh.
rsh "sleep 55"
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

# No pipes: a `|` typed through the ws API never reaches IRIX's shell as one
# (docs/design/scsi-block-cache.md). The copy is synced before the halt so it is on the disk rather than
# in the buffer cache.
say "checksumming and copying inside IRIX"
ws "text:sum $FILES > $SUMS; sum -r $FILES >> $SUMS; cp $SRC $COPY; sync; sync" "sleep:0.3" "kbdRaw:28"
rsh "sleep 90"
say "halting"
ws "text:init 0" "sleep:0.3" "kbdRaw:28"
rsh "sleep 75"
rep "---- sumcheck on the board ----"
rsh "cd $TMPD; python3 sumcheck.py '$IMG' $SUMS $SRC $COPY $FILES" 2>&1 | tee -a "$OUT"
grep -q "^DISKCHECK " "$OUT" || { rep "DISKCHECK NO VERDICT (the checker printed nothing)"; exit 1; }
say "report -> $OUT"
