#!/usr/bin/env bash
# Install the Claude Code auto-updater on the firm host.
#   cc-cli-update-install.sh             install script + units, seed the CURRENT pod version as
#                                        /opt/claude-cli/current (no restarts), enable the timer
#   cc-cli-update-install.sh --rollback  disable the timer, remove /opt/claude-cli/current so pods
#                                        fall back to the image's own Claude Code on their next start
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now cc-cli-update.timer 2>/dev/null || true
  rm -f /opt/claude-cli/current
  echo "auto-update off; pods use the image's Claude Code from their next start (/opt/claude-cli kept)"
  exit 0
fi
install -m 0755 "$HERE/cc-cli-update.sh" /usr/local/sbin/cc-cli-update
install -m 0755 "$ROOT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
install -m 0644 "$ROOT/systemd/cc-cli-update.service" "$ROOT/systemd/cc-cli-update.timer" /etc/systemd/system/
systemctl daemon-reload
if [ ! -e /opt/claude-cli/current ]; then
  V="$(podman run --rm --entrypoint /bin/sh localhost/claude-user:latest -c 'claude --version' | awk '{print $1}')"
  /usr/local/sbin/cc-cli-update --seed "$V"
fi
systemctl enable --now cc-cli-update.timer
echo "installed. current: $(readlink -f /opt/claude-cli/current)"
systemctl list-timers cc-cli-update.timer --no-pager | head -2
