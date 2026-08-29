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
# "Processor: 16 Mhz" is a MEASURED figure, not a claim the core makes, and it
# is NOT the 8254 - an earlier version of this comment said it was. The PROM
# times a fixed 512-iteration two-instruction loop (FUN_bfc31594) with CP0
# Count, so what it reports is instruction throughput. Doubling PIT_TICK_DIV
# and doubling RTC_TICK_DIV each leave it at 16, which rules out both
# timebases; the loop lives at 0xBFC3159C, in uncached KSEG1, so the
# instruction cache does not move it either. See docs/10-r4300-integration.md,
# "What it did not buy". The part that matters is "R4400, with FPU".
#
# The run ends on "Mbytes" rather than on "Memory size:", which is the last
# thing hinv prints: --stop-on fires on the cycle the substring completes, so
# stopping on the label ends the run before the number it labels arrives.
#
#   tests/run-prom.sh [--no-build]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/verilator/obj_dir/Vsim_top"
PROM="${PROM:-$ROOT/roms/IP24_Indy/ip24prom.070-9101-011.bin}"
OUT="$ROOT/tests/out/prom-console.txt"

# Milestones, in the order the PROM prints them. Each is a substring.
EXPECT=(
    "NVRAM checksum is incorrect"          # the console works, and the RTC/NVRAM answers
    "Running power-on diagnostics"         # POST started, so memory was found
    "Cannot open video() for output"       # POST ran to the end and found no graphics
    "System Maintenance Menu"              # POST passed, so the menu comes up unprompted
    "5) Enter Command Monitor"
    "Command Monitor."                     # and the menu took a keystroke: serial input
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
    # The 8042 answers its self-test, so the keyboard/mouse diagnostic passes
    # and prints nothing at all. This used to be an EXPECT line, back when the
    # ports read zero and the only question was whether POST got as far as
    # complaining about them - see docs/12-chipset.md finding 10. Moved here
    # rather than deleted: the machine now gets further, and a regression that
    # brought the failure back would otherwise pass silently.
    "PC keyboard/mouse controller"
    # Both of these were EXPECT lines when there was no SCSI controller at all:
    # the question then was only whether POST got as far as complaining. The
    # WD33C93B now passes its own diagnostic and the data path test, so neither
    # prints. Same reasoning as the keyboard line above.
    "WD SCSI0 path test"
    "SCSI controller 0 diagnostic"
    # The bus scan of the empty IDs used to print one of these per ID and then
    # fail POST. It was the chip accepting a command while an interrupt was
    # still pending, where the part sets LCI and refuses; docs/12-chipset.md has
    # the whole diagnosis. "Diagnostics failed" was an EXPECT line for as long
    # as that was true - POST now passes, and with it the "[Press any key to
    # continue.]" prompt that used to gate the menu is gone too.
    "illegal disconnection interrupt"
    "Diagnostics failed"
    "Press any key to continue"
)

if [[ "${1:-}" != "--no-build" ]]; then
    make -C "$ROOT/verilator" cputest >/dev/null || exit 2
fi

[[ -x "$SIM" ]]  || { echo "no $SIM" >&2; exit 2; }
[[ -f "$PROM" ]] || { echo "no PROM at $PROM" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

echo "booting $(basename "$PROM") ..."
# The triggers fire in order, so a trigger that never appears blocks every
# keystroke behind it. There is no "[Press any key to continue.]" here any
# more: POST passes and the menu comes up on its own.
# --no-gfx leaves Newport unfitted. A real Indy always has a graphics
# board, and the PROM moves its console to it the moment it finds one -
# so a serial-console ratchet has to ask for the machine that talks to a
# terminal. tests/run-newport.sh is the one that fits the board.
"$SIM" --prom "$PROM" --no-gfx --max-cycles 1200000000 --stuck 150000000 \
       --type-on 'Option?' '5\r' \
       --type-on 'Command Monitor' 'version\r' \
       --type-on 'PROM Monitor' 'hinv\r' \
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
[[ $fail -eq 0 ]] && echo "PROM: PASS"
exit $fail
