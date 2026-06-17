#!/usr/bin/env bash
# M1.5 — bring up the control-plane services as Podman containers on cp-net:
#   cp-audit-collector  (hash-chain WORM sink, unix socket)
#   cp-api              (Fastify: initData auth, /auth/session, /me) on 127.0.0.1:8080
#
# Run as root on the host. Idempotent (recreates the service containers each run;
# stores cp-postgres/cp-redis from m1.2 are left running). Prompts once, silently,
# for the vitaliy bot token and stores it as a podman secret (never a file/argv).
#
# Services run the TypeScript directly via the workspace's tsx (no build step):
# the repo is bind-mounted read-only at its real path so pnpm's symlinked
# node_modules resolve. Secrets are mounted as files under /run/secrets and read
# at container start; the PG password is composed into DATABASE_URL in-container
# only. Stores are reached by container DNS (cp-postgres/cp-redis on cp-net).
#
# Pilot: vitaliy only. All artifacts tracked for teardown (project_fleet_dev_teardown).
set -euo pipefail

REPO=/home/vitaliy/work/fleet-platform/control-plane
NODE_IMAGE=docker.io/library/node:22-alpine
PG_SECRET=cp_pg_password
BOT_SECRET=cp_bot_token
JWT_SECRET=cp_jwt_secret
API_PORT=8080
SRV_AUDIT=/srv/audit
# M5.1: tenant whose sandbox the authoring fs API serves (GET /fs/tree, PUT
# /fs/file). The home is bind-mounted into cp-api; fs-safety.ts confines paths.
# Pilot: vitaliy only.
TENANT=vitaliy
# M5.4b: bot username (no @) for Mini App deep links in approval notifications.
# Optional — empty means notifications go out without the url-button.
BOT_USERNAME="${TELEGRAM_BOT_USERNAME:-}"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# ---- preflight -------------------------------------------------------------
command -v podman >/dev/null 2>&1 || die "podman not installed (run m1.2-stores.sh first)"
podman container exists cp-postgres || die "cp-postgres not found (run m1.2-stores.sh first)"
podman container exists cp-redis    || die "cp-redis not found (run m1.2-stores.sh first)"
podman secret inspect "$PG_SECRET" >/dev/null 2>&1 || die "$PG_SECRET secret missing (m1.2)"
[ -d "$REPO/node_modules" ] || die "node_modules missing in $REPO — run 'corepack pnpm install' as vitaliy"
[ -e "$REPO/apps/api/node_modules/@fleet/scanners" ] || die "@fleet/scanners not linked into apps/api — run 'corepack pnpm install' as vitaliy (m5.1 dep)"

# ---- secrets ---------------------------------------------------------------
# Bot token: prompt silently, store as podman secret. Used for LOCAL initData
# HMAC verification (not an outbound call) → local credential, not OneCLI.
if ! podman secret inspect "$BOT_SECRET" >/dev/null 2>&1; then
  printf 'Paste the vitaliy Telegram bot token (hidden), then Enter: ' >&2
  read -rs BOT_TOKEN; echo >&2
  [ -n "${BOT_TOKEN:-}" ] || die "empty bot token"
  printf '%s' "$BOT_TOKEN" | podman secret create "$BOT_SECRET" - >/dev/null
  unset BOT_TOKEN
  echo "stored $BOT_SECRET"
else
  echo "$BOT_SECRET already exists"
fi

# JWT signing secret: generated, never displayed.
if ! podman secret inspect "$JWT_SECRET" >/dev/null 2>&1; then
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64 | podman secret create "$JWT_SECRET" - >/dev/null
  echo "generated $JWT_SECRET"
else
  echo "$JWT_SECRET already exists"
fi

# ---- audit storage ---------------------------------------------------------
log "audit storage"
mkdir -p "$SRV_AUDIT"  # created root-owned by the root-run script; no chown needed
# Append-only directory: entries can be added but not removed/renamed. Combined
# with the per-record hash-chain this makes tampering detectable. (Per-file +a
# is a later hardening step.)
chattr +a "$SRV_AUDIT" 2>/dev/null || echo "note: chattr +a not supported on this fs — relying on hash-chain"
podman volume exists cp-audit-run >/dev/null 2>&1 || podman volume create cp-audit-run >/dev/null

# audit group: tenant pods join it (--group-add, see runtime/systemd/claude-pod-run)
# for WRITE-ONLY access to the collector socket (root:audit 0660); they never get
# read/mutate access to $SRV_AUDIT. A system group resolved BY NAME everywhere, so
# the product is portable across servers regardless of the assigned gid.
getent group audit >/dev/null 2>&1 || groupadd --system audit
AUDIT_GID="$(getent group audit | cut -d: -f3)"
echo "audit group: gid=$AUDIT_GID"

# ---- pull runtime image ----------------------------------------------------
podman image exists "$NODE_IMAGE" || { log "pulling $NODE_IMAGE"; podman pull "$NODE_IMAGE" >/dev/null; }

