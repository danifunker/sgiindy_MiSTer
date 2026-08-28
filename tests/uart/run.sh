#!/usr/bin/env bash
# Host-side unit test for verilator/sim_uart.h. No simulator, no RTL, ~1 s.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/tests/out/uart_test"
mkdir -p "$(dirname "$OUT")"
c++ -std=c++17 -O1 -Wall -I "$ROOT/verilator" -o "$OUT" "$ROOT/tests/uart/uart_test.cpp" || exit 2
"$OUT"
