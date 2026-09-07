#!/usr/bin/env bash
# m8.2-chat-registry.sh — let a tenant publish/import artifacts FROM CHAT.
#
#   apply     mint per-tenant registry tokens, expose /registry/* to the pod subnet,
#             recreate cp-api with the token map mounted read-only
#   rollback  bash m8.2-chat-registry-rollback.sh
#
# WHY THIS EXISTS. M8.1 built the whole marketplace — cp-api routes, DB tables, the
# pod-side publisher, the entrypoint task executor — but its only front door is a Mini
# App session JWT, and this host has no web front end: nginx answers 404 for every path
# except the Composio callback and the deploy webhook. So on 2026-09-04 nobody could
# reach publish/import by any route, while all 30 tenant guides documented a
# `share-skill` command that was never written. Vitaliy chose the chat route over
# standing up a web UI: these users live in Telegram.
#
# WHAT IT DOES NOT WEAKEN. The token buys exactly what a browser session buys. Every
# publish and import still goes through the scanners (fail-closed) and the approval
# flow; a non-admin still needs an approval to publish. The token is an authentication
# path, not an authorisation bypass.
#
# SHAPE COPIED ON PURPOSE from two things that already work on this host:
#   * token model  — apps/dbread-gateway: the map holds sha256(token) → os username, so
#                    it is not itself a credential; cp-api re-reads it per request, so
#                    deleting a line revokes instantly; unreadable map = nobody in.
#   * pod exposure — m9.1-dbread-gateway.sh: pods cannot reach a host loopback service,
#                    so a listener on the bridge gateway plus ONE narrow nft rule. Here
#                    the listener is nginx rather than socat, because socat cannot filter
#                    paths and cp-api also serves fs/sessions/deploy routes that a pod has
#                    no business reaching. nginx proxies /registry/ and 404s the rest.
set -euo pipefail

ACTION="${1:-apply}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="$REPO_ROOT/control-plane"

TOKENS_DIR=/etc/claudeapp/registry
TOKENS_FILE="$TOKENS_DIR/tokens.json"
POD_PORT=10257
API_PORT=8080
NGINX_CONF=/etc/nginx/sites-enabled/cl-registry-pods.conf
NODE_IMAGE=docker.io/library/node:22-alpine

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$ACTION" = "apply" ] || die "only 'apply' here; use m8.2-chat-registry-rollback.sh"

command -v nginx >/dev/null || die "nginx not installed"
command -v nft   >/dev/null || die "nftables not installed"
[ -f /etc/cl-egress.env ] || die "/etc/cl-egress.env missing — run m2.3-egress.sh first"
# shellcheck disable=SC1091
. /etc/cl-egress.env
[ -n "${GW:-}" ] && [ -n "${SUBNET:-}" ] || die "GW/SUBNET not set in /etc/cl-egress.env"
podman inspect cp-api >/dev/null 2>&1 || die "cp-api container not found"

# ── 1. per-tenant tokens ─────────────────────────────────────────────────────
# Idempotent: a tenant who already has a token keeps it, so re-running does not
# invalidate a token the pod has already been told about.
log "minting per-tenant registry tokens"
install -d -m 0700 "$TOKENS_DIR"
[ -f "$TOKENS_FILE" ] || printf '{}\n' > "$TOKENS_FILE"
chmod 0600 "$TOKENS_FILE"

python3 - "$TOKENS_FILE" <<'PY'
import glob, hashlib, json, os, secrets, sys, pwd

tokens_file = sys.argv[1]
try:
    m = json.load(open(tokens_file))
except Exception:
    m = {}
# digest -> os username; invert to find who already has one
have = set(m.values())
minted, kept = [], []
for home in sorted(glob.glob("/home/*/")):
    u = home.rstrip("/").split("/")[-1]
    if u == "cplane":
        continue
    try:
        pw = pwd.getpwnam(u)
    except KeyError:
        continue
    tok_path = os.path.join(home, ".claude", "registry.token")
    if u in have and os.path.exists(tok_path):
        kept.append(u)
        continue
    tok = "reg_" + secrets.token_urlsafe(32)
    # drop any stale digest for this tenant before adding the new one
    for d, who in list(m.items()):
        if who == u:
            del m[d]
    m[hashlib.sha256(tok.encode()).hexdigest()] = u
    os.makedirs(os.path.dirname(tok_path), exist_ok=True)
    old = os.umask(0o077)
    try:
        with open(tok_path, "w") as f:
            f.write(tok + "\n")
    finally:
        os.umask(old)
    os.chmod(tok_path, 0o600)
    os.chown(tok_path, pw.pw_uid, pw.pw_gid)
    minted.append(u)
json.dump(m, open(tokens_file, "w"), indent=2, sort_keys=True)
os.chmod(tokens_file, 0o600)
print(f"  minted {len(minted)}, kept {len(kept)}, map holds {len(m)} digests")
PY

# ── 2. cp-api: mount the token map read-only, same args otherwise ────────────
# Captured from the live container on 2026-09-04 (podman inspect), not from an older
# installer, so nothing silently regresses. cp-api runs tsx straight from the mounted
# source tree, so this recreate also picks up registry-routes.ts.
log "recreating cp-api with $TOKENS_DIR mounted read-only"
podman rm -f cp-api >/dev/null 2>&1 || true
podman run -d --name cp-api --network host \
  --workdir "$REPO" \
  -v "$REPO:$REPO:ro" \
  -v cp-audit-run:/run/audit \
  -v /run/cp-secretd:/run/cp-secretd \
  -v /home:/home \
  -v "$TOKENS_DIR:$TOKENS_DIR:ro" \
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
    export REGISTRY_TOKENS_FILE='"$TOKENS_FILE"';
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/cp_pg_password)@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/api/src/index.ts' >/dev/null

