#!/usr/bin/env bash
# Undo login-expiry-notify-install.sh completely. Leaves the config file in place only
# if it was hand-edited (nothing else reads it, and it holds no secret).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

systemctl disable --now login-expiry-notify.timer 2>/dev/null || true
rm -f /etc/systemd/system/login-expiry-notify.timer \
      /etc/systemd/system/login-expiry-notify.service \
      /usr/local/sbin/login-expiry-notify \
      /var/lib/fleet/login-expiry.state
systemctl daemon-reload
echo "login-expiry-notify removed (config left at /etc/claudeapp/login-expiry-notify.env)"
