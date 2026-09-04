#!/usr/bin/env bash
# m8.2-chat-registry-rollback.sh — undo m8.2-chat-registry.sh in one command.
#
# Removes the pod-facing listener and its firewall hole, drops the token map, and
# recreates cp-api without the mount (so the chat path stops authenticating even if a
# token file survives in someone's home). Tenant token files are deleted too.
#
# What it does NOT touch: the M8.1 routes, DB tables and the pod publisher — those
# predate this step. The Mini App JWT path is unaffected.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="$REPO_ROOT/control-plane"
TOKENS_DIR=/etc/claudeapp/registry
POD_PORT=10257
API_PORT=8080
NGINX_CONF=/etc/nginx/sites-enabled/cl-registry-pods.conf
NODE_IMAGE=docker.io/library/node:22-alpine

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

log "removing the pod-facing listener"
rm -f "$NGINX_CONF"
nginx -t >/dev/null 2>&1 && systemctl reload nginx && echo "  nginx reloaded" || echo "  nginx reload skipped"

log "removing the firewall hole for tcp/$POD_PORT"
handle=$(nft -a list chain inet cl_egress input 2>/dev/null | awk "/dport $POD_PORT/ {print \$NF; exit}")
if [ -n "${handle:-}" ]; then
  nft delete rule inet cl_egress input handle "$handle" && echo "  rule deleted"
else
  echo "  no rule found"
fi
TMPL="$REPO_ROOT/runtime/nftables/cl-egress.nft.tmpl"
[ -f "$TMPL" ] && sed -i "/dport $POD_PORT counter accept/d" "$TMPL" && echo "  template line removed"

log "dropping tokens"
rm -f /home/*/.claude/registry.token
rm -rf "$TOKENS_DIR"
echo "  tenant token files and the map are gone"

log "recreating cp-api without the token mount"
podman rm -f cp-api >/dev/null 2>&1 || true
podman run -d --name cp-api --network host \
  --workdir "$REPO" \
  -v "$REPO:$REPO:ro" \
  -v cp-audit-run:/run/audit \
  -v /run/cp-secretd:/run/cp-secretd \
  -v /home:/home \
  --secret cp_pg_password --secret cp_bot_token --secret cp_jwt_secret \
  --secret cp_github_webhook_secret \
  --restart=always \
  "$NODE_IMAGE" \
  sh -c 'set -e;
    command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1 || true;
    export HOST=127.0.0.1 PORT='"$API_PORT"' REDIS_URL=redis://127.0.0.1:6380 AUDIT_SOCKET=/run/audit/collector.sock TENANT_HOME_ROOT=/home;
    export TELEGRAM_BOT_TOKEN_FILE=/run/secrets/cp_bot_token JWT_SECRET_FILE=/run/secrets/cp_jwt_secret;
    export GITHUB_WEBHOOK_SECRET_FILE=/run/secrets/cp_github_webhook_secret;
    export TELEGRAM_BOT_USERNAME=;
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/cp_pg_password)@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/api/src/index.ts' >/dev/null

for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1 && { echo "  healthz OK"; break; }
  sleep 1
done
echo
echo "rolled back. The chat path is closed; the Mini App path is untouched."
