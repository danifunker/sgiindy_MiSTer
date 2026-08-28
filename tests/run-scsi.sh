#!/usr/bin/env bash
#
# run-scsi.sh - boot the PROM with a disk attached and hold the SCSI data path
# where it now is.
#
# tests/run-prom.sh boots with NO disk, and that is deliberate: it is the
# machine's own ratchet and it must not depend on a block device. This one is
# the SCSI ratchet. The difference between the two is the whole DMA engine:
# with a disk attached and no engine, the PROM's INQUIRY reached DATA IN, the
# WD33C93B raised DBR, nobody drained it, and the boot printed
#
#     sc0,1,0: cmd=0x12 timeout after 2 sec.  Resetting SCSI bus
#
# once for every command it tried. What is asserted below is that the INQUIRY
# completes and that the PROM gets far enough to open the disk and read its
# volume header - which is a real descriptor-driven DMA transfer of a real
# block, out of a real image file, through the WD33C93B a byte at a time.
#
# THE VOLUME HEADER IS EXPECTED TO BE INVALID. tests/disks/blank8m.img is
# eight megabytes of zeroes; "volume header not valid" is the PROM correctly
# reading a block full of nothing. A test that wanted a valid header would be
# testing the fixture, not the machine.
#
# The boot is now free of SCSI errors entirely. It used to print
#
#     sc0,1,0: SYNC negotiation error, resetting SCSI bus
#
# because the PROM negotiates synchronous transfer and the target had no
# MESSAGE OUT phase to receive the SDTR in. Both ends of that are built now -
# see docs/13-scsi-dma-plan.md - and the string is on the forbidden list below.
#
# WHAT IS STILL MISSING: `hinv` lists no disk. That is NOT what this script
# tests, and two theories about why have already been wrong - the negotiation
# was not it, and neither is "this PROM's hinv does not report SCSI". The disk
# is missing from the ARCS device tree; docs/13 has where to pick that up.
#
#   tests/run-scsi.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
DISK="${DISK:-$ROOT/tests/disks/blank8m.img}"
OUT="$ROOT/tests/out/scsi-console.txt"

EXPECT=(
    "Running power-on diagnostics"
    # The disk answered INQUIRY, the PROM named it, and then read block 0
    # through the HPC3 SCSI DMA channel. This one line is the whole engine.
    "dks0d1s0"
    "System Maintenance Menu"                # POST still passes with a disk on
    "Command Monitor."
    "Memory size: 64 Mbytes"
)

FORBID=(
    # The failure this engine was built to fix. cmd=0x12 is INQUIRY; the
    # WD33C93B had taken its first byte and raised DBR with nothing behind it.
    "cmd=0x12 timeout"
    "timeout after 2 sec"
    # POST must not start failing just because a disk is present.
    "Diagnostics failed"
    "illegal disconnection interrupt"
    # The PROM's synchronous-transfer negotiation. It fails when the target
    # cannot receive a MESSAGE OUT, or when it receives one and never answers.
    "SYNC negotiation error"
    # Any bus reset at all. Every one of these was a real failure being
    # recovered from, and there should now be none in a clean boot.
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

echo "booting $(basename "$PROM") with a disk on ID 1 ..."
"$SIM" --prom "$PROM" --disk "1=$DISK" \
       --max-cycles 1200000000 --stuck 150000000 \
       --type-on 'Option?' '5\r' \
       --type-on 'Command Monitor' 'hinv\r' \
       --stop-on 'Mbytes' \
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
[[ $fail -eq 0 ]] && echo "SCSI: PASS"
exit $fail
