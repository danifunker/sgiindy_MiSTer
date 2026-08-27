#!/usr/bin/env bash
#
# run-scc.sh - build and run the SCC bring-up image.
#
# Proves the Z8530 twice over: the byte tap at the TX FIFO pop says what the
# CPU handed the transmitter, and a UART decode of the txdb pin says what came
# out of it. The run only passes when the two agree and the line has no framing
# errors, so a model that queued bytes without shifting them fails.
#
#   tests/run-scc.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
ELF="$ROOT/tests/scc/build/scctest.elf"
EXPECT="USCC-TX-OK"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/tests/scc" CROSS="$CROSS" >/dev/null || exit 2
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]] || { echo "no $SIM" >&2; exit 2; }

out="$("$SIM" --elf "$ELF" --testdev --uart --max-cycles 40000000 2>&1)"
rc=$?
echo "$out"
echo

fail=0
grep -q "uart: MATCHES the byte tap" <<<"$out" || { echo "FAIL: tap and wire disagree"; fail=1; }
grep -q "0 framing errors"           <<<"$out" || { echo "FAIL: framing errors on txdb"; fail=1; }
grep -q "$EXPECT"                    <<<"$out" || { echo "FAIL: expected $EXPECT on the console"; fail=1; }
[[ $rc -eq 0 ]] || { echo "FAIL: the image reported rc=$rc"; fail=1; }

[[ $fail -eq 0 ]] && echo "SCC: PASS"
exit $fail
