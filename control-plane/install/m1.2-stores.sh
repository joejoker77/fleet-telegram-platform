#!/usr/bin/env bash
# M1.2 — control-plane data stores on Podman: PostgreSQL + Redis, isolated on
# 127.0.0.1. Idempotent. Brings up the stores, then applies migrations + seed.
#
# WHY run as root on the host (not from the bot): the vitaliy bot's systemd unit
# uses ProtectSystem=strict (ReadWritePaths=/home/vitaliy only), so the bot's
# process tree sees /usr /var /etc /opt as read-only even with sudo — it cannot
# install packages, create users, or run rootful podman. This script is the
# host-side step; the bot then builds the services (M1.3/M1.4) in the repo and
# verifies via `podman exec` (no DB password needed for that).
#
# Pilot scope: vitaliy only. Everything here is dev-scaffolding tracked for
# teardown (see memory project_fleet_dev_teardown).
set -euo pipefail

PG_PORT=5433
REDIS_PORT=6380
PG_USER=cplane
PG_DB=control_plane
SECRET=cp_pg_password
REPO=/home/vitaliy/work/fleet-platform/control-plane
PG_IMAGE=docker.io/library/postgres:18-alpine
REDIS_IMAGE=docker.io/library/redis:7-alpine

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

# 1) podman
if ! command -v podman >/dev/null 2>&1; then
  log "installing podman"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y podman
fi
echo "podman $(podman --version)"

# 2) cplane system user (runs the control-plane Node services later, M1.4/M1.5)
if ! id cplane >/dev/null 2>&1; then
  log "creating cplane system user"
  useradd --system --create-home --home-dir /home/cplane --shell /usr/sbin/nologin cplane
fi
id cplane

# 3) Postgres password — generated once, stored as a podman secret (never a file).
#    NOTE on the OneCLI rule: OneCLI is for EXTERNAL-request secrets (injected at
#    the HTTPS egress proxy). A local store credential is internal, so the right
#    mechanism is a podman/systemd secret, not OneCLI. Consistent with the rule.
if ! podman secret inspect "$SECRET" >/dev/null 2>&1; then
  log "creating podman secret $SECRET"
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40 | podman secret create "$SECRET" - >/dev/null
else
  echo "secret $SECRET already exists"
fi

# 4) network
podman network exists cp-net >/dev/null 2>&1 || { log "creating network cp-net"; podman network create cp-net >/dev/null; }

# 5) postgres
if ! podman container exists cp-postgres; then
  log "starting cp-postgres (127.0.0.1:${PG_PORT})"
  podman run -d --name cp-postgres --network cp-net \
    -p 127.0.0.1:${PG_PORT}:5432 \
    -e POSTGRES_USER="${PG_USER}" -e POSTGRES_DB="${PG_DB}" \
    --secret "${SECRET},type=env,target=POSTGRES_PASSWORD" \
    -v cp-pgdata:/var/lib/postgresql/data \
    --restart=unless-stopped \
    "${PG_IMAGE}" >/dev/null
else
  podman start cp-postgres >/dev/null 2>&1 || true
fi

# 6) redis
if ! podman container exists cp-redis; then
  log "starting cp-redis (127.0.0.1:${REDIS_PORT})"
  podman run -d --name cp-redis --network cp-net \
    -p 127.0.0.1:${REDIS_PORT}:6379 \
    --restart=unless-stopped \
    "${REDIS_IMAGE}" >/dev/null
else
  podman start cp-redis >/dev/null 2>&1 || true
fi

# 7) wait for postgres
log "waiting for postgres to accept connections"
for _ in $(seq 1 60); do
  podman exec cp-postgres pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1 && { echo "ready"; break; }
  sleep 1
done

# 8) migrations + seed. Idempotent: read the live password from the running
#    container (not the unreadable secret), and invoke drizzle-kit/tsx directly
#    via `pnpm exec` — the package.json wrapper scripts call bare `pnpm`, which
#    isn't on PATH (we only use `corepack pnpm`), so they fail in this context.
log "applying migrations + seed (as vitaliy, against 127.0.0.1:${PG_PORT})"
PW="$(podman exec cp-postgres printenv POSTGRES_PASSWORD)"
[ -n "$PW" ] || { echo "could not read POSTGRES_PASSWORD from cp-postgres"; exit 1; }
sudo -u vitaliy -H bash -lc "cd '${REPO}' \
  && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  && export DATABASE_URL='postgres://${PG_USER}:${PW}@127.0.0.1:${PG_PORT}/${PG_DB}' \
  && corepack pnpm install --silent \
  && corepack pnpm --filter @fleet/db exec drizzle-kit migrate \
  && corepack pnpm --filter @fleet/db exec tsx src/seed.ts"
unset PW

log "status"
podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}  {{.Ports}}'
