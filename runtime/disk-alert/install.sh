#!/usr/bin/env bash
# Install (or remove) the disk-space alert on this host.
#   install.sh             install and enable the 15-minute timer
#   install.sh --rollback  stop the timer and take the unit files away
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now disk-alert.timer 2>/dev/null || true
  rm -f /etc/systemd/system/disk-alert.service /etc/systemd/system/disk-alert.timer
  systemctl daemon-reload
  echo "disk-alert removed (state in /var/lib/disk-alert kept)"
  exit 0
fi

# It reaches Telegram through smart-reminders' admin channel; without that module
# there is nowhere for an alert to go.
[ -r /opt/smart-reminders/smart_reminders.py ] || {
  echo "missing /opt/smart-reminders/smart_reminders.py -- install smart-reminders first" >&2
  exit 1
}

install -d -m 0755 /opt/disk-alert
install -m 0755 "$HERE/disk_alert.py" /opt/disk-alert/disk_alert.py
install -m 0644 "$HERE/disk-alert.service" /etc/systemd/system/disk-alert.service
install -m 0644 "$HERE/disk-alert.timer"   /etc/systemd/system/disk-alert.timer
systemctl daemon-reload
systemctl enable --now disk-alert.timer
echo "installed; next run:"
systemctl list-timers disk-alert.timer --no-pager | sed -n 2p
