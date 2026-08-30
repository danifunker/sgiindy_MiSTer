#!/usr/bin/env bash
# Run the full Quartus flow for the MiSTer top level: map, fit, assemble, STA.
# ~45 minutes on this design. Writes output_files/sgiindy.rbf.
#
# Two things this checks that a green exit code does not:
#  * "Info (276014): Found N instances of uninferred RAM logic" in the map log.
#    An array that quietly becomes flip-flops costs tens of thousands of
#    registers and is why the first fit of this core missed the device by 1.78x.
#  * Total registers in the map summary. ~39k is right for this design; a
#    number in the hundreds of thousands is an array that did not infer.
#
# DO NOT TOUCH sgiindy.qsf WHILE THIS IS RUNNING, and that includes `git
# checkout`. Quartus watches the settings file; if it changes underneath it the
# compile stops with "Error (125085): The Quartus Prime Settings File changed
# outside of the Quartus Prime software" and then REWRITES IT - inlining
# everything sys/sys.tcl sources, 266 lines of pin assignments, which is exactly
# what the warning at the top of that file means by "It will mess this file!".
# The compile dies in synthesis and the diff looks like the project exploded.
# Restore it with `git checkout -- sgiindy.qsf` and start again from a clean db/.
#
# Quartus also rewrites LAST_QUARTUS_VERSION to "Lite Edition" on every run of
# this build, which is a one-line diff to discard rather than commit.
#
# Usage: bash scripts/build.sh [--log FILE]
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${QUARTUS_BIN:=/c/intelFPGA_lite/17.0/quartus/bin64}"
: "${PROJECT_NAME:=sgiindy}"

LOG="build_full.log"
[ "${1:-}" = "--log" ] && LOG="$2"

log() { echo "[$(date +%H:%M:%S)] $*"; }
[ -x "$QUARTUS_BIN/quartus_sh.exe" ] || [ -x "$QUARTUS_BIN/quartus_sh" ] || {
    log "ERROR: no quartus_sh under $QUARTUS_BIN (set QUARTUS_BIN in scripts/local.env)"
    exit 1; }
SH_EXE="$QUARTUS_BIN/quartus_sh.exe"; [ -x "$SH_EXE" ] || SH_EXE="$QUARTUS_BIN/quartus_sh"

log "=== quartus_sh --flow compile $PROJECT_NAME ==="
"$SH_EXE" --flow compile "$PROJECT_NAME" > "$LOG" 2>&1
RC=$?
log "quartus exited $RC; log in $LOG"

MAPSUM="output_files/$PROJECT_NAME.map.summary"
FITSUM="output_files/$PROJECT_NAME.fit.summary"
STASUM="output_files/$PROJECT_NAME.sta.summary"

if grep -q "Found .* instances of uninferred RAM logic" "$LOG"; then
    log "--- uninferred RAM (each one is an array that became flip-flops) ---"
    grep -E "Info \(276014\)|Info \(2760(03|04|07|20)\)" "$LOG" | sed 's/^/    /'
fi
[ -f "$MAPSUM" ] && { log "--- map summary ---"; grep -E "Total (registers|logic|RAM)|Analysis" "$MAPSUM" | sed 's/^/    /'; }
[ -f "$FITSUM" ] && { log "--- fit summary ---"; sed -n '1,20p' "$FITSUM" | sed 's/^/    /'; }
[ -f "$STASUM" ] && { log "--- timing ---"; sed -n '1,40p' "$STASUM" | sed 's/^/    /'; }

if [ -f "output_files/$PROJECT_NAME.rbf" ]; then
    log "OK: output_files/$PROJECT_NAME.rbf ($(ls -l "output_files/$PROJECT_NAME.rbf" | awk '{print $5}') bytes)"
else
    log "ERROR: no rbf produced. Errors from the log:"
    grep -E "^Error|Error \([0-9]+\)" "$LOG" | head -20 | sed 's/^/    /'
    exit 1
fi
exit $RC
