#!/usr/bin/env bash
#
# run-prom.sh - boot the real IP24 PROM and check how far it gets.
#
# This is a progress ratchet, not a pass/fail test of the machine: the PROM is
# expected to report the devices this core does not implement, and it does.
# What the script asserts is that each milestone it has previously reached is
# still reached, so that a change which quietly moves the boot backwards shows
# up as a failing test rather than as a surprise three sessions later.
#
# Add a line to EXPECT when the PROM starts printing something new. Do not
# remove one to make the script pass.
#
# "Processor: 16 Mhz" is a MEASURED figure, not a claim the core makes: the
# PROM times itself against the 8254, which simulation runs ten times fast
# (sim_top.sv's PIT_TICK_DIV). Change that knob and this number changes with
# it. The part that matters is "R4400, with FPU".
#
#   tests/run-prom.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
OUT="$ROOT/tests/out/prom-console.txt"

# Milestones, in the order the PROM prints them. Each is a substring.
EXPECT=(
    "Data path test"                       # the console itself works
    "NVRAM checksum is incorrect"          # the RTC/NVRAM answers, and is blank
    "Running power-on diagnostics"         # POST started, so memory was found
    "SCSI controller 0 diagnostic"         # POST got past the memory tests
    "PC keyboard/mouse controller"
    "Diagnostics failed"                   # POST finished and reported
    "System Maintenance Menu"              # the keystroke arrived: serial input
    "5) Enter Command Monitor"
    "Command Monitor."                     # and the menu took a second keystroke
    "PROM Monitor SGI Version 5.3"         # the >> prompt runs commands
    "Processor: 16 Mhz R4400, with FPU"    # the R4400 presentation, end to end
    "Primary I-cache size: 16 Kbytes"
    "Memory size: 64 Mbytes"               # and MEMCFG sized the SIMMs right
)

# Things that must NOT appear. These are the failures that used to happen and
# each one names a piece of the chipset that would have stopped working.
FORBID=(
    "No usable memory found"               # the MEMCFG-driven memory decode
    "memory probe *FAILED*"                # ditto
    "Bank 0 memory diagnostics"            # ditto
)

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

echo "booting $(basename "$PROM") ..."
"$SIM" --prom "$PROM" --max-cycles 1200000000 --stuck 150000000 \
       --type-on 'Press any key' ' ' \
       --type-on 'Option?' '5\r' \
       --type-on 'Command Monitor' 'version\r' \
       --type-on 'PROM Monitor' 'hinv\r' \
       --stop-on 'Memory size:' \
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
[[ $fail -eq 0 ]] && echo "PROM: PASS"
exit $fail
