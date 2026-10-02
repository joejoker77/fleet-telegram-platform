#!/usr/bin/env bash
# Install the fleet-update Telegram relay on the firm host.
#   cli-update-relay-install.sh             install script + conf + units, anchor at the current
#                                           end of the events file, enable the timer
#   cli-update-relay-install.sh --rollback  disable the timer and remove it; the events file and
#                                           cc-cli-update itself are untouched
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ADMIN="${FLEET_CLI_RELAY_ADMIN:-vitaliy}"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now cli-update-relay.timer 2>/dev/null || true
  rm -f /etc/systemd/system/cli-update-relay.service /etc/systemd/system/cli-update-relay.timer
  systemctl daemon-reload
  echo "relay off; /var/lib/fleet/cli-update.events and cc-cli-update are untouched"
  exit 0
fi
install -m 0755 "$HERE/cli-update-relay.sh" /usr/local/sbin/cli-update-relay
install -m 0644 "$ROOT/systemd/cli-update-relay.service" "$ROOT/systemd/cli-update-relay.timer" /etc/systemd/system/
install -d -m 0755 /etc/claudeapp
if [ ! -e /etc/claudeapp/cli-update-relay.env ]; then
  cat > /etc/claudeapp/cli-update-relay.env <<CONF
# Tenant whose bot sends the report, and whose chat receives it (a bot can only message
# someone who started it, so the admin's own bot is the right sender).
FLEET_CLI_RELAY_ADMIN=$ADMIN
CONF
  chmod 0644 /etc/claudeapp/cli-update-relay.env
fi
systemctl daemon-reload
# Anchor on the events already in the file, so installing the relay does not replay history
# as if the fleet had just been updated.
if [ ! -e /var/lib/fleet/cli-update-relay.state ]; then
  N=0
  [ -e /var/lib/fleet/cli-update.events ] && N="$(grep -c . /var/lib/fleet/cli-update.events || true)"
  install -d -m 0755 /var/lib/fleet
  printf '{"sent_lines": %s, "sent_at": "install"}\n' "$N" > /var/lib/fleet/cli-update-relay.state
  echo "anchored at $N existing event(s)"
fi
systemctl enable --now cli-update-relay.timer
echo "installed. admin: $ADMIN"
systemctl list-timers cli-update-relay.timer --no-pager | head -2
