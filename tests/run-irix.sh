#!/usr/bin/env bash
#
# run-irix.sh - boot an INSTALLED IRIX 5.3 root and check the kernel starts.
#
# This is the only test here that runs guest code past the PROM, and it is the
# ratchet for the whole exception path: the kernel takes a TLB refill on its
# first instruction and roughly two and a half million of them before it
# prints anything. The bug it exists to catch is in docs/09, "A TLB refill
# taken with EXL set" - the CPU sent a refill nested inside the refill handler
# back to the refill vector, and IRIX looped there forever in eight cached
# instructions, issuing no bus cycles at all. Nothing else in tests/ came
# anywhere near it: run-prom, run-scsi and run-cdrom all pass against a CPU
# with that bug, because the PROM never uses the TLB.
#
# IT NEEDS A DISK THIS REPOSITORY CANNOT CARRY - two gigabytes of installed
# IRIX. Point IRIXDISK at a raw image, or leave it and the script will convert
# a MAME CHD if it finds one:
#
#     chdman extractraw -i ~/irix-images/Indy-IRIX53_dev.chd -o /tmp/irix53.img
#     IRIXDISK=/tmp/irix53.img tests/run-irix.sh --no-build
#
# With no image it SKIPS and exits 0. That is deliberate: a machine without the
# media should not report a failure it did not measure.
#
# THE RUN IS LONG. The banner lands around 200 million clocks, which is about
# five minutes; --max-cycles is set a little past it rather than generously,
# because a regression here is a machine that stops, and waiting an hour to be
# told so helps nobody. Read --stop-on as the pass condition: the run ends the
# moment the kernel identifies itself.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
OUT="$ROOT/tests/out/irix-console.txt"
CHD="${IRIXCHD:-$HOME/irix-images/Indy-IRIX53_dev.chd}"

DISK="${IRIXDISK:-}"
if [[ -z "$DISK" ]]; then
    DISK="${TMPDIR:-/tmp}/irix53_dev.img"
    if [[ ! -f "$DISK" ]]; then
        if [[ -f "$CHD" ]] && command -v chdman >/dev/null; then
            echo "converting $(basename "$CHD") -> $DISK ..."
            chdman extractraw -i "$CHD" -o "$DISK" -f >/dev/null 2>&1 || {
                echo "IRIX: SKIP (chdman failed on $CHD)"; exit 0; }
        else
            echo "IRIX: SKIP (no installed-IRIX image; set IRIXDISK or IRIXCHD)"
            exit 0
        fi
    fi
fi

# Milestones, in the order they appear. The banner is the whole point; the two
# menu lines are here so that a failure says WHERE it stopped rather than just
# that it did.
EXPECT=(
    "System Maintenance Menu"              # the PROM got that far
    "Starting up the system"               # option 1 took, and sash was loaded
    "IRIX Release 5.3 IP22"                # THE KERNEL IS RUNNING
    "Silicon Graphics, Inc."
)

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

echo "booting $(basename "$DISK") ..."
# --no-gfx keeps the console on the serial port. A real Indy has a graphics
# board and IRIX would put its console there, which would make this test
# assert nothing readable; see tests/run-newport.sh for the other machine.
# --type-on rather than --key-at: the menu prompt is the trigger, and its
# cycle number moves with every change to the PROM's timing.
"$SIM" --prom "$PROM" --no-gfx --disk "1=$DISK" \
       --max-cycles 260000000 --stuck 250000000 \
       --type-on 'Option?' '1\r' \
       --stop-on 'Silicon Graphics, Inc.' \
       --console "$OUT" >/dev/null 2>&1

fail=0
for e in "${EXPECT[@]}"; do
    if grep -qF -- "$e" "$OUT"; then
        printf '  ok      %s\n' "$e"
    else
        printf '  MISSING %s\n' "$e"; fail=1
    fi
done

echo
echo "console output is in ${OUT#"$ROOT"/}"
[[ $fail -eq 0 ]] && echo "IRIX: PASS"
exit $fail
