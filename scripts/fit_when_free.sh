#!/usr/bin/env bash
# fit_when_free.sh - wait until no Quartus process is running on this box,
# then run the full flow (scripts/build.sh) once. Another session on this
# machine fits MacQuadra800; two fits at once thrash and both take twice as
# long, so a fit here queues behind whatever Quartus is already doing.
#
#   SEED=2 bash scripts/fit_when_free.sh b23     # logs to b23.log / b23.status
#
# Launch it detached (it outlives any tool timeout) - from PowerShell:
#   Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
#     CommandLine = '"C:\Program Files\Git\bin\bash.exe" -c "SEED=2 exec bash scripts/fit_when_free.sh b23 </dev/null >b23.console 2>&1"';
#     CurrentDirectory = '<repo>' }
# Quartus is detected through PowerShell's Get-Process: tasklist is not on
# every PATH, and a WSL shell cannot see Windows processes at all.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TAG="${1:-fit}"
STATUS="$TAG.status"
quartus_count() {
    powershell.exe -NoProfile -Command '(Get-Process | Where-Object { $_.ProcessName -match "quartus" } | Measure-Object).Count' 2>/dev/null | tr -d '\r '
}
free=0
while :; do
    n="$(quartus_count)"; n="${n:-0}"
    if [ "$n" = "0" ]; then free=$((free + 1)); else free=0; fi
    echo "$(date +%H:%M:%S) quartus=$n free=$free" >> "$STATUS"
    # Two consecutive clear readings, 15 s apart: one can land between the
    # other session's synthesis and fitter stages.
    [ "$free" -ge 2 ] && break
    sleep 15
done
echo "$(date +%H:%M:%S) quartus free; launching SEED=${SEED:-1} fit" >> "$STATUS"
SEED="${SEED:-1}" bash scripts/build.sh --log "$TAG.log"
rc=$?
echo "$(date +%H:%M:%S) build.sh rc=$rc" >> "$STATUS"
exit $rc
