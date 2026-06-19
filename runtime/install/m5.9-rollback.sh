#!/usr/bin/env bash
# Rollback for m5.9-web-serving.sh: remove the rendered Mini App / IDE vhosts,
# reset the bot menu button to default, drop the recorded base URL. Idempotent.
# TLS certs from certbot are left in place (harmless; `certbot delete` to purge).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

DOMAIN="${PLATFORM_DOMAIN:-}"
MINIAPP_HOST="${PLATFORM_MINIAPP_HOST:-}"; IDE_HOST="${PLATFORM_IDE_HOST:-}"
[ -z "$MINIAPP_HOST" ] && [ -n "$DOMAIN" ] && MINIAPP_HOST="miniapp.$DOMAIN"
[ -z "$IDE_HOST" ]     && [ -n "$DOMAIN" ] && IDE_HOST="ide.$DOMAIN"

for h in "$MINIAPP_HOST" "$IDE_HOST"; do
  [ -z "$h" ] && continue
  rm -f "/etc/nginx/sites-enabled/$h" "/etc/nginx/sites-available/$h"
  echo "removed vhost $h"
done
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

TOKEN="${PLATFORM_BOT_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN="$(podman secret inspect cp_bot_token --showsecret --format '{{.SecretData}}' 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
  curl -s -m 15 -X POST "https://api.telegram.org/bot${TOKEN}/setChatMenuButton" \
    -H 'Content-Type: application/json' -d '{"menu_button":{"type":"default"}}' >/dev/null 2>&1 \
    && echo "menu button reset to default" || true
fi
rm -f /etc/cp-web/base-url
echo "m5.9 rollback done"
