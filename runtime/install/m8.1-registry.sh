#!/usr/bin/env bash
# m8.1-registry.sh — deploy the M8.1 artifact marketplace control-plane side.
#   apply:    migration 0003 + restart cp-api (picks up registry routes)
#   rollback: drop the 0003 schema additions + restart cp-api
#
# What this DOES cover: the cp-api routes (publish/import/catalog) and the DB.
# What it does NOT (needs an image rebuild + pod restart, done separately):
#   • the pod-side `registry-publish` helper (Containerfile symlink, m2.1 build)
#   • the entrypoint registry-task executor
# And the Mini App frontend deploy is a dist copy (see notes at the end).
#
# Run as root on the host:  bash runtime/install/m8.1-registry.sh [apply|rollback]
set -euo pipefail

ACTION="${1:-apply}"
REPO="${REPO:-/home/vitaliy/work/fleet-platform}"
PG_USER=cplane
PG_DB=control_plane
PG_PORT=5433
TENANT_USER="${TENANT_USER:-vitaliy}"   # unprivileged user that owns the repo / runs drizzle

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v podman >/dev/null 2>&1 || die "podman not found"
podman ps --format '{{.Names}}' | grep -qx cp-postgres || die "cp-postgres container not running"

# Password lives only as a podman secret, mounted in cp-api at /run/secrets.
PW="$(podman exec cp-api cat /run/secrets/cp_pg_password 2>/dev/null | tr -d '\n')"
[ -n "$PW" ] || die "could not read cp_pg_password from cp-api"

psql_cp() { podman exec -i cp-postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"; }

case "$ACTION" in
  apply)
    log "applying migration 0003 (as $TENANT_USER, against 127.0.0.1:$PG_PORT)"
    sudo -u "$TENANT_USER" -H bash -lc "cd '$REPO' \
      && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
      && export DATABASE_URL='postgres://$PG_USER:$PW@127.0.0.1:$PG_PORT/$PG_DB' \
      && corepack pnpm --filter @fleet/db exec drizzle-kit migrate"
    log "verifying schema additions"
    psql_cp -c "\d+ artifact_versions" | grep -q "scan_summary" || die "scan_summary column missing after migrate"
    psql_cp -c "\d+ artifacts" | grep -q "description" || die "description column missing after migrate"
    log "restarting cp-api (loads registry routes)"
    podman restart cp-api >/dev/null
    sleep 2
    curl -sf http://127.0.0.1:8080/healthz >/dev/null && echo "cp-api healthz ok" || die "cp-api not healthy after restart"
    cat <<'NOTE'

DONE (control-plane side). STILL REQUIRED for the full feature, separately:
  1. Pod image rebuild so registry-publish lands on PATH AND the entrypoint
     registry-task executor ships:
        bash runtime/install/m2.1-build-image.sh
        systemctl restart claude-pod@vitaliy     # ⚠️ restarts the bot session
  2. Mini App frontend deploy (📦 Marketplace screen):
        (cd control-plane/apps/miniapp && pnpm build)
        cp -a control-plane/apps/miniapp/dist/. /var/www/miniapp/dist/
  3. Acceptance:
        node runtime/install/m8.1-accept.mjs              # PHASE A (safe)
        DO_PUBLISH=1 node runtime/install/m8.1-accept.mjs # PHASE B (REAL PR on the public repo)
NOTE
    ;;
  rollback)
    log "dropping 0003 schema additions"
    psql_cp <<'SQL'
ALTER TABLE artifact_versions DROP COLUMN IF EXISTS status;
ALTER TABLE artifact_versions DROP COLUMN IF EXISTS scan_summary;
ALTER TABLE artifacts DROP COLUMN IF EXISTS description;
DROP INDEX IF EXISTS artifacts_owner_type_name_key;
DROP TYPE IF EXISTS artifact_status;
SQL
    echo "NOTE: drizzle's journal still lists 0003 — restore the prior schema.ts"
    echo "and delete drizzle/0003_*.sql if you intend to re-generate."
    log "restarting cp-api"
    podman restart cp-api >/dev/null
    ;;
  *)
    die "usage: $0 [apply|rollback]"
    ;;
esac