ok=""
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1 && { ok=1; break; }
  [ "$(podman inspect -f '{{.State.Status}}' cp-api 2>/dev/null)" = "running" ] \
    || { podman logs --tail 40 cp-api 2>&1; die "cp-api not running"; }
  sleep 1
done
[ -n "$ok" ] || { podman logs --tail 40 cp-api 2>&1; die "cp-api did not answer /healthz"; }
echo "  healthz OK"
code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$API_PORT/registry/items" || echo ERR)
[ "$code" = "401" ] || die "/registry/items answered $code, expected 401 (route missing?)"
echo "  /registry/items -> 401 (route alive, auth required)"

# ── 3. pod-facing listener: nginx, /registry/ only ───────────────────────────
log "exposing /registry/ to the pod subnet on $GW:$POD_PORT"
cat > "$NGINX_CONF" <<CONF
# Managed by m8.2-chat-registry.sh — the ONLY cp-api surface tenant pods may reach.
# cp-api runs --network host and binds 127.0.0.1, which a pod's netns cannot reach; this
# is the bridge-gateway listener that m9.1 does with socat, except paths are filtered
# because cp-api also serves fs/sessions/deploy routes that a pod must not touch.
server {
    listen $GW:$POD_PORT;
    server_name _;
    client_max_body_size 2m;

    location ^~ /registry/ {
        proxy_pass http://127.0.0.1:$API_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
    }
    location / { return 404; }
}
CONF
nginx -t >/dev/null 2>&1 || { nginx -t; rm -f "$NGINX_CONF"; die "nginx config invalid — reverted"; }
systemctl reload nginx || die "nginx reload failed"
echo "  nginx reloaded"

log "allowing $SUBNET -> host tcp/$POD_PORT (scoped; everything else stays dropped)"
if nft list chain inet cl_egress input 2>/dev/null | grep -q "dport $POD_PORT"; then
  echo "  rule already present"
else
  nft insert rule inet cl_egress input ip saddr "$SUBNET" tcp dport "$POD_PORT" counter accept \
    || die "could not insert the nft rule"
  echo "  rule inserted"
fi
TMPL="$REPO_ROOT/runtime/nftables/cl-egress.nft.tmpl"
if [ -f "$TMPL" ] && ! grep -q "dport $POD_PORT" "$TMPL"; then
  sed -i "s#\(.*ip saddr __SUBNET__ tcp dport 10255 counter accept\)#\1\n    ip saddr __SUBNET__ tcp dport $POD_PORT counter accept#" "$TMPL"
  echo "  added to the nft template for reboot persistence"
fi

# ── 4. prove it end-to-end from inside a pod ─────────────────────────────────
log "verifying from a tenant pod (catalog read with that tenant's own token)"
probe=""
for u in $(ls /etc/claudeapp/image-pin 2>/dev/null) $(ls /home | head -3); do
  podman inspect "claude-$u" >/dev/null 2>&1 || continue
  [ -f "/home/$u/.claude/registry.token" ] || continue
  probe="$u"; break
done
[ -n "$probe" ] || die "no running pod with a token to verify against"
out=$(podman exec "claude-$probe" sh -lc \
  'curl -sS -m 20 -o /tmp/reg.json -w "%{http_code}" -H "Authorization: Bearer $(cat ~/.claude/registry.token)" http://'"$GW:$POD_PORT"'/registry/items' 2>&1 || echo ERR)
echo "  $probe: GET /registry/items -> $out"
[ "$out" = "200" ] || die "pod could not read the catalog (got $out)"
echo "  body: $(podman exec "claude-$probe" sh -lc 'head -c 200 /tmp/reg.json' 2>/dev/null)"
echo "  anonymous request from the same pod (must be 401):"
anon=$(podman exec "claude-$probe" sh -lc 'curl -sS -m 20 -o /dev/null -w "%{http_code}" http://'"$GW:$POD_PORT"'/registry/items' 2>&1 || echo ERR)
echo "    -> $anon"
[ "$anon" = "401" ] || die "unauthenticated pod request returned $anon, expected 401"
echo "  a non-registry cp-api path from the pod (must be 404):"
other=$(podman exec "claude-$probe" sh -lc 'curl -sS -m 20 -o /dev/null -w "%{http_code}" http://'"$GW:$POD_PORT"'/sessions' 2>&1 || echo ERR)
echo "    -> $other"
[ "$other" = "404" ] || die "pod reached a non-registry path ($other) — the filter is not holding"

cat <<EOF

== DONE ==
tokens:   $TOKENS_FILE (sha256 only, 0600) + ~/.claude/registry.token per tenant (0600, tenant-owned)
pod URL:  http://$GW:$POD_PORT/registry/...  (only /registry/ is proxied; everything else 404)
gate:     scanners + approval unchanged — the token authenticates, it does not authorise

Rollback: sudo bash $HERE/m8.2-chat-registry-rollback.sh
EOF
