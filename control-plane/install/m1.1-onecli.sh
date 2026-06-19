#!/usr/bin/env bash
# M1.1 — OneCLI secret vault + egress gateway, on PODMAN (single runtime; no Docker).
#
# Stands up the OneCLI stack as rootful podman containers on loopback:
#   onecli-pg   postgres:18-alpine            (the vault's own DB, on onecli-net)
#   onecli      ghcr.io/onecli/onecli:<ver>   app UI :10254 + secret-injection gateway :10255
#
# This is the secrets backbone every tenant pod reaches through the cl-egress
# forwarder (10.89.1.1:10255 -> host 127.0.0.1:10255). The control plane's own
# store creds use podman secrets (m1.2); OneCLI holds EXTERNAL-service keys that
# get injected at the egress proxy. Must run BEFORE egress (m2.3) and before any
# per-tenant agent bind (m2.4).
#
# Idempotent. Run as root. The vault's OWN bootstrap secrets (db password +
# SECRET_ENCRYPTION_KEY) are GENERATED FRESH on THIS host and persisted root-only
# at $STATE_DIR/onecli.env — never copied from another machine. Re-runs reuse them
# so the encrypted data + DB stay readable.
set -euo pipefail

ONECLI_IMAGE_REPO="${ONECLI_IMAGE_REPO:-ghcr.io/onecli/onecli}"
ONECLI_VERSION="${ONECLI_VERSION:-latest}"
PG_IMAGE=docker.io/library/postgres:18-alpine
NET=onecli-net
STATE_DIR=/opt/onecli
ENVF="$STATE_DIR/onecli.env"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v podman >/dev/null 2>&1 || die "podman not installed (run the deps phase / m1.2 first)"
command -v openssl >/dev/null 2>&1 || die "openssl not installed (run the deps phase)"

# 1) bootstrap secrets — generated ON THIS host, persisted root-only, reused on re-run
install -d -m 0700 "$STATE_DIR"
if [ ! -f "$ENVF" ]; then
  log "generating OneCLI bootstrap secrets (root-only $ENVF)"
  PGPW="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 40)"
  ENCKEY="$(openssl rand -base64 32)"   # 32 random bytes, base64 (matches the vault key format)
  umask 077
  cat > "$ENVF" <<EOF
ONECLI_BIND_HOST=127.0.0.1
ONECLI_APP_PORT=10254
ONECLI_GATEWAY_PORT=10255
POSTGRES_PORT=5432
POSTGRES_USER=onecli
POSTGRES_DB=onecli
POSTGRES_PASSWORD=$PGPW
SECRET_ENCRYPTION_KEY=$ENCKEY
ONECLI_VERSION=$ONECLI_VERSION
EOF
  chmod 600 "$ENVF"
else
  log "reusing existing OneCLI secrets ($ENVF)"
fi
# load for DATABASE_URL composition + port binding
set -a; . "$ENVF"; set +a
BIND="${ONECLI_BIND_HOST:-127.0.0.1}"
APP_PORT="${ONECLI_APP_PORT:-10254}"
GW_PORT="${ONECLI_GATEWAY_PORT:-10255}"

# 2) images
podman image exists "$PG_IMAGE" || { log "pulling $PG_IMAGE"; podman pull "$PG_IMAGE" >/dev/null; }
ONECLI_IMAGE="${ONECLI_IMAGE_REPO}:${ONECLI_VERSION}"
podman image exists "$ONECLI_IMAGE" || { log "pulling $ONECLI_IMAGE"; podman pull "$ONECLI_IMAGE" >/dev/null; }

# 3) network
podman network exists "$NET" >/dev/null 2>&1 || { log "creating network $NET"; podman network create "$NET" >/dev/null; }

# 4) postgres
log "starting onecli-pg"
podman rm -f onecli-pg >/dev/null 2>&1 || true
podman run -d --name onecli-pg --network "$NET" \
  --env-file "$ENVF" \
  -v onecli-pgdata:/var/lib/postgresql \
  --restart=unless-stopped \
  "$PG_IMAGE" >/dev/null

log "waiting for onecli-pg"
ready=""
for _ in $(seq 1 60); do
  if podman exec onecli-pg pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then ready=1; echo ready; break; fi
  [ "$(podman inspect -f '{{.State.Status}}' onecli-pg 2>/dev/null)" = "running" ] || break
  sleep 1
done
[ -n "$ready" ] || { podman logs --tail 40 onecli-pg 2>&1 || true; die "onecli-pg never became ready"; }

# 5) onecli app + gateway
log "starting onecli ($ONECLI_IMAGE)"
podman rm -f onecli >/dev/null 2>&1 || true
podman run -d --name onecli --network "$NET" \
  -p "${BIND}:${APP_PORT}:10254" -p "${BIND}:${GW_PORT}:10255" \
  --env-file "$ENVF" \
  -e DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@onecli-pg:5432/${POSTGRES_DB}" \
  -e APP_URL="http://${BIND}:${APP_PORT}" \
  -e NEXT_PUBLIC_APP_URL="http://${BIND}:${APP_PORT}" \
  -v onecli-appdata:/app/data \
  --restart=unless-stopped \
  "$ONECLI_IMAGE" >/dev/null

# 6) wait for the gateway port to answer (any HTTP response = up)
log "waiting for OneCLI gateway :${GW_PORT}"
up=""
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://${BIND}:${GW_PORT}/" 2>/dev/null || echo 000)"
  if [ "$code" != "000" ]; then up=1; echo "gateway responding (HTTP $code)"; break; fi
  [ "$(podman inspect -f '{{.State.Status}}' onecli 2>/dev/null)" = "running" ] || { echo "onecli container not running:"; podman logs --tail 40 onecli 2>&1 || true; die "onecli crashed"; }
  sleep 2
done
[ -n "$up" ] || { echo "gateway not answering; recent onecli logs:"; podman logs --tail 50 onecli 2>&1 || true; die "OneCLI gateway never came up"; }

log "status"
podman ps --filter name=onecli --format '{{.Names}}  {{.Status}}  {{.Ports}}'
