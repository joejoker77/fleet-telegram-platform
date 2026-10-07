#!/usr/bin/env bash
# Install (or remove) the skill auto-publisher on this host.
#   install.sh            install and enable the hourly timer
#   install.sh --rollback stop the timer and take the unit files away
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now skill-autoshare.timer 2>/dev/null || true
  rm -f /etc/systemd/system/skill-autoshare.service /etc/systemd/system/skill-autoshare.timer
  systemctl daemon-reload
  echo "skill-autoshare removed (state in /var/lib/skill-autoshare kept)"
  exit 0
fi
install -d -m 0755 /opt/skill-autoshare
install -m 0755 "$HERE/autoshare.py" /opt/skill-autoshare/autoshare.py
install -m 0644 "$HERE/skill-autoshare.service" /etc/systemd/system/skill-autoshare.service
install -m 0644 "$HERE/skill-autoshare.timer" /etc/systemd/system/skill-autoshare.timer
systemctl daemon-reload
systemctl enable --now skill-autoshare.timer
echo "installed; next run:"
systemctl list-timers skill-autoshare.timer --no-pager | sed -n 2p
