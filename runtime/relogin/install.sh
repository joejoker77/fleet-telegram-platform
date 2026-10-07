#!/usr/bin/env bash
# Install (or remove) self-service sign-in on this host.
#
#   install.sh             files into /opt and /usr/local/sbin, unit up
#   install.sh --rollback  stop and remove the unit and the host binaries
#
# Deployed by hand on 2026-10-06, so a fresh host had none of it. Per-tenant files
# (the `relogin` helper and the mod) are NOT placed here: add-user.sh runs
# `rollout.py <user>` at onboarding, and that is the only path for an existing tenant too.
#
# The public address is served by nginx, which proxies /relogin/ to 127.0.0.1:8099.
# That location block ships with the Composio callback site (m6.3-composio-web.sh), so on
# a host where no public site is configured the service runs and only the one-tap link
# from the expiry warning has nowhere to land — said out loud below rather than assumed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/relogin
UNIT=/etc/systemd/system/relogin-web.service

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }

if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now relogin-web.service fleet-restart-requests.timer 2>/dev/null || true
  rm -f "$UNIT" /usr/local/sbin/relogin-web.py /usr/local/sbin/relogin-trigger \
        /usr/local/sbin/rc-reset-bridge /usr/local/sbin/fleet-restart-requests \
        /etc/systemd/system/fleet-restart-requests.service \
        /etc/systemd/system/fleet-restart-requests.timer
  systemctl daemon-reload
  echo "relogin removed ($DEST and the tenants' installed copies are kept)"
  exit 0
fi

install -d -m 0755 "$DEST" "$DEST/tenant"
install -m 0755 "$HERE/rollout.py" "$DEST/rollout.py"
[ -f "$HERE/README.md" ] && install -m 0644 "$HERE/README.md" "$DEST/README.md"
# tenant/ is what rollout.py copies into a home: the helper, and the mod beside it.
install -m 0755 "$HERE/tenant/relogin" "$DEST/tenant/relogin"
if [ -d "$HERE/tenant/mod" ]; then
  rm -rf "$DEST/tenant/mod.new"
  cp -a "$HERE/tenant/mod" "$DEST/tenant/mod.new"
  find "$DEST/tenant/mod.new" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$DEST/tenant/mod"; mv "$DEST/tenant/mod.new" "$DEST/tenant/mod"
  chown -R root:root "$DEST/tenant/mod"
fi

install -m 0755 "$HERE/relogin-trigger" /usr/local/sbin/relogin-trigger
install -m 0755 "$HERE/relogin-web.py"  /usr/local/sbin/relogin-web.py
install -m 0644 "$HERE/relogin-web.service" "$UNIT"
# The cure for a dead remote-control session, and the thing that honours the restart a
# tenant asks for after signing in. Without the second one a person is told "signed in"
# and then met with "Login expired" on their next question, because the running session
# still holds the credentials and the bridge it started with.
install -m 0755 "$HERE/rc-reset-bridge" /usr/local/sbin/rc-reset-bridge
install -m 0755 "$HERE/fleet-restart-requests" /usr/local/sbin/fleet-restart-requests
install -m 0644 "$HERE/fleet-restart-requests.service" /etc/systemd/system/
install -m 0644 "$HERE/fleet-restart-requests.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now relogin-web.service
systemctl enable --now fleet-restart-requests.timer
echo "relogin-web: $(systemctl is-active relogin-web.service) on 127.0.0.1:8099"

if ! grep -rqs "location ^~ /relogin/" /etc/nginx/sites-available/ 2>/dev/null; then
  echo "NOTE: nginx has no /relogin/ location yet — the sign-in link has no public address."
  echo "  It ships with the callback site: control-plane/install/m6.3-composio-web.sh --domain <d>"
fi
echo "enrol tenants with: $DEST/rollout.py <tenant>   (add-user.sh does this for new ones)"
