#!/usr/bin/env bash
# console.sh [--baud N] [--seconds N] [--out FILE] - read the machine's serial
# console off the MiSTer.
#
# THE CORE'S UART IS A REAL TTY ON THE HPS. sys_top.v wires the core's
# UART_TXD/RXD to `cyclonev_hps_interface_peripheral_uart`, so the SCC's tty1
# comes out of the ARM side as /dev/ttyS1 - not as pins on the user port. That
# makes the hardware console exactly as observable as the Verilator harness's,
# over the same ssh connection everything else here uses.
#
# `uartmode 0` first, because MiSTer's own uartmode script parks pppd, agetty
# or midilink on that tty depending on the OSD setting, and two readers on one
# tty each get half the bytes.
#
# BAUD: the PROM opens the console at 9600 and then announces "diagnostic baud
# rate set to 19200" partway through POST, so a capture pinned to one rate gets
# either the start or the rest. Default 9600 catches the reset banner; pass
# --baud 19200 to follow it afterwards.
#
# This only shows anything with "Graphics board: None". Fitting the board moves
# the console into the frame buffer - ARCS installs a DisplayController with
# ConsoleOut|Output and the PROM stops writing to the SCC at all.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_SSH_USER:=root}"

BAUD=9600
SECONDS_=60
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --baud)    BAUD="$2"; shift ;;
        --seconds) SECONDS_="$2"; shift ;;
        --out)     OUT="$2"; shift ;;
        *) echo "usage: scripts/console.sh [--baud N] [--seconds N] [--out FILE]" >&2; exit 2 ;;
    esac
    shift
done

export MSYS_NO_PATHCONV=1
echo "[console] ${MISTER_HOST}:/dev/ttyS1 at ${BAUD} baud for ${SECONDS_}s"
# `raw -echo` so nothing is line-buffered or echoed back at the machine, and
# `-hupcl` so closing the capture does not toggle the modem lines.
CMD="uartmode 0 >/dev/null 2>&1; \
     stty -F /dev/ttyS1 ${BAUD} raw -echo -hupcl; \
     timeout ${SECONDS_} cat /dev/ttyS1"
if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
        "$MISTER_SSH_USER@$MISTER_HOST" "$CMD" | tee "$OUT"
    echo "[console] $(wc -c < "$OUT") bytes -> $OUT"
else
    ssh -o StrictHostKeyChecking=no -i "$MISTER_SSH_KEY" \
        "$MISTER_SSH_USER@$MISTER_HOST" "$CMD"
fi
