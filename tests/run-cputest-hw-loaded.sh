#!/usr/bin/env bash
#
# run-cputest-hw-loaded.sh - the CPU suite on hardware, with the memory busy.
#
# WHY THIS IS A DIFFERENT TEST FROM run-cputest-hw.sh. That one passes: 240
# tests, 2160 checks, on the board. And a PROM boot on the same bitstream
# panics about one time in three. The largest difference between the two is not
# the CPU - it is how many masters are on the memory.
#
# The suite never programs Newport, so the display's frame buffer reader is
# idle and the CPU has DDR3 to itself for the whole run. A boot programs it, and
# docs/18 measures that reader saturating the port: 0.52 words per clock
# delivered against the 0.80 it wants. So the CPU-to-DDR3 path is proven under
# ONE master and has never been tested under two, which is exactly the gap a
# fault that only appears during boots would live in.
#
# This puts a second heavy reader on the memory for the length of the run. It
# is not the same master - it contends at the HPS end rather than through
# ddr3_mux's arbiter - so a pass here does not clear the arbiter. A FAILURE,
# though, would be worth a great deal: 2160 checks is a far better detector of
# memory trouble than a boot that only fails 40% of the time and reports it as
# a garbage pointer three turns from the cause.
#
#   tests/run-cputest-hw-loaded.sh [--no-build]
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?}"; : "${MISTER_SSH_KEY:?}"; : "${MISTER_SSH_USER:=root}"

export MSYS_NO_PATHCONV=1
DBG="/media/fat/sgidbg"
rsh() { ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
            "$MISTER_SSH_USER@$MISTER_HOST" "$@"; }

# The load is started by run-cputest-hw.sh itself, AFTER it launches the core.
# It has to be: launch_unstable_core.py reboots the MiSTer, so a generator
# started here would be killed before the suite ever ran - which is exactly
# what happened the first time, and the run came back a clean pass with no
# contention on it.
exec bash tests/run-cputest-hw.sh --load "$@"
