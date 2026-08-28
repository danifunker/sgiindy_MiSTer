#!/usr/bin/env bash
#
# run-scsiwr.sh - the SCSI DATA OUT ratchet.
#
# tests/run-scsi.sh proves DATA IN: the PROM's INQUIRY and its volume-header
# read both come back through the WD33C93B and the HPC3's SCSI DMA channel.
# Nothing proved DATA OUT, because nothing in a PROM boot writes to a disk, so
# the memory-to-device half of this core's only bus master had never moved a
# byte. This image writes one block through it and reads the same block back.
#
# It found a real hole the first time it ran: rtl/scsi/sgi_scsi.sv left each
# target's sd_buff_din unconnected and tied the module's own output to zero, so
# every block written to a disk would have landed as 512 zero bytes. scsi.v and
# the initiator were both fine. See tests/scsiwr/scsiwr.c.
#
# THE DISK IMAGE IS BUILT HERE, not checked in. The harness commits writes to
# its in-memory copy and never back to the file, but a test that writes to a
# tracked fixture is one refactor away from corrupting it, so this one gets a
# scratch image of its own under tests/out/.
#
#   tests/run-scsiwr.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
ELF="$ROOT/tests/scsiwr/build/scsiwr.elf"
DISK="$ROOT/tests/out/scratch8m.img"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/tests/scsiwr" CROSS="$CROSS" >/dev/null || exit 2
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]] || { echo "no $SIM" >&2; exit 2; }
[[ -f "$ELF" ]] || { echo "no $ELF" >&2; exit 2; }

mkdir -p "$(dirname "$DISK")"
dd if=/dev/zero of="$DISK" bs=1048576 count=8 status=none || exit 2

out="$("$SIM" --elf "$ELF" --testdev --disk "1=$DISK" \
              --max-cycles 400000000 --stuck 40000000 2>&1)"
rc=$?
echo "$out"
echo

fail=0
grep -q "SCSIWR: ALL PASS" <<<"$out" || { echo "FAIL: the image reported failures"; fail=1; }
grep -q "FAIL"             <<<"$out" && { echo "FAIL: at least one check failed"; fail=1; }
[[ $rc -eq 0 ]]                      || { echo "FAIL: the image exited rc=$rc"; fail=1; }

[[ $fail -eq 0 ]] && echo "SCSIWR: PASS"
exit $fail
