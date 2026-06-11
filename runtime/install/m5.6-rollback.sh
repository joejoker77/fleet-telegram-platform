#!/usr/bin/env bash
# M5.6 rollback — remove the web-IDE exposure completely. One command, safe at
# any point (idempotent), prepared BEFORE the deploy (rollback-first rule).
# Run as root.
#
# What it reverts:
#   - nginx vhost ide.ai-assistant.gg (sites-enabled symlink + sites-available)
#   - /etc/tmpfiles.d/cp-ide.conf + /run/cp-ide (the claude-pod-run conditional
#     keys off this dir: absent → no socket mount, no CP_IDE_SOCKET env)
# What it does NOT touch:
#   - the running pod: it keeps its current code-server until the next restart;
#     after a restart without CP_IDE_SOCKET, code-server returns to the legacy
#     127.0.0.1:8443 loopback inside the pod netns (unreachable from outside).
#   - cp-api: /ide/* endpoints stay but issue tickets to a dead vhost — inert.
#     Roll the code back separately with git revert if needed.
#   - certbot certificates (harmless to keep; certbot delete if desired).
set -euo pipefail

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

log "removing nginx vhost ide.ai-assistant.gg"
rm -f /etc/nginx/sites-enabled/ide.ai-assistant.gg \
      /etc/nginx/sites-available/ide.ai-assistant.gg
if command -v nginx >/dev/null 2>&1 && systemctl is-active -q nginx 2>/dev/null; then
  nginx -t && systemctl reload nginx
fi

log "removing /run/cp-ide + tmpfiles entry"
rm -f /etc/tmpfiles.d/cp-ide.conf
rm -rf /run/cp-ide

log "DONE — web-IDE exposure removed"
echo "note: the pod keeps running untouched; on its next restart code-server"
echo "reverts to 127.0.0.1:8443 inside the pod (no CP_IDE_SOCKET → legacy path)."
