#!/usr/bin/env bash
#
# run-dma.sh - build and run the HPC3 SCSI DMA channel image.
#
# This is the bus-master and descriptor test, with no SCSI in it at all. The
# PROM exercises exactly one path through the engine - one data descriptor
# followed by the zero-count EOX marker the spec's "**** BUG ****" note tells
# drivers to append - and a boot that finds a disk says nothing about the rest
# of it. What this image covers that no boot does:
#
#   - the power-on state, where ch_reset comes up SET and gates ch_active
#   - XIE, the interrupt, and the fact that reading the control port clears it
#     while reading the byte count beside it does not
#   - ch_active_mask, which no driver on this machine ever writes
#   - link descriptors: a zero byte count without EOX
#   - FLUSH, which must stop the channel and must NOT interrupt
#   - a descriptor chain pointing at memory that is not there
#
# It does not move a byte: there is no device here to hand one over. The data
# path is tested by tests/run-scsi.sh against a real disk image.
#
#   tests/run-dma.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
ELF="$ROOT/tests/dma/build/dmatest.elf"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/tests/dma" CROSS="$CROSS" >/dev/null || exit 2
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
grep -q "DMA: ALL PASS" <<<"$out" || { echo "FAIL: the image reported failures"; fail=1; }
grep -q "FAIL"          <<<"$out" && { echo "FAIL: at least one check failed"; fail=1; }
[[ $rc -eq 0 ]]                   || { echo "FAIL: the image exited rc=$rc"; fail=1; }

[[ $fail -eq 0 ]] && echo "DMA: PASS"
exit $fail
