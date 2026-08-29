#!/usr/bin/env bash
#
# run-scsiwr.sh - the SCSI data path, in both directions and at width.
#
# tests/run-scsi.sh proves the narrowest possible DATA IN: the PROM's INQUIRY
# and its volume-header read, one block at a time through a single descriptor.
# Nothing proved DATA OUT at all, because nothing in a PROM boot writes to a
# disk, so the memory-to-device half of this core's only bus master had never
# moved a byte.
#
# It found a real hole the first time it ran: rtl/scsi/sgi_scsi.sv left each
# target's sd_buff_din unconnected and tied the module's own output to zero, so
# every block written to a disk would have landed as 512 zero bytes. scsi.v and
# the initiator were both fine. See tests/scsiwr/scsiwr.c.
#
# IT IS NOW FIVE PHASES WIDE, and the reason is a failure this core has already
# produced: the IRIX 5.3 installer copies itself off the CD onto the disk,
# prints "Copy complete", and panics on a load from address zero. That copy is
# a bulk read off a CD and a bulk multi-block write to a disk, and until this
# was widened the entire path was covered by one WRITE(6) of one block. What
# runs now:
#
#   1. one block, WRITE(6)/READ(6), one descriptor - the original;
#   2. four blocks in one WRITE(6), so the target advances its own LBA;
#   3. four blocks through WRITE(10)/READ(10) - a ten-byte CDB, which is a
#      different length decode in both the WD33C93B and the target;
#   4. the same four blocks over a chain of three data descriptors, read back
#      over a chain of two;
#   5. a READ(10) of a 2048-byte logical block off the CD-ROM on ID 6,
#      compared against what the image actually has at that offset. No byte
#      had ever been read off a disc before.
#
# THE IMAGES ARE BUILT HERE, not checked in. The harness commits writes to its
# in-memory copy and never back to the file, but a test that writes to a
# tracked fixture is one refactor away from corrupting it, so the disk gets a
# scratch image of its own under tests/out/. The disc gets a PATTERNED one: a
# disc full of zeros would hide a scaling bug in the x4 that turns a CD-ROM's
# 2048-byte logical block into four host blocks, exactly the way blank8m.img
# hid the DATA IN off-by-one for months.
#
#   tests/run-scsiwr.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS="${CROSS:-mipsel-linux-gnu-}"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
ELF="$ROOT/tests/scsiwr/build/scsiwr.elf"
DISK="$ROOT/tests/out/scratch8m.img"
ISO="$ROOT/tests/out/scsiwr8m.iso"

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/tests/scsiwr" CROSS="$CROSS" >/dev/null || exit 2
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]] || { echo "no $SIM" >&2; exit 2; }
[[ -f "$ELF" ]] || { echo "no $ELF" >&2; exit 2; }

mkdir -p "$(dirname "$DISK")"
dd if=/dev/zero of="$DISK" bs=1048576 count=8 status=none || exit 2

# The disc's pattern has to agree with cd_pat() in tests/scsiwr/scsiwr.c byte
# for byte. It is deliberately a different shape from the disk pattern that
# file writes: a test that computed both with the same function could pass on
# a path that had confused the two images for each other.
python3 - "$ISO" <<'PY' || exit 2
import sys
n = 8*1024*1024
with open(sys.argv[1], 'wb') as f:
    f.write(bytes(((i*7) ^ (i >> 11) ^ 0x5A) & 0xFF for i in range(n)))
PY

out="$(# --no-gfx leaves Newport unfitted. A real Indy always has a graphics
# board, and the PROM moves its console to it the moment it finds one -
# so a serial-console ratchet has to ask for the machine that talks to a
# terminal. tests/run-newport.sh is the one that fits the board.
"$SIM" --elf "$ELF" --testdev --no-gfx --disk "1=$DISK" --disk "6=$ISO" \
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
