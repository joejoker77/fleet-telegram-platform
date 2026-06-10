#!/usr/bin/env bash
# Rollback the M4.3 settings.json integrity guard. Disables the .path units,
# removes the units + binaries. Leaves the golden baselines unless --purge.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
USERS=("vitaliy")

for u in "${USERS[@]}"; do
  systemctl disable --now "agentshield-settings-guard@$u.path" 2>/dev/null || true
done
rm -f /etc/systemd/system/agentshield-settings-guard@.path /etc/systemd/system/agentshield-settings-guard@.service
systemctl daemon-reload
rm -f /usr/local/sbin/agentshield-settings-guard /usr/local/sbin/agentshield-settings-rebaseline
if [ "${1:-}" = "--purge" ]; then
  rm -rf /var/lib/agentshield/golden
  echo "purged golden baselines"
fi
echo "✅ settings-guard rolled back"
