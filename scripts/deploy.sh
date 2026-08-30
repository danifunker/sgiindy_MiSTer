#!/usr/bin/env bash
# Push this core to a MiSTer and launch it.
#
# Three things have to be on the device before the machine can boot, and only
# one of them is the bitstream:
#
#   1. the .rbf, in a top-level "_" folder the main menu lists;
#   2. /media/fat/games/<GAMES_DIR>/, which MiSTer does NOT create for you -
#      `prefixGameDir` in the framework only *computes* the path
#      (file_io.cpp:1145, with the FileCreatePath call commented out), so a
#      missing directory is silently an absent PROM;
#   3. boot.rom inside it. The framework uploads that file to ioctl index 0 at
#      core start (user_io.cpp:1637) with no OSD interaction, and sgiindy.sv
#      decodes index 0 as the PROM. Without it the CPU fetches zeroes.
#
# The rbf and the ROM are pushed on every run - both are build products and
# neither holds state worth preserving. Anything that IS state (a mounted SCSI
# image, a saved NVRAM once that exists) is left alone.
#
# Usage: bash scripts/deploy.sh [--no-launch] [--rom-only] [--rbf FILE] [--rom FILE]
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi

: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_SSH_USER:=root}"
: "${MISTER_HTTP_PORT:=8182}"
: "${MISTER_CORE_FOLDER:=_Computer}"
: "${RBF_NAME:=sgiindy.rbf}"
# The name the core is filed under ON THE DEVICE. Quartus names its output after
# the project revision (lowercase); MiSTer lists the filename in the OSD and
# `coreRunning` reports it, so the device gets the core's proper name. Fixed
# rather than date-stamped: bring-up re-pushes many times a day and a new
# filename each time buries the menu in dead builds.
: "${RBF_REMOTE:=SGIIndy.rbf}"
: "${MISTER_GAMES_DIR:=SGIIndy}"
: "${PROJECT_NAME:=sgiindy}"

RBF="output_files/$RBF_NAME"
# The PROM is normally the repository's own boot.rom, but it does not have to
# be: tests/hw-cputest builds a boot.rom that IS the CPU test suite, and the
# framework will upload anything at index 0 just the same.
ROM="boot.rom"
LAUNCH=1
ROM_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-launch) LAUNCH=0 ;;
        --rom-only)  ROM_ONLY=1 ;;
        --rbf) RBF="$2"; shift ;;
        --rom) ROM="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

log() { echo "[$(date +%H:%M:%S)] $*"; }
# git-bash rewrites bare "/media/fat/..." arguments into Windows paths.
export MSYS_NO_PATHCONV=1
SSH=(ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY")
SCP=(scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY")
DEV="$MISTER_SSH_USER@$MISTER_HOST"

if [ "$ROM_ONLY" = 0 ]; then
log "=== Verify build artefact ==="
[ -f "$RBF" ] || { log "ERROR: $RBF does not exist - has Quartus run?"; exit 1; }
# Refuse to deploy an rbf left behind by a failed fit: the .fit.summary's first
# line is "Fitter Status : Successful" or "... : Failed".
FIT=$(awk 'NR==1' "output_files/$PROJECT_NAME.fit.summary" 2>/dev/null)
case "$FIT" in
    *Successful*) log "fit: ${FIT#*: }" ;;
    *Failed*)     log "ERROR: Quartus Fitter reported Failed: $FIT"; exit 1 ;;
    *)            log "WARN: no parseable Fitter Status - build state unknown, continuing" ;;
esac
log "rbf: $(ls -l "$RBF" | awk '{print $5}') bytes, $(date -r "$RBF" '+%Y-%m-%d %H:%M')"
fi

log "=== Create the folder structure ==="
# HomeDir() resolves to games/<CoreName> where CoreName is CONF_STR's first
# field. mkdir -p is idempotent, so this also serves as the connectivity check.
# The core folder is created here too: the launcher reads the ROOT menu to find
# it, so it has to exist before anything can navigate to it.
GAMES="/media/fat/games/$MISTER_GAMES_DIR"
CORES="/media/fat/$MISTER_CORE_FOLDER"
"${SSH[@]}" "$DEV" "mkdir -p '$GAMES' '$CORES' && ls -ld '$GAMES' '$CORES'" || {
    log "ERROR: cannot reach $DEV over ssh"; exit 1; }

log "=== Drop the boot PROM ==="
[ -f "$ROM" ] || { log "ERROR: $ROM does not exist"; exit 1; }
"${SCP[@]}" "$ROM" "$DEV:$GAMES/boot.rom" || exit 1
LOCAL_MD5=$(md5sum "$ROM" | awk '{print $1}')
REMOTE_MD5=$("${SSH[@]}" "$DEV" "md5sum '$GAMES/boot.rom'" | awk '{print $1}')
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    log "ERROR: boot.rom md5 mismatch (local $LOCAL_MD5 != remote $REMOTE_MD5)"
    exit 1
fi
log "$ROM -> $GAMES/boot.rom, md5 verified: $LOCAL_MD5"

if [ "$ROM_ONLY" = 1 ]; then
    log "--rom-only: the PROM and its directory are in place, stopping here"
    exit 0
fi

log "=== Push the bitstream ==="
# Pushed here rather than through the launcher's --push, because the launcher
# reads the root menu listing before it pushes, and an empty "_" folder is not
# something to rely on being listed. One copy either way.
"${SCP[@]}" "$RBF" "$DEV:$CORES/$RBF_REMOTE" || exit 1
LOCAL_MD5=$(md5sum "$RBF" | awk '{print $1}')
REMOTE_MD5=$("${SSH[@]}" "$DEV" "md5sum '$CORES/$RBF_REMOTE'" | awk '{print $1}')
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    log "ERROR: rbf md5 mismatch (local $LOCAL_MD5 != remote $REMOTE_MD5)"
    exit 1
fi
log "$RBF -> $CORES/$RBF_REMOTE, md5 verified: $LOCAL_MD5"

if [ "$LAUNCH" = 0 ]; then
    log "--no-launch: stopping here"
    exit 0
fi

# Blind OSD navigation: the screenshot API does not capture the OSD, so the
# launcher counts rows from the live menu listing and then verifies against the
# coreRunning broadcast. A missed keystroke selects the ADJACENT core, which is
# a far more confusing failure than launching nothing.
log "=== Reboot and select it from the OSD ==="
exec python tools/misterdeploy/launch_unstable_core.py     --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT"     --ssh-key "$MISTER_SSH_KEY" --ssh-user "$MISTER_SSH_USER"     --folder "$MISTER_CORE_FOLDER"     --core "$RBF_REMOTE"
