#!/usr/bin/env bash
# Rollback M4.4 auto-suspend. Disables the timer(s), removes units + binaries.
# Keeps /etc/agentshield/autosuspend.conf unless --purge. Does NOT resume a
# paused pod — use tenant-resume <user> for that (or it stays as-is).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
USERS=("vitaliy")
for u in "${USERS[@]}"; do
  systemctl disable --now "auto-suspend-monitor@$u.timer" 2>/dev/null || true
done
rm -f /etc/systemd/system/auto-suspend-monitor@.service /etc/systemd/system/auto-suspend-monitor@.timer
systemctl daemon-reload
rm -f /usr/local/sbin/auto-suspend-monitor /usr/local/sbin/tenant-resume
if [ "${1:-}" = "--purge" ]; then rm -f /etc/agentshield/autosuspend.conf; echo "purged autosuspend.conf"; fi
echo "✅ auto-suspend rolled back"
