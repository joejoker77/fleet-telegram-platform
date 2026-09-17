#!/usr/bin/env bash
# Install the sign-in expiry reporter (script + daily timer). Idempotent.
# Rollback: login-expiry-notify-rollback.sh — one command, removes everything this adds.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN=/usr/local/sbin/login-expiry-notify
UNIT_DIR=/etc/systemd/system

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

install -m 0755 "$HERE/login-expiry-notify.sh" "$BIN"
install -m 0644 "$ROOT/systemd/login-expiry-notify.service" "$UNIT_DIR/"
install -m 0644 "$ROOT/systemd/login-expiry-notify.timer" "$UNIT_DIR/"

# Who gets the report, and how early. Written once; edit in place afterwards.
if [ ! -f /etc/claudeapp/login-expiry-notify.env ]; then
  mkdir -p /etc/claudeapp
  cat > /etc/claudeapp/login-expiry-notify.env <<'CFG'
# Tenant whose bot sends the report, and whose chat receives it (a bot can only
# message someone who started it, so the admin's own bot is the right sender).
FLEET_EXPIRY_ADMIN=tonysoprano1337
# How many days of notice.
FLEET_EXPIRY_WARN_DAYS=5
CFG
  chmod 0644 /etc/claudeapp/login-expiry-notify.env
fi

systemctl daemon-reload
systemctl enable --now login-expiry-notify.timer >/dev/null
systemctl is-enabled login-expiry-notify.timer >/dev/null || die "timer not enabled"

echo "installed: $BIN"
systemctl list-timers login-expiry-notify.timer --no-pager | sed -n '1,3p'
echo
echo "Try it without sending:  $BIN --dry-run"
echo "Send one now:            $BIN --force"
