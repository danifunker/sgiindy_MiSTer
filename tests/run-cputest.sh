#!/usr/bin/env bash
#
# run-cputest.sh - run the bare-metal MIPS suite on the core and diff it
# against the reference.
#
#   tests/run-cputest.sh                    build everything and compare
#   tests/run-cputest.sh --no-build         just run what is already built
#   tests/run-cputest.sh --trace            add a bus trace to the log
#
# The suite lives in the IRIS repository, not here: it is a general MIPS III/IV
# suite that also runs on real SGI hardware, and forking it would strand the
# R4300 support this core needs. Point CPUTESTS at a different checkout if
# yours is elsewhere.
#
# Exit status is the comparison's: non-zero when a test that passes on the
# reference fails here.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPUTESTS="${CPUTESTS:-$HOME/repos/iris/cpu-tests}"
# macOS has no mips-linux-gnu-gcc, but the mipsel cross GCC is bi-endian and
# -EB -mabi=n32 gets exactly the ELF32 MSB n32 image the suite wants:
#   brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
OUT="${OUT:-$ROOT/tests/out}"
REF="${REF:-$ROOT/tests/baseline/iris-r4400.log}"

BUILD=1
EXTRA=()
# bash 3.2 (what macOS ships) treats an empty array as unset under `set -u`,
# so expansions below use the ${a[@]+"${a[@]}"} form.
for a in "$@"; do
    case "$a" in
        --no-build) BUILD=0 ;;
        *)          EXTRA+=("$a") ;;
    esac
done

mkdir -p "$OUT"

if [[ $BUILD -eq 1 ]]; then
    [[ -d "$CPUTESTS" ]] || { echo "no cpu-tests at $CPUTESTS (set CPUTESTS)" >&2; exit 2; }
    echo "== building the suite =="
    make -C "$CPUTESTS" CROSS="$CROSS" -j8 >/dev/null || exit 2
    echo "== building the core =="
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

ELF="$CPUTESTS/build/cputest.elf"
[[ -f "$ELF" ]] || { echo "no $ELF" >&2; exit 2; }
[[ -x "$SIM" ]]  || { echo "no $SIM (make -C verilator cputest)" >&2; exit 2; }

# 20M clocks of no new bus address is generous on purpose. With the real SCC in
# the core and no PROM to have programmed WR5, the suite's first console write
# spins out its whole 100000-iteration transmit-empty budget before it gives up
# on the port and switches to the test device - a few million clocks of
# legitimate, faithful nothing. cpu-tests/harness/console.c:36-50 describes
# the same behaviour on real hardware.
echo "== running =="
# --no-gfx leaves Newport unfitted. A real Indy always has a graphics
# board, and the PROM moves its console to it the moment it finds one -
# so a serial-console ratchet has to ask for the machine that talks to a
# terminal. tests/run-newport.sh is the one that fits the board.
"$SIM" --elf "$ELF" --testdev --no-gfx --console "$OUT/r4300.log" \
       --stuck 20000000 ${EXTRA[@]+"${EXTRA[@]}"} > "$OUT/r4300.full" 2>&1
rc=$?
tail -6 "$OUT/r4300.log"
echo "rc=$rc  (the suite's own failure count; 127 means it refused to run)"
echo

python3 "$ROOT/tests/compare.py" "$REF" "$OUT/r4300.log"
