#!/usr/bin/env bash
# M1.2 — control-plane data stores on Podman: PostgreSQL + Redis, isolated on
# 127.0.0.1. Then apply migrations + seed.
#
# WHY run as root on the host (not from the bot): a tenant bot's systemd unit
# uses ProtectSystem=strict (ReadWritePaths=/home/<tenant> only), so the bot's
# process tree sees /usr /var /etc /opt as read-only even with sudo — it cannot
# install packages, create users, or run rootful podman. This script is the
# host-side step; the bot then builds the services (M1.3/M1.4) in the repo and
# verifies via `podman exec`.
#
# DEV bring-up: this recreates the stores from a clean slate every run (there is
# no real data in M1 yet). The productized quadlet install (M1.5) will NOT wipe.
#
# Pilot scope: vitaliy only. All artifacts are dev-scaffolding tracked for
# teardown (memory project_fleet_dev_teardown).
set -euo pipefail

PG_PORT=5433
REDIS_PORT=6380
PG_USER=cplane
PG_DB=control_plane
SECRET=cp_pg_password
# Repo root derived from THIS script's location ($ROOT/control-plane/install/…),
# so the installer is portable to any path/host (no hardcoded /home/<user>).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
REPO="$ROOT/control-plane"
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

# 3) clean slate (dev: no real data yet) — avoids half-initialised volumes and
#    stale/crash-looping containers from earlier attempts.
log "removing any prior cp-* state"
podman rm -f cp-postgres cp-redis >/dev/null 2>&1 || true
podman volume rm cp-pgdata >/dev/null 2>&1 || true
podman secret rm "$SECRET" >/dev/null 2>&1 || true

# 4) Postgres password — generated fresh, stored as a podman secret (never a file
#    on disk; mounted into the container only). Kept in PW for the migrate step.
#    OneCLI is for EXTERNAL-request secrets (HTTPS egress injection); a local
#    store credential is internal, so a podman secret is the right mechanism.
log "creating podman secret $SECRET"
PW="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)"
printf '%s' "$PW" | podman secret create "$SECRET" - >/dev/null

# 5) network
podman network exists cp-net >/dev/null 2>&1 || { log "creating network cp-net"; podman network create cp-net >/dev/null; }

# 6) postgres — password injected via file (POSTGRES_PASSWORD_FILE + mounted
#    secret); this is the robust path (env-type secret injection was unreliable).
log "starting cp-postgres (127.0.0.1:${PG_PORT})"
podman run -d --name cp-postgres --network cp-net \
  -p 127.0.0.1:${PG_PORT}:5432 \
  -e POSTGRES_USER="${PG_USER}" -e POSTGRES_DB="${PG_DB}" \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/${SECRET} \
  --secret "${SECRET}" \
  -v cp-pgdata:/var/lib/postgresql \
  --restart=unless-stopped \
  "${PG_IMAGE}" >/dev/null

# 7) redis
log "starting cp-redis (127.0.0.1:${REDIS_PORT})"
podman run -d --name cp-redis --network cp-net \
  -p 127.0.0.1:${REDIS_PORT}:6379 \
  --restart=unless-stopped \
  "${REDIS_IMAGE}" >/dev/null

# 8) wait for postgres — fail loudly with logs if it never comes up
log "waiting for postgres to accept connections"
ready=""
for _ in $(seq 1 60); do
  if podman exec cp-postgres pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then ready=1; echo "ready"; break; fi
  # if the container died, stop waiting and show why
  if [ "$(podman inspect -f '{{.State.Status}}' cp-postgres 2>/dev/null)" != "running" ]; then break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "ERROR: cp-postgres did not become ready. Status + logs:"
  podman inspect -f 'status={{.State.Status}} exitcode={{.State.ExitCode}}' cp-postgres 2>&1 || true
  podman logs --tail 40 cp-postgres 2>&1 || true
  exit 1
fi

# 9) migrations + seed — drizzle-kit/tsx invoked directly via `pnpm exec`
#    (package.json wrappers call bare `pnpm`, not on PATH here). Run as the repo
#    OWNER: root on a greenfield install (repo cloned by root) or the tenant user
#    on the pilot host (repo in their home) — auto-detected, so this is portable.
OWNER="$(stat -c %U "$REPO" 2>/dev/null)"; id "$OWNER" >/dev/null 2>&1 || OWNER=root
log "applying migrations + seed (as ${OWNER}, against 127.0.0.1:${PG_PORT})"
MIGRATE_CMD="cd '${REPO}' \
  && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  && export DATABASE_URL='postgres://${PG_USER}:${PW}@127.0.0.1:${PG_PORT}/${PG_DB}' \
  && corepack pnpm install --silent \
  && corepack pnpm --filter @fleet/db exec drizzle-kit migrate \
  && corepack pnpm --filter @fleet/db exec tsx src/seed.ts"
if [ "$OWNER" = "root" ]; then
  bash -lc "$MIGRATE_CMD"
else
  sudo -u "$OWNER" -H bash -lc "$MIGRATE_CMD"
fi
unset PW

log "status"
podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}  {{.Ports}}'
