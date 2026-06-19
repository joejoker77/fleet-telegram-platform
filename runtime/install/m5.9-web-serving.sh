#!/usr/bin/env bash
# M5.9 — serve the public web surface (Telegram Mini App + web-IDE) out of the
# box. Renders the nginx vhost templates for the install's DOMAIN, enables them,
# issues TLS via certbot, and points the bot's Mini App menu button at the app.
# Run as root. Idempotent. Rollback: runtime/install/m5.9-rollback.sh.
#
# Inputs (env, from install.sh):
#   PLATFORM_MINIAPP_HOST   e.g. miniapp.example.com   (or derived from DOMAIN)
#   PLATFORM_IDE_HOST       e.g. ide.example.com       (or derived from DOMAIN)
#   PLATFORM_DOMAIN         base domain → miniapp.<d> / ide.<d> when hosts unset
#   BOOTSTRAP_ADMIN_USER    tenant whose code-server the IDE vhost fronts
#   PLATFORM_ADMIN_EMAIL    certbot registration email (optional)
#   PLATFORM_BOT_TOKEN      bot token for setChatMenuButton (else podman secret cp_bot_token)
#   WEB_SKIP_CERTBOT=1      install http vhosts only (no TLS) — for hosts without DNS yet
set -euo pipefail

log() { printf '\n== %s ==\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
[ "${DRY_RUN:-0}" = "1" ] || [ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
DEPLOY="$ROOT/control-plane/deploy"

DOMAIN="${PLATFORM_DOMAIN:-}"
MINIAPP_HOST="${PLATFORM_MINIAPP_HOST:-}"
IDE_HOST="${PLATFORM_IDE_HOST:-}"
[ -z "$MINIAPP_HOST" ] && [ -n "$DOMAIN" ] && MINIAPP_HOST="miniapp.$DOMAIN"
[ -z "$IDE_HOST" ]     && [ -n "$DOMAIN" ] && IDE_HOST="ide.$DOMAIN"
TENANT="${BOOTSTRAP_ADMIN_USER:-}"
EMAIL="${PLATFORM_ADMIN_EMAIL:-}"

if [ -z "$MINIAPP_HOST" ]; then
  echo "no PLATFORM_MINIAPP_HOST / PLATFORM_DOMAIN set — skipping web serving."
  echo "  (set PLATFORM_DOMAIN=example.com and re-run, or run m5.9-web-serving.sh later)"
  exit 0
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY-RUN: would render+enable nginx vhost for $MINIAPP_HOST (root /var/www/miniapp/dist),"
  [ -n "$IDE_HOST" ] && [ -n "$TENANT" ] && echo "  + IDE vhost $IDE_HOST → tenant $TENANT socket,"
  echo "  run certbot --nginx for the host(s), and set the bot Mini App menu button → https://$MINIAPP_HOST"
  exit 0
fi

command -v nginx >/dev/null || { echo "ERROR: nginx not installed (deps phase)" >&2; exit 1; }
SA=/etc/nginx/sites-available; SE=/etc/nginx/sites-enabled
mkdir -p "$SA" "$SE"

# Deploy the Mini App SPA bundle from the repo (was a manual note in m8.1 →
# broke out-of-the-box). The built dist is committed; copy it where nginx serves.
SPA_SRC="$ROOT/control-plane/apps/miniapp/dist"
if [ -d "$SPA_SRC" ] && [ -f "$SPA_SRC/index.html" ]; then
  log "deploy Mini App SPA → /var/www/miniapp/dist"
  mkdir -p /var/www/miniapp/dist
  cp -a "$SPA_SRC/." /var/www/miniapp/dist/
  chmod -R a+rX /var/www/miniapp
else
  warn "SPA dist not found at $SPA_SRC — build it first: (cd control-plane/apps/miniapp && pnpm build). nginx will 404 until then."
fi

render_vhost() { # $1=tmpl $2=dest  (remaining: sed exprs)
  local tmpl="$1" dest="$2"; shift 2
  local expr=(); local e; for e in "$@"; do expr+=(-e "$e"); done
  sed "${expr[@]}" "$tmpl" > "$dest"
}

log "miniapp vhost → $MINIAPP_HOST"
render_vhost "$DEPLOY/nginx-miniapp.conf.tmpl" "$SA/$MINIAPP_HOST" "s#__MINIAPP_HOST__#$MINIAPP_HOST#g"
ln -sf "$SA/$MINIAPP_HOST" "$SE/$MINIAPP_HOST"

CERT_HOSTS=(-d "$MINIAPP_HOST")
if [ -n "$IDE_HOST" ] && [ -n "$TENANT" ]; then
  log "IDE vhost → $IDE_HOST (tenant $TENANT)"
  render_vhost "$DEPLOY/nginx-ide.conf.tmpl" "$SA/$IDE_HOST" \
    "s#__IDE_HOST__#$IDE_HOST#g" "s#__TENANT__#$TENANT#g"
  ln -sf "$SA/$IDE_HOST" "$SE/$IDE_HOST"
  CERT_HOSTS+=(-d "$IDE_HOST")
else
  [ -n "$IDE_HOST" ] && warn "IDE_HOST set but no BOOTSTRAP_ADMIN_USER — skipping IDE vhost (no tenant socket)."
fi

log "nginx -t + reload"
nginx -t
systemctl reload nginx 2>/dev/null || systemctl restart nginx

# TLS via certbot (needs the host(s) to resolve here + :80 reachable).
if [ "${WEB_SKIP_CERTBOT:-0}" = "1" ]; then
  warn "WEB_SKIP_CERTBOT=1 — serving HTTP only; run certbot --nginx ${CERT_HOSTS[*]} once DNS resolves."
elif command -v certbot >/dev/null; then
  log "certbot --nginx ${CERT_HOSTS[*]}"
  EMAIL_ARG=(--register-unsafely-without-email)
  [ -n "$EMAIL" ] && EMAIL_ARG=(-m "$EMAIL")
  if certbot --nginx "${CERT_HOSTS[@]}" --non-interactive --agree-tos --redirect "${EMAIL_ARG[@]}"; then
    log "TLS issued"
  else
    warn "certbot failed (DNS not pointing here yet / :80 blocked?). HTTP vhost is live; re-run: certbot --nginx ${CERT_HOSTS[*]}"
  fi
else
  warn "certbot not installed — skipping TLS. Install it + run certbot --nginx ${CERT_HOSTS[*]}."
fi

# Point the bot's Mini App menu button at the served app (HTTPS — Telegram requirement).
TOKEN="${PLATFORM_BOT_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN="$(podman secret inspect cp_bot_token --showsecret --format '{{.SecretData}}' 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
  log "setChatMenuButton → https://$MINIAPP_HOST"
  MB=$(jq -n --arg u "https://$MINIAPP_HOST" \
        '{menu_button:{type:"web_app", text:"Open app", web_app:{url:$u}}}')
  RESP=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TOKEN}/setChatMenuButton" \
          -H 'Content-Type: application/json' -d "$MB" || true)
  [ "$(printf '%s' "$RESP" | jq -r '.ok // false')" = "true" ] \
    && echo "menu button set" \
    || warn "setChatMenuButton failed: $(printf '%s' "$RESP" | jq -r '.description // .')"
else
  warn "no bot token (PLATFORM_BOT_TOKEN / cp_bot_token) — skipping menu button. Set later."
fi

# Record the public base URL so other components (Composio OAuth callback) can
# derive their redirect base instead of hardcoding ai-assistant.gg.
mkdir -p /etc/cp-web
printf 'MINIAPP_URL=https://%s\n' "$MINIAPP_HOST" > /etc/cp-web/base-url
[ -n "$IDE_HOST" ] && printf 'IDE_URL=https://%s\n' "$IDE_HOST" >> /etc/cp-web/base-url

log "DONE — Mini App: https://$MINIAPP_HOST  (menu button + TLS as reported above)"
