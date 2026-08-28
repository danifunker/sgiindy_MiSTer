#!/usr/bin/env bash
#
# run-cdrom.sh - the CD-ROM ratchet: a drive on ID 6 that `hinv` lists.
#
# The drive is a compile-time thing, not a mount-time one. `sgi_scsi.sv`'s
# CDROM_IDS parameter says which IDs elaborate as CD-ROM drives (ID 6 by
# default, where SGI put the internal one), because `CDROM` changes what the
# target answers to INQUIRY, the size of a logical block, what READ CAPACITY
# reports and which MODE SENSE pages exist. A drive is a different device from
# a disk, not a disk with a different file in it - so this mounts an ISO with
# the same --disk flag and the RTL decides what is behind it.
#
# WHAT THIS COVERS: the drive answers selection, INQUIRY reports CD-ROM, and
# the PROM builds the ARCS nodes for it. `SCSI CDROM: scsi(0)cdrom(6)` only
# prints if the node printer at 0xBFC4130C finds the disk's grandparent is the
# type-0x0b adapter AND the parent's type is 0x10 - the CD-ROM controller type
# the probe assigns at 0xBFC1BCAC for INQUIRY device type 5 - so that one line
# asserts adapter -> controller(0x10) -> peripheral(0x1a) as a shape.
#
# WHAT THIS DOES NOT COVER, and be clear about it: **the ISO.** A CD-ROM drive
# answers selection on `cd_enable`, not on `mounted` - a drive with no disc in
# it is still a drive, and still appears in hinv, which is what real hardware
# does. So this exact line also appears in tests/run-scsi.sh, which mounts no
# ISO at all. What is asserted here is that the drive is present, answers
# INQUIRY as device type 5, and gets the right ARCS node shape built for it -
# NOT that a disc image was read, because no block has ever come off one.
#
# The 2048-byte logical block path - four consecutive 512-byte host blocks,
# scaled x4 at latch time in scsi.v - is therefore completely untested. That is
# the obvious next thing, and the argument for it is docs/13: DATA IN was off
# by one for months because everything being read was zeros. The ISO is built
# with a pattern below so that the test which finally reads it can fail.
#
# THE ISO IS BUILT HERE, not checked in: 8 MB of incompressible pattern is not
# something to put in git, and a disc full of zeros would hide a scaling bug in
# that x4 the way blank8m.img hid the DATA IN one. The pattern is the same
# shape as tests/scsiwr/scsiwr.c's.
#
#   tests/run-cdrom.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
DISK="${DISK:-$ROOT/tests/disks/blank8m.img}"
ISO="$ROOT/tests/out/patterned8m.iso"
OUT="$ROOT/tests/out/cdrom-console.txt"

EXPECT=(
    "Running power-on diagnostics"
    "System Maintenance Menu"                # POST still passes with a drive on
    "SCSI Disk: scsi(0)disk(1)"              # the disk is still there beside it
    "SCSI CDROM: scsi(0)cdrom(6)"            # and this is the whole point
)

FORBID=(
    "cmd=0x12 timeout"
    "timeout after 2 sec"
    "Diagnostics failed"
    "illegal disconnection interrupt"
    "SYNC negotiation error"
    "resetting SCSI bus"
    "Resetting SCSI bus"
)

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "no disk image at $DISK" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
python3 - "$ISO" <<'PY' || exit 2
import sys
n = 8*1024*1024
with open(sys.argv[1], 'wb') as f:
    f.write(bytes(((i*7) ^ (i >> 11) ^ 0x5A) & 0xFF for i in range(n)))
PY

echo "booting $(basename "$PROM") with a disk on ID 1 and a CD-ROM on ID 6 ..."
# Stops on the audio line, which the PROM prints AFTER the SCSI ones, so the
# CD-ROM line is always flushed before the run ends. Stopping on the CD-ROM
# line itself would race the newline - see tests/run-scsi.sh.
"$SIM" --prom "$PROM" --disk "1=$DISK" --disk "6=$ISO" \
       --max-cycles 1200000000 --stuck 150000000 \
       --type-on 'Option?' '5\r' \
       --type-on 'Command Monitor' 'hinv\r' \
       --stop-on 'revision 4.1.0' \
       --console "$OUT" >/dev/null 2>&1

fail=0
for e in "${EXPECT[@]}"; do
    if grep -qF -- "$e" "$OUT"; then
        printf '  ok      %s\n' "$e"
    else
        printf '  MISSING %s\n' "$e"; fail=1
    fi
done
for f in "${FORBID[@]}"; do
    if grep -qF -- "$f" "$OUT"; then
        printf '  REGRESSED, must not appear: %s\n' "$f"; fail=1
    fi
done

echo
echo "console output is in ${OUT#"$ROOT"/}"
[[ $fail -eq 0 ]] && echo "CDROM: PASS"
exit $fail
