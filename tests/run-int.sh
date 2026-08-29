#!/usr/bin/env bash
#
# run-int.sh - build and run the INT2 interrupt-path image.
#
# The PROM cannot test this. It masks LOCAL0 off entirely and polls the
# WD33C93's AUX STATUS register instead, so a boot all the way to the Command
# Monitor exercises not one line of the interrupt controller. IRIX is the
# software that needs it and IRIX does not boot yet, which would leave INT2 and
# the CPU's Cause.IP handling as code nothing had ever run.
#
# The image arms 8254 counter 0 and follows it to the CPU twice: once straight
# through to Cause.IP4, and once through MAP_MASK0 and the LOCAL0 summary to
# Cause.IP2. It also checks the two negatives - masked at the CPU, and masked
# at INT2 - because a core that took a spurious interrupt every microsecond
# would pass a test that only looked for one arriving. See tests/int/inttest.c.
#
#   tests/run-int.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
ELF="$ROOT/tests/int/build/inttest.elf"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/tests/int" CROSS="$CROSS" >/dev/null || exit 2
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]] || { echo "no $SIM" >&2; exit 2; }

out="$(# --no-gfx leaves Newport unfitted. A real Indy always has a graphics
# board, and the PROM moves its console to it the moment it finds one -
# so a serial-console ratchet has to ask for the machine that talks to a
# terminal. tests/run-newport.sh is the one that fits the board.
"$SIM" --elf "$ELF" --testdev --no-gfx --max-cycles 200000000 --stuck 20000000 2>&1)"
rc=$?
echo "$out"
echo

fail=0
grep -q "INT: ALL PASS" <<<"$out" || { echo "FAIL: the image reported failures"; fail=1; }
grep -q "FAIL"          <<<"$out" && { echo "FAIL: at least one check failed"; fail=1; }
[[ $rc -eq 0 ]]                   || { echo "FAIL: the image exited rc=$rc"; fail=1; }

[[ $fail -eq 0 ]] && echo "INT: PASS"
exit $fail
