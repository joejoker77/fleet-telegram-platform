#!/usr/bin/env bash
# Install (or remove) the tenant-home log caps on this host.
#   install.sh             install the sweeper, tighten pane-log rotation, enable the daily timer
#   install.sh --rollback  stop the timer, take the unit files away, restore the old logrotate
# Deletes nothing by itself: run tenant-logcaps.py (no flags) for a dry run first.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# NOT under /etc/logrotate.d. logrotate reads every file in that directory
# whatever it is called, so a backup kept beside the original is read as a
# second config, trips "duplicate log entry", and logrotate exits 1 having
# rotated nothing. That is exactly how an rsyslog.bak-20261020 left there on
# 2026-10-20 killed the whole host's daily rotation for a week.
BACKUP_DIR=/var/backups/logrotate-superseded
BACKUP="$BACKUP_DIR/claude-pane.pre-logcaps"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now tenant-logcaps.timer 2>/dev/null || true
  rm -f /etc/systemd/system/tenant-logcaps.service /etc/systemd/system/tenant-logcaps.timer
  systemctl daemon-reload
  if [ -f "$BACKUP" ]; then
    mv -f "$BACKUP" /etc/logrotate.d/claude-pane
    echo "restored the previous /etc/logrotate.d/claude-pane"
  fi
  echo "tenant-logcaps removed (run reports in /var/log/tenant-logcaps kept)"
  exit 0
fi

install -d -m 0755 /opt/tenant-logcaps
install -m 0755 "$HERE/tenant-logcaps.py" /opt/tenant-logcaps/tenant-logcaps.py

# Keep exactly one backup: the state before this component first touched the host.
install -d -m 0755 "$BACKUP_DIR"
if [ -f /etc/logrotate.d/claude-pane ] && [ ! -f "$BACKUP" ]; then
  cp -p /etc/logrotate.d/claude-pane "$BACKUP"
fi
install -m 0644 "$HERE/claude-pane.logrotate" /etc/logrotate.d/claude-pane

# Parse the WHOLE of logrotate's config, not just our file: a stray backup or
# an editor's leftover anywhere in /etc/logrotate.d takes the daily run down
# with it, and we would rather find that here than a week later.
if logrotate --debug /etc/logrotate.conf 2>&1 | grep -q '^error'; then
  echo "WARNING: /etc/logrotate.d has a broken config -- the daily run will exit 1:" >&2
  logrotate --debug /etc/logrotate.conf 2>&1 | grep '^error' | sed 's/^/  /' >&2
fi

install -m 0644 "$HERE/tenant-logcaps.service" /etc/systemd/system/tenant-logcaps.service
install -m 0644 "$HERE/tenant-logcaps.timer"   /etc/systemd/system/tenant-logcaps.timer
systemctl daemon-reload
systemctl enable --now tenant-logcaps.timer
echo "installed; next run:"
systemctl list-timers tenant-logcaps.timer --no-pager | sed -n 2p
