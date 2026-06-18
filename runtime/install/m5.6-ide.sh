#!/usr/bin/env bash
# M5.6 — enable the web-IDE host side. Idempotent, run as root.
# Rollback: runtime/install/m5.6-rollback.sh (prepared first, rollback-first rule).
#
# This script only flips the host-side SWITCH: it creates /run/cp-ide (and a
# tmpfiles.d entry so it survives reboots). claude-pod-run keys its conditional
# off this dir — when present, the pod gets the socket mount + CP_IDE_SOCKET
# env on its NEXT restart (end-of-session only).
#
# The nginx vhost is installed separately from the template (see header of
# control-plane/deploy/nginx-ide.conf) — same procedure as the miniapp vhost.
set -euo pipefail

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

getent group www-data >/dev/null || { echo "ERROR: group www-data missing (nginx not installed?)" >&2; exit 1; }

log "tmpfiles.d entry + /run/cp-ide"
cat > /etc/tmpfiles.d/cp-ide.conf <<'EOF'
# M5.6 web-IDE: parent dir for per-tenant code-server unix sockets.
# claude-pod-run creates /run/cp-ide/<user> (tenant-uid:www-data, 2750) and
# bind-mounts it into the pod; nginx connects to the socket inside.
# Conditional switch: claude-pod-run only wires the socket when this dir exists.
d /run/cp-ide 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/cp-ide.conf

TENANT="${BOOTSTRAP_ADMIN_USER:-}"

log "DONE — /run/cp-ide ready"
echo "next steps:"
echo "  1. install the nginx vhost from control-plane/deploy/nginx-ide.conf (+ certbot)"
if [ -n "$TENANT" ]; then
  echo "  2. pod restart (END of session only) picks up the socket: systemctl restart claude-pod@$TENANT"
else
  echo "  2. no tenant set (BOOTSTRAP_ADMIN_USER empty) — the per-tenant pod picks up the"
  echo "     socket on its next restart (end of session): systemctl restart claude-pod@<user>"
fi
echo "rollback: runtime/install/m5.6-rollback.sh"
