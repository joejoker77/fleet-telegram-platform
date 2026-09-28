#!/usr/bin/env bash
# One-command rollback for compact-governor: every enabled tenant goes back to
# /autocompact auto (the behaviour before the governor), the status line comes out,
# and the timer and script are removed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONF=/etc/claudeapp/compact-governor.env
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

systemctl disable --now compact-governor.timer 2>/dev/null || true
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  T="$( . "$CONF"; echo "${TENANTS:-}" )"
  [ -n "$T" ] && "$HERE/compact-governor-install.sh" --disable $T
fi
rm -f /etc/systemd/system/compact-governor.service /etc/systemd/system/compact-governor.timer \
      /usr/local/sbin/compact-governor "$CONF"
rm -rf /var/lib/fleet/compact-governor
systemctl daemon-reload
echo "compact-governor removed"
