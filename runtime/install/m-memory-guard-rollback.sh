#!/usr/bin/env bash
# m-memory-guard-rollback.sh — undo m-memory-guard.sh.
#
# Removes the hourly reaper (timer, unit, binary) and turns the swapfile off, out of
# /etc/fstab and off the disk, and restores the default swappiness. Sessions already
# reaped are not restored — they were abandoned processes, there is nothing to restore.
set -euo pipefail

SWAPFILE=/swapfile
BIN=/usr/local/sbin/reap-stale-app-sessions
UNIT_DIR=/etc/systemd/system

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

log "reaper"
systemctl disable --now reap-stale-app-sessions.timer 2>/dev/null || true
rm -f "$UNIT_DIR/reap-stale-app-sessions.timer" "$UNIT_DIR/reap-stale-app-sessions.service" "$BIN"
systemctl daemon-reload
echo "  removed"

log "swap"
if swapon --show=NAME --noheadings | grep -q "^$SWAPFILE$"; then
  # Refuse to pull the cushion out from under a box that is currently leaning on it.
  used_kb=$(awk -v f="$SWAPFILE" '$1==f {print $4}' /proc/swaps)
  if [ "${used_kb:-0}" -gt 1048576 ]; then
    echo "  ${used_kb} kB of swap is IN USE — not turning it off; free memory first" >&2
  else
    swapoff "$SWAPFILE" && echo "  swapoff done"
    sed -i "\|^$SWAPFILE |d" /etc/fstab
    rm -f "$SWAPFILE"
    echo "  file removed and fstab cleaned"
  fi
else
  echo "  no swapfile of ours is active"
fi

log "swappiness"
rm -f /etc/sysctl.d/99-fleet-swappiness.conf
sysctl -w vm.swappiness=60 >/dev/null || true
sysctl -n vm.swappiness | sed 's/^/  vm.swappiness = /'

echo
free -h | sed -n '1,3p'
echo "rolled back."
