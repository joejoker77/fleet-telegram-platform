#!/usr/bin/env bash
# One-command rollback of fleet-policy-install.sh.
# Context windows go back to auto AT ONCE in running pods (the tap reads the control file);
# the subagent model and the effort cap leave on each pod's next restart.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
systemctl disable --now fleet-governor.service 2>/dev/null || true
for d in /var/lib/fleet/ctl/*/; do [ -d "$d" ] && echo auto > "$d/window"; done
rm -f /etc/claudeapp/fleet-policy.json /etc/systemd/system/fleet-governor.service /usr/local/sbin/fleet-governor
rm -rf /var/lib/fleet/governor /var/lib/fleet/managed
systemctl daemon-reload
echo "fleet policy removed. Windows are back to auto now; restart pods to drop the tap, subagent model and effort cap."
echo "(The tap file /usr/local/lib/fleet/fleet-usage-tap.js stays until no pod mounts it; delete it after the restarts.)"
