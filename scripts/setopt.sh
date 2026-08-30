#!/usr/bin/env bash
# setopt.sh [name=value ...] - set the core's OSD options without the OSD.
#
# MiSTer keeps a core's OSD state in /media/fat/config/<CORENAME>.CFG: sixteen
# bytes, the 128-bit `status` word, little-endian bit order (bit N is bit N%8 of
# byte N/8). It is read once when the core starts, so this writes the file and
# the caller relaunches.
#
# THIS EXISTS BECAUSE DRIVING THE OSD BLIND DOES NOT WORK WELL ENOUGH. The
# screenshot API does not capture the OSD, so a keystroke sequence cannot be
# verified, and a miscounted row silently changes the wrong option - which
# during bring-up is indistinguishable from the change having no effect. The
# CFG file is exact and it is checkable.
#
# Names match CONF_STR in sgiindy.sv. Keep them in step.
#
#   gfx=none|fitted      O[10]     graphics board
#   cache=on|off         O[11]     primary caches
#   mem=48|32|64         O[13:12]  memory size
#   viddbg=off|raw       O[14]     show the frame buffer index, no palette
#   uartdbg=off|sys|ser  O[16:15]  0x55 test pattern from clk_sys or sclk
#
# Usage: bash scripts/setopt.sh gfx=none uartdbg=ser
#        bash scripts/setopt.sh            # all defaults
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_SSH_USER:=root}"
: "${MISTER_GAMES_DIR:=SGIIndy}"

export MSYS_NO_PATHCONV=1
TMP=$(mktemp)
python - "$@" > "$TMP" <<'PY'
import sys
FIELDS = {                       # name: (low bit, width, {value: code})
    "gfx":     (10, 1, {"fitted": 0, "none": 1}),
    "cache":   (11, 1, {"on": 0, "off": 1}),
    "mem":     (12, 2, {"48": 0, "32": 1, "64": 2}),
    "viddbg":  (14, 1, {"off": 0, "raw": 1}),
    "uartdbg": (15, 2, {"off": 0, "sys": 1, "ser": 2}),
}
st = 0
for arg in sys.argv[1:]:
    if "=" not in arg:
        sys.exit(f"expected name=value, got {arg!r}")
    k, v = arg.split("=", 1)
    if k not in FIELDS:
        sys.exit(f"unknown option {k!r}; known: {', '.join(FIELDS)}")
    lo, w, vals = FIELDS[k]
    if v not in vals:
        sys.exit(f"{k}: expected one of {', '.join(vals)}, got {v!r}")
    st |= vals[v] << lo
sys.stderr.write(f"status = 0x{st:032x}\n")
sys.stdout.buffer.write(st.to_bytes(16, "little"))
PY
RC=$?
[ $RC -eq 0 ] || { rm -f "$TMP"; exit $RC; }

CFG="/media/fat/config/$(echo "$MISTER_GAMES_DIR" | tr '[:lower:]' '[:upper:]').CFG"
scp -q -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" "$TMP" \
    "$MISTER_SSH_USER@$MISTER_HOST:$CFG"
rm -f "$TMP"
ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
    "$MISTER_SSH_USER@$MISTER_HOST" "od -An -tx1 '$CFG'"
echo "wrote $CFG - relaunch the core for it to take effect"
