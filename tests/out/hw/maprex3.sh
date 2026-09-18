#!/bin/bash
# quartus_map on np_rex3 alone: what did the rest of the command set cost?
# The module has no children, so its own numbers are the whole answer and a
# two-minute run answers the area question before a forty-minute fit does.
#   bash maprex3.sh [path-to-np_rex3.sv]
set -u
Q="/c/intelFPGA_lite/17.0/quartus/bin64"
WT="/c/Temp/mistercore/sgiindy_MiSTer/.claude/worktrees/modest-robinson-cad59e"
SRC="${1:-$WT/rtl/newport/np_rex3.sv}"
D="$(dirname "$0")/maprex3probe"
rm -rf "$D"; mkdir -p "$D"
cp "$SRC" "$D/np_rex3.sv"
cat > "$D/probe.qsf" <<EOF
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY np_rex3
set_global_assignment -name SYSTEMVERILOG_FILE np_rex3.sv
EOF
cd "$D" || exit 1
"$Q/quartus_map.exe" probe --source=np_rex3.sv 2>&1 | tail -4
echo "---- resource summary ----"
grep -A18 "Analysis & Synthesis Resource Usage Summary" probe.map.rpt | head -24
echo "---- multipliers ----"
grep -iE "multiplier|DSP" probe.map.rpt | head -10
