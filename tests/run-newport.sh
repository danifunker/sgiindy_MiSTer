#!/usr/bin/env bash
#
# run-newport.sh - boot the PROM with Newport fitted and check that the machine
# finds the board, drives a monitor, and draws on it.
#
# THIS TEST CANNOT USE THE SERIAL CONSOLE, and that is the point. The moment
# ARCS finds a DisplayController the PROM moves its console to it: the serial
# port goes quiet after "NVRAM checksum is incorrect" and every message this
# project has ever read - the POST banner, the menu, hinv - is drawn into the
# frame buffer instead. Every other test in tests/ passes --no-gfx for exactly
# that reason. This one is what happens with the board in.
#
# So the assertions are made on the video OUTPUT PINS and the frame buffer,
# which between them cover the whole chain:
#
#   frames > 0            VC2 walked the video timing table all the way round a
#                         frame. The table is a program in VC2's external SRAM,
#                         loaded by the PROM from np_timing.h, so this is the
#                         interpreter in np_vc2.sv agreeing with the compiler
#                         that wrote it.
#   frame size            measured from the display enable rather than assumed,
#                         and checked EXACTLY. 1318 x 1065 is what walking
#                         n1280_r3 by hand gives - see below - so anything else
#                         is the interpreter disagreeing with the table.
#   lit pixels            REX3 drew, the readout found it, XMAP9's mode table
#                         and CMAP's palette turned it into colour, and it came
#                         out of the pins.
#   all three channels    red, green and blue each carry something. A DEAD
#                         CHANNEL IS INVISIBLE EVERYWHERE ELSE: the frame
#                         buffer holds a colour index, so a Display Control Bus
#                         that dropped the third byte of every palette write
#                         left the store perfect, the geometry perfect and the
#                         pixel count perfect, and turned the whole boot screen
#                         yellow-green.
#
# A frame buffer dump is written beside the console so a failure can be looked
# at rather than guessed at: tests/out/newport-fb.ppm.
#
#   tests/run-newport.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
OUT="$ROOT/tests/out/newport-console.txt"
FB="$ROOT/tests/out/newport-fb.ppm"

# How many lit pixels count as "it drew something". The PROM's boot screen is
# a filled background and a logo; a few hundred thousand pixels is what that
# comes to, and anything above a few thousand rules out a stray write.
MIN_LIT=1000000

# The geometry the PROM's own timing table describes, walked by hand from
# np_timing.h. See docs/16-newport-plan.md.
WANT_SIZE=1318x1065

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

echo "booting $(basename "$PROM") with Newport fitted ..."
out="$("$SIM" --prom "$PROM" --max-cycles 90000000 --stuck 80000000 \
       --fbdump "$FB" --console "$OUT" 2>&1)"

fail=0
check() {   # check <description> <test-expression-result>
    if [[ "$2" == "ok" ]]; then printf '  ok      %s\n' "$1"
    else                        printf '  FAILED  %s\n' "$1"; fail=1; fi
}

vline="$(printf '%s\n' "$out" | grep -m1 '^video: ')"
if [[ -z "$vline" ]]; then
    echo "  FAILED  no video summary in the run output"
    fail=1
else
    echo "  $vline"
    frames=$(sed -E 's/^video: ([0-9]+) frames.*/\1/' <<<"$vline")
    size=$(sed -E 's/.*best ([0-9]+x[0-9]+).*/\1/'    <<<"$vline")
    lit=$(sed -E 's/.*, ([0-9]+) lit pixels.*/\1/'    <<<"$vline")
    check "VC2 generated at least one complete frame"  \
          "$([[ ${frames:-0} -ge 1 ]] && echo ok)"
    # THE SIZE IS AN EXACT NUMBER AND IT IS NOT 1280x1024.
    #
    # CMAP 1's revision register reports monitor type 10, so Ng1DacInit loads
    # np_timing.h's 1280x1024-at-60Hz table for a revision-3 board: n1280_r3.
    # Walking that table by hand gives 1065 lines, of which 1024 carry the
    # display enable, and a horizontal total of 1680 pixels of which 1318 are
    # visible - 1280 plus the black margin the PROM keeps to the left of every
    # scanline. Both numbers come out of the pins exactly, so this asserts
    # them exactly rather than with a threshold: the timing generator is an
    # interpreter for that table and "close" is a bug.
    #
    # It used to be 1082 x 813, which was TWO defects and neither was the
    # walk. The board was reporting monitor type 0 - "unknown", which on a
    # Guinness means 1024x768 - and a duration field of D was being held for
    # D+1 two-pixel units. See docs/16-newport-plan.md.
    check "the frame out of the pins is exactly $WANT_SIZE"  \
          "$([[ "$size" == "$WANT_SIZE" ]] && echo ok)"
    check "the last frame is the same size as the best one" \
          "$([[ "$(sed -E 's/.*last ([0-9]+x[0-9]+).*/\1/' <<<"$vline")" == "$WANT_SIZE" ]] && echo ok)"
    check "REX3 drew at least $MIN_LIT pixels onto it" \
          "$([[ ${lit:-0} -ge $MIN_LIT ]] && echo ok)"
fi

cline="$(printf '%s\n' "$out" | grep -m1 '^video colour: ')"
if [[ -z "$cline" ]]; then
    echo "  FAILED  no video colour summary in the run output"
    fail=1
else
    echo "  $cline"
    cr=$(sed -E 's/^video colour: ([0-9]+) red.*/\1/'      <<<"$cline")
    cg=$(sed -E 's/.*, ([0-9]+) green.*/\1/'               <<<"$cline")
    cb=$(sed -E 's/.*, ([0-9]+) blue.*/\1/'                <<<"$cline")
    # A tenth of the lit pixels in each channel. The boot screen is a blue
    # gradient with grey and yellow on it, so every channel is well past this;
    # what the threshold rules out is a channel that is dead or nearly so.
    MIN_CHAN=$(( MIN_LIT / 10 ))
    check "red, green and blue all carry pixels" \
          "$([[ ${cr:-0} -ge $MIN_CHAN && ${cg:-0} -ge $MIN_CHAN && ${cb:-0} -ge $MIN_CHAN ]] && echo ok)"
fi

# The PROM opened video() this time, so the message it has printed on every
# boot this project has ever run must be gone.
if grep -qF "Cannot open video() for output" "$OUT"; then
    echo "  FAILED  the PROM still could not open video()"
    fail=1
else
    echo "  ok      the PROM opened video() for output"
fi

echo
echo "console output is in ${OUT#"$ROOT"/}"
echo "frame buffer is in ${FB#"$ROOT"/}"
[[ $fail -eq 0 ]] && echo "NEWPORT: PASS"
exit $fail
