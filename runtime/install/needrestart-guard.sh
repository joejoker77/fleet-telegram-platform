#!/usr/bin/env bash
# Stop the host's automatic OS updates from restarting the tenant fleet.
# See runtime/host/needrestart-claude-fleet.conf for the incident this comes from.
# Idempotent. Rollback: needrestart-guard-rollback.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
SRC="$REPO/runtime/host/needrestart-claude-fleet.conf"
DST=/etc/needrestart/conf.d/90-claude-fleet.conf

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC — wrong checkout?"; exit 1; }
[ -d /etc/needrestart/conf.d ] || { echo "needrestart is not installed here — nothing to guard"; exit 0; }

install -m 0644 "$SRC" "$DST"
echo "installed $DST"

# Prove it parses: needrestart reads conf.d at startup and dies loudly on a syntax
# error, which would leave the host's updates unable to run at all. Checking it
# here is the difference between finding that out now and finding it out at 06:01.
if command -v needrestart >/dev/null 2>&1; then
  if needrestart -p >/dev/null 2>&1; then
    echo "needrestart parses the config and still runs"
  else
    echo "needrestart FAILED to run with the new config — removing it again" >&2
    rm -f "$DST"
    exit 1
  fi
fi

echo
echo "in effect for:"
sed -n 's/^ *qr(\^\([^)]*\)).*/  \1*/p' "$DST"
