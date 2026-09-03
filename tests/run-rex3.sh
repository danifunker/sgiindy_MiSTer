#!/usr/bin/env bash
#
# run-rex3.sh - check every pixel REX3 drew against every command it was given.
#
# THIS IS THE ONLY TEST IN THE REPOSITORY THAT CAN TELL A RASTERISER THAT DRAWS
# THE WRONG THING FROM ONE THAT DRAWS THE RIGHT THING. A boot with graphics
# fitted produces a picture, and a picture is inspectable only by eye - which
# is how three separate defects survived a whole session of work on it, none of
# them making the machine hang, fail POST, or print anything wrong:
#
#   * DRAWMODE1's logic op was decoded from bits [15:12] instead of [31:28], so
#     every fill was OR-ed onto the destination instead of replacing it.
#   * REX3 had no graphics FIFO and no back-pressure, so the sixteen
#     rex3SetAndGo(zpattern) writes Ng1TpDrawbitmap fires back to back landed
#     on top of each other and glyph rows picked up pixels from the row before.
#   * USER_STATUS at 0x133C is an alias of STATUS and was answering a plain
#     register of zero, so REX3WAIT never waited for anything.
#
# The run is a normal PROM boot with Newport fitted, built with np_rex3.sv's
# REX3_DEBUG block enabled: one line per accepted GO, carrying every register
# the command depends on. tests/rex3_replay.py replays those lines into a model
# frame buffer and compares it with the one the run dumped.
#
# It is slower than tests/run-newport.sh because the trace is ten thousand
# lines and the replay is in Python, and it builds its own simulator in
# verilator/obj_dir_rex3dbg so the ordinary one is untouched.
#
#   tests/run-rex3.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir_rex3dbg/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
OUT="$ROOT/tests/out"
TRACE="$OUT/rex3-trace.txt"
FB="$OUT/rex3-fb.ppm"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest-rex3-debug >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM - run without --no-build" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
mkdir -p "$OUT"

echo "booting $(basename "$PROM") with REX3's command trace on ..."
"$SIM" --prom "$PROM" --max-cycles 90000000 --stuck 80000000 \
       --fbdump "$FB" > "$TRACE" 2>&1

gos=$(grep -c '^\[REX3\]' "$TRACE")
echo "  REX3 accepted $gos drawing commands"
if [[ "$gos" -lt 3000 ]]; then
    # A boot that draws the whole console draws ten thousand of them. Far
    # fewer means the machine stopped before it got to the screen, and the
    # replay would then agree with a nearly empty frame buffer and pass.
    # The bar was 5000 until 2026-09-02: with HAL2 reporting no audio the
    # PROM reaches its last console line right around the 90M-cycle limit
    # and the count settled at 3718 (docs/36 section 5) - the screen is
    # drawn, the logo and the text are there, and the replay checks them.
    echo "  FAILED  too few commands - the boot did not reach the screen"
    exit 1
fi

python3 "$ROOT/tests/rex3_replay.py" "$TRACE" "$FB" | sed 's/^/  /'
rc=${PIPESTATUS[0]}

echo
echo "trace is in ${TRACE#"$ROOT"/}, frame buffer in ${FB#"$ROOT"/}"
[[ $rc -eq 0 ]] && echo "REX3: PASS"
exit $rc
