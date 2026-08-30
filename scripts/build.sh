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

# THE REGISTER COUNT IS CHECKED BETWEEN SYNTHESIS AND THE FITTER, and that is
# the whole reason this script runs the stages itself rather than calling
# `--flow compile`. An array that fails to infer as memory becomes flip-flops
# SILENTLY - Info (276014) lists the arrays Quartus could see and says nothing
# at all about the ones it could not - and the first symptom is a fit that
# fails at 291% of the device twenty minutes later. That has now happened
# twice. Synthesis takes three minutes; the fitter takes twenty-five.
: "${MAX_REGISTERS:=60000}"

log "=== quartus_map (synthesis) ==="
"$SH_EXE" --flow analysis_and_synthesis "$PROJECT_NAME" > "$LOG" 2>&1
RC=$?
MAPSUM="output_files/$PROJECT_NAME.map.summary"
if [ $RC -ne 0 ] || [ ! -f "$MAPSUM" ]; then
    log "ERROR: synthesis failed ($RC). Errors from the log:"
    grep -E "^Error|Error \([0-9]+\)" "$LOG" | head -20 | sed 's/^/    /'
    exit 1
fi
REGS=$(awk -F': *' '/Total registers/ {gsub(/[^0-9]/,"",$2); print $2}' "$MAPSUM")
log "Total registers: $REGS (ceiling $MAX_REGISTERS)"
if [ -n "$REGS" ] && [ "$REGS" -gt "$MAX_REGISTERS" ]; then
    log "ERROR: $REGS registers. An array did not infer as memory."
    log "  Around 39,000 is right for this design. Hundreds of thousands means"
    log "  a storage array became flip-flops. Grep the log for Info (276014),"
    log "  but note the dangerous case produces NO message - compare the"
    log "  Fitter's RAM block count with what you expected instead."
    grep -E "Info \(2760(03|04|07|14)\)" "$LOG" | sed 's/^[[:space:]]*//' | sed 's/^/    /'
    log "  Refusing to run the fitter. See the memory note on RAM inference."
    exit 1
fi
if grep -q "Found .* instances of uninferred RAM logic" "$LOG"; then
    log "--- uninferred RAM (each one is an array that became flip-flops) ---"
    grep -E "Info \(2760(03|04|07|14)\)" "$LOG" | sed 's/^[[:space:]]*//' | sed 's/^/    /'
fi

log "=== quartus_fit, quartus_asm, quartus_sta ==="
for STAGE in fit asm sta; do
    "$QUARTUS_BIN/quartus_$STAGE" "$PROJECT_NAME" -c "$PROJECT_NAME" >> "$LOG" 2>&1 || {
        log "ERROR: quartus_$STAGE failed. Errors from the log:"
        grep -E "^Error|Error \([0-9]+\)" "$LOG" | head -20 | sed 's/^/    /'
        exit 1; }
    log "  $STAGE done"
done

FITSUM="output_files/$PROJECT_NAME.fit.summary"
STASUM="output_files/$PROJECT_NAME.sta.summary"
[ -f "$FITSUM" ] && { log "--- fit summary ---"; sed -n '1,14p' "$FITSUM" | sed 's/^/    /'; }
[ -f "$STASUM" ] && { log "--- worst slack per clock ---"; grep -A 2 "^Type  : Setup" "$STASUM" | sed 's/^/    /' | head -30; }

if [ -f "output_files/$PROJECT_NAME.rbf" ]; then
    log "OK: output_files/$PROJECT_NAME.rbf ($(ls -l "output_files/$PROJECT_NAME.rbf" | awk '{print $5}') bytes)"
else
    log "ERROR: no rbf produced."
    exit 1
fi