# NOTE on networking: aardvark-dns name resolution on the cp-net bridge proved
# unreliable on this host (containers couldn't resolve cp-postgres/cp-redis), so
# the services use host networking and reach the stores via their published
# loopback ports (127.0.0.1:5433 / :6380). The audit socket is shared via a
# volume, independent of networking. (Hardening to a DNS-enabled network or a
# shared pod is a later item.)

# ---- cp-audit-collector ----------------------------------------------------
log "starting cp-audit-collector"
podman rm -f cp-audit-collector >/dev/null 2>&1 || true
podman run -d --name cp-audit-collector --network host \
  --workdir "$REPO" \
  -v "$REPO:$REPO:ro" \
  -v "$SRV_AUDIT:/srv/audit" \
  -v cp-audit-run:/run/audit \
  -e AUDIT_GID="$AUDIT_GID" \
  -e REDIS_URL=redis://127.0.0.1:6380 \
  --secret "$PG_SECRET" \
  --restart=unless-stopped \
  "$NODE_IMAGE" \
  sh -c 'set -e; export AUDIT_DIR=/srv/audit AUDIT_SOCKET=/run/audit/collector.sock;
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/'"$PG_SECRET"')@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/audit-collector/src/index.ts' >/dev/null

# ---- cp-api ----------------------------------------------------------------
# This is the CANONICAL cp-api stanza — m5.1-authoring-api.sh used to recreate
# the container with extra mounts and the 2026-06-11 m1.5 re-run silently
# dropped them (FileTree/PUT /fs broke). Every later increment lands HERE.
log "starting cp-api (127.0.0.1:${API_PORT})"
[ -d "/home/${TENANT}/.claude" ] || die "tenant sandbox /home/${TENANT}/.claude missing"
podman rm -f cp-api >/dev/null 2>&1 || true
# /run/cp-secretd: cp-secretd activation socket (M5.5b, runtime/install/
# m5.5b-secretd.sh). Dir-bind: the socket appears when the helper is installed;
# absent helper only degrades secretSpec connects (clear error), nothing else.
mkdir -p /run/cp-secretd
# A2: GitHub push-webhook HMAC secret (INBOUND verification → a LOCAL credential
# like JWT, NOT OneCLI). Referenced ONLY if the operator created it
# (`openssl rand -hex 32 | podman secret create cp_github_webhook_secret -`).
# Absent ⇒ /deploy/webhook/github stays dormant (503), nothing else changes — so
# m1.5 stays runnable on a box without it.
WH_SECRET_ARG=""
WH_EXPORT=""
if podman secret inspect cp_github_webhook_secret >/dev/null 2>&1; then
  WH_SECRET_ARG="--secret cp_github_webhook_secret"
  WH_EXPORT="export GITHUB_WEBHOOK_SECRET_FILE=/run/secrets/cp_github_webhook_secret;"
  log "github webhook secret present → wiring it into cp-api"
fi
# -v /home:/home (NOT a single tenant): cp-api is the MULTI-TENANT control plane —
# it reads/writes every tenant's ~/.claude + ~/work (fs API, mcp-gate) and each
# bot's .env token for multi-bot Mini App initData verification. Single-tenant
# mount broke the 2nd tenant (dmrudenko, 2026-06-15).
podman run -d --name cp-api --network host \
  --workdir "$REPO" \
  -v "$REPO:$REPO:ro" \
  -v cp-audit-run:/run/audit \
  -v /run/cp-secretd:/run/cp-secretd \
  -v /home:/home \
  --secret "$PG_SECRET" --secret "$BOT_SECRET" --secret "$JWT_SECRET" $WH_SECRET_ARG \
  --restart=unless-stopped \
  "$NODE_IMAGE" \
  sh -c 'set -e;
    # M5.5: best-effort git for committing settings.json to the tenant git HEAD
    # after an approved MCP connect (node:alpine has no git). Survives restarts
    # (container fs persists); failure is tolerated — apply degrades to committed=false.
    command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1 || true;
    export HOST=127.0.0.1 PORT='"$API_PORT"' REDIS_URL=redis://127.0.0.1:6380 AUDIT_SOCKET=/run/audit/collector.sock TENANT_HOME_ROOT=/home;
    export TELEGRAM_BOT_TOKEN_FILE=/run/secrets/'"$BOT_SECRET"' JWT_SECRET_FILE=/run/secrets/'"$JWT_SECRET"';
    '"$WH_EXPORT"'
    export TELEGRAM_BOT_USERNAME='"$BOT_USERNAME"';
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/'"$PG_SECRET"')@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/api/src/index.ts' >/dev/null

# reboot persistence for all --restart containers
systemctl enable podman-restart.service >/dev/null 2>&1 || true

# ---- health ----------------------------------------------------------------
log "waiting for cp-api /healthz"
ok=""
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then ok=1; echo "healthz OK"; break; fi
  for c in cp-api cp-audit-collector; do
    [ "$(podman inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" = "running" ] || { echo "$c not running:"; podman logs --tail 30 "$c" 2>&1 || true; exit 1; }
  done
  sleep 1
done
[ -n "$ok" ] || { echo "cp-api did not answer /healthz:"; podman logs --tail 40 cp-api 2>&1 || true; exit 1; }

log "status"
podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}  {{.Ports}}'
