#!/usr/bin/env bash
# M5.5b rollback — remove the cp-secretd privileged helper completely.
# One command, safe to run at any point (idempotent). Does NOT touch the
# OneCLI vault state: staged/bound secrets stay as they are (delete them
# individually via the Mini App disconnect, or `onecli secrets delete --id`).
# Run as root.
set -euo pipefail

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

log "stopping + disabling cp-secretd socket/instances"
systemctl disable --now cp-secretd.socket 2>/dev/null || true
# Accept=yes spawns per-connection instances cp-secretd@N.service — stop strays.
systemctl stop 'cp-secretd@*.service' 2>/dev/null || true

log "removing units, helper, tmpfiles, socket dir"
rm -f /etc/systemd/system/cp-secretd.socket \
      /etc/systemd/system/cp-secretd@.service \
      /etc/tmpfiles.d/cp-secretd.conf \
      /usr/local/sbin/cp-secretd
rm -rf /run/cp-secretd
systemctl daemon-reload

log "DONE — cp-secretd removed"
echo "note: cp-api keeps running; its /mcp/connect with secretSpec will now"
echo "fail with a clear 'secretd unavailable' error (secret-less M5.5 flow is unaffected)."
