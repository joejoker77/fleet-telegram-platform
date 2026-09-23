#!/usr/bin/env bash
# Undo needrestart-guard.sh — the host goes back to restarting tenant pods on
# every library upgrade (i.e. back to the 2026-09-23 behaviour).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
rm -f /etc/needrestart/conf.d/90-claude-fleet.conf
echo "removed /etc/needrestart/conf.d/90-claude-fleet.conf"
command -v needrestart >/dev/null 2>&1 && needrestart -p >/dev/null 2>&1 \
  && echo "needrestart still runs"
