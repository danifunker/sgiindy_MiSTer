#!/usr/bin/env bash
#
# diff_upstream.sh - show every local change to the vendored R4300i sources.
#
#   tools/diff_upstream.sh [path-to-N64_MiSTer]
#
# rtl/cpu/r4300/UPSTREAM.md lists the changes and why; this is how to check
# that list is still complete. Every hunk should carry an `-- SGI:` comment.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N64="${1:-$HOME/repos/N64_MiSTer}"

[[ -d "$N64/rtl" ]] || { echo "no N64_MiSTer checkout at $N64" >&2; exit 2; }

echo "upstream: $N64 @ $(git -C "$N64" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo

for f in "$ROOT/rtl/cpu/r4300"/*.vhd; do
    b="$(basename "$f")"
    if [[ -f "$N64/rtl/$b" ]]; then
        diff -u "$N64/rtl/$b" "$f" || true
    else
        echo "=== $b: not present upstream ==="
    fi
done
