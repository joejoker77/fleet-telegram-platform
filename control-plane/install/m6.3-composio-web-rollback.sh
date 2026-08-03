#!/usr/bin/env bash
# m6.3-composio-web-rollback.sh — remove the public callback vhost and stop pointing tenants at
# it. The TLS certificate is KEPT by default (re-issuing costs a rate-limit slot and the cert is
# harmless on its own); pass --delete-cert to remove it too.
#
# After this, composio-connect falls back to its built-in default again — which is the fleet
# domain, so only run this if that is what you want.
set -uo pipefail
DEL_CERT=0; DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --delete-cert) DEL_CERT=1 ;;
    --domain) DOMAIN="${2:-}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac; shift
done
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

echo "== 1) tenant callback base =="
rm -f /etc/claudeapp/composio-callback.env && echo "  removed /etc/claudeapp/composio-callback.env" \
  || echo "  (absent)"
echo "  tenants revert on their next pod restart"

echo "== 2) nginx vhost =="
rm -f /etc/nginx/sites-enabled/claudeapp-composio.conf
rm -f /etc/nginx/sites-available/claudeapp-composio.conf
if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || true; echo "  vhost removed, nginx reloaded"
else echo "  WARN: nginx config no longer valid — inspect 'nginx -t' before reloading"; fi

echo "== 3) certificate =="
if [ "$DEL_CERT" = 1 ] && [ -n "$DOMAIN" ]; then
  certbot delete --cert-name "$DOMAIN" --non-interactive 2>&1 | tail -2
else
  echo "  kept (pass --delete-cert --domain <d> to remove)"
fi
echo
echo "== rollback DONE =="
