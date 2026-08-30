#!/usr/bin/env bash
# grab.sh OUT.png - take a FRESH screenshot of what the MiSTer is displaying.
#
# The point of the freshness check is that the mrext screenshot API happily
# returns the last file it has if video capture is dead, and a stale frame of
# the previous core is exactly the picture that makes a dead bring-up look
# like a working one. So: note the newest shot, ask for a new one, and only
# report success once a file with a later timestamp appears.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_HTTP_PORT:=8182}"

OUT="${1:?usage: scripts/grab.sh out.png}"
HTTP="http://$MISTER_HOST:$MISTER_HTTP_PORT"

newest() {
  curl -s -m 10 "$HTTP/api/screenshots" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('|'); sys.exit()
d.sort(key=lambda x: x['modified'])
print(d[-1]['modified'] + '|' + d[-1]['path'] if d else '|')"
}

BEFORE=$(newest)
curl -s -m 10 -X POST "$HTTP/api/screenshots" >/dev/null
for _ in 1 2 3 4 5 6; do
  sleep 2
  AFTER=$(newest)
  if [ "$AFTER" != "$BEFORE" ]; then
    ENC=$(printf '%s' "${AFTER#*|}" | python -c "import sys,urllib.parse as u; print(u.quote(sys.stdin.read()))")
    mkdir -p "$(dirname "$OUT")"
    curl -s -m 30 -o "$OUT" "$HTTP/api/screenshots/$ENC"
    echo "FRESH $OUT <- ${AFTER#*|}"
    exit 0
  fi
done
echo "STALE: no new frame - the core may output no video at all"
exit 3
