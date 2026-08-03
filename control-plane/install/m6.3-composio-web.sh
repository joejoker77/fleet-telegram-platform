#!/usr/bin/env bash
# m6.3-composio-web.sh — publish the ONE public endpoint this deployment needs: the Composio
# OAuth callback, on the deployment's own domain, behind TLS.
#
# WHY THIS EXISTS. composio-connect builds the callback URL from COMPOSIO_CALLBACK_BASE and
# falls back to the FLEET's domain when it is unset. On the firm install that fallback was live:
# their users' OAuth callbacks — carrying their Telegram id, the toolkit and the connected-account
# id — were landing on our host, and the confirmation message was attempted by our bot instead of
# theirs. Connecting still appeared to work, which is exactly why nobody noticed. This script
# makes the deployment self-contained.
#
# EXPOSURE. Only two exact paths are proxied, and everything else is 404:
#   /integrations/composio/callback  — validates its params, changes no state, carries no secret
#   /deploy/webhook/github          — HMAC-verified (cp_github_webhook_secret), rejects bad sigs
# cp-api itself stays bound to 127.0.0.1, so nginx is the only way in. Deliberately NOT included
# here: the per-role MCP gateway paths (/authorize, /token, /register, /login, /mcp) from the old
# Claude-App architecture — this build has no such service, and on the firm host those paths were
# still advertised publicly while answering 502.
#
# Usage:
#   sudo bash m6.3-composio-web.sh --domain claude.example.co.uk [--email admin@example.com]
# Rollback: m6.3-composio-web-rollback.sh
set -uo pipefail
DOMAIN=""; EMAIL="${CERTBOT_EMAIL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:?--domain needs a value}"; shift ;;
    --email)  EMAIL="${2:?--email needs a value}"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac; shift
done
[ -n "$DOMAIN" ] || { echo "ERROR: --domain is required" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

SITE=/etc/nginx/sites-available/claudeapp-composio.conf
LINK=/etc/nginx/sites-enabled/claudeapp-composio.conf
CB_ENV=/etc/claudeapp/composio-callback.env
log(){ printf '\n== %s ==\n' "$*"; }

log "sanity: does $DOMAIN point at this host?"
MYIP="$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)"
RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
echo "  this host: ${MYIP:-unknown}   $DOMAIN -> ${RESOLVED:-unresolved}"
if [ -n "$MYIP" ] && [ -n "$RESOLVED" ] && [ "$MYIP" != "$RESOLVED" ]; then
  echo "  WARN: the domain does not resolve to this host — certbot issuance will fail"
fi

log "writing the vhost (HTTP only; certbot adds TLS below)"
install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > "$SITE" <<EOF
# Managed by m6.3-composio-web.sh — exposes ONLY the Composio OAuth callback and the
# signature-verified GitHub deploy webhook. Everything else returns 404 on purpose.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Composio OAuth landing. cp-api validates uid/toolkit, changes no state, holds no secret.
    location = /integrations/composio/callback {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # GitHub push webhook for skill/MCP reconcile — HMAC-gated inside cp-api.
    location = /deploy/webhook/github {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / { return 404; }
}
EOF
ln -sfn "$SITE" "$LINK"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t 2>&1 | tail -2 || { echo "ERROR: nginx config test failed"; exit 1; }
systemctl reload nginx 2>/dev/null || systemctl restart nginx

log "TLS"
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  echo "  certificate for $DOMAIN already present — reusing it"
  # Re-run the installer so the vhost we just wrote gets the ssl directives back.
  certbot --nginx --reinstall -d "$DOMAIN" --non-interactive 2>&1 | tail -3 || \
    echo "  WARN: certbot --reinstall reported an issue; check 'nginx -T' for ssl directives"
elif command -v certbot >/dev/null 2>&1; then
  if [ -n "$EMAIL" ]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect 2>&1 | tail -4
  else
    echo "  no certificate and no --email given — skipping issuance."
    echo "  run: certbot --nginx -d $DOMAIN -m <email> --agree-tos --redirect"
  fi
else
  echo "  certbot not installed — skipping TLS"
fi
nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

log "pointing tenants at this deployment's own callback base"
install -d -m 0755 /etc/claudeapp
printf 'COMPOSIO_CALLBACK_BASE=https://%s\n' "$DOMAIN" > "$CB_ENV"
chmod 0644 "$CB_ENV"
echo "  wrote $CB_ENV -> https://$DOMAIN"
echo "  NOTE: claude-pod-run passes this into each pod at start, so tenants pick it up on"
echo "        their next pod restart (systemctl restart claude-pod@<user>)."

log "verify"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
  "https://$DOMAIN/integrations/composio/callback?uid=1&toolkit=probe&status=failed" 2>/dev/null || echo 000)"
echo "  callback endpoint  -> HTTP $CODE  (200 = serving)"
for p in /sessions /approvals /registry/artifacts; do
  printf '  %-22s -> HTTP %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$DOMAIN$p" 2>/dev/null || echo 000)"
done
echo "  ^ those must be 404: the rest of cp-api is not public"
echo
echo "== DONE — rollback: bash $(dirname "$0")/m6.3-composio-web-rollback.sh =="
