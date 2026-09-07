#!/usr/bin/env bash
#
# diff_upstream.sh - show every local change to the vendored CPU sources.
#
#   tools/diff_upstream.sh [path-to-Arcade-KillerInstinct_MiSTer]
#
# The base is the Killer Instinct project's R4600 (rtl/cpu/ in that repo -
# itself a fork of the MiSTer N64 R4300i), see rtl/cpu/r4300/UPSTREAM.md for
# the commit and the list of changes and why; this is how to check that list is
# still complete. Every hunk should carry an `-- SGI:` comment.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KI="${1:-/c/Temp/mistercore/Arcade-KillerInstinct_MiSTer}"
UP="$KI/rtl/cpu"

[[ -d "$UP" ]] || { echo "no Arcade-KillerInstinct_MiSTer checkout at $KI" >&2; exit 2; }

echo "upstream: $UP @ $(git -C "$KI" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo

for f in "$ROOT/rtl/cpu/r4300"/*.vhd; do
    b="$(basename "$f")"
    if [[ -f "$UP/$b" ]]; then
        diff -u <(tr -d '' < "$UP/$b") <(tr -d '' < "$f") || true
    else
        echo "=== $b: not present upstream ==="
    fi
done
