#!/usr/bin/env bash
# M5.1 — deploy the authoring fs API: link @fleet/scanners, recreate cp-api with
# the tenant sandbox bind-mounted (so PUT /fs/file can write the tenant's
# ~/.claude as the tenant uid), restart, and run the fs acceptance.
#
# Boundary note (ADR-004): PUT /fs/file is BOUNDARY-1 (own sandbox) — it writes +
# audits + returns a non-blocking advisory, NO judge call. The blocking judge gate
# is at PUBLISH (M5.5). Pilot: vitaliy only. Run as root. Idempotent.
# Rollback: re-run m1.5-services.sh (recreates cp-api without the sandbox mount).
set -euo pipefail

REPO=/home/vitaliy/work/fleet-platform/control-plane
NODE_IMAGE=docker.io/library/node:22-alpine
PG_SECRET=cp_pg_password
BOT_SECRET=cp_bot_token
JWT_SECRET=cp_jwt_secret
API_PORT=8080
TENANT=vitaliy
SANDBOX="/home/${TENANT}/.claude"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d "$SANDBOX" ] || die "tenant sandbox $SANDBOX missing"

# 1) link @fleet/scanners into the api (new workspace dep)
log "pnpm install (links @fleet/scanners into @fleet/api)"
runuser -u "$TENANT" -- bash -lc "cd '$REPO' && corepack pnpm install" || die "pnpm install failed"
[ -e "$REPO/apps/api/node_modules/@fleet/scanners" ] || die "@fleet/scanners not linked into apps/api"

# 2) fs-safety smoke (path confinement) — offline, no infra
log "fs-safety smoke (path confinement)"
runuser -u "$TENANT" -- bash -lc "cd '$REPO' && node_modules/.bin/tsx apps/api/src/fs-safety.smoke.ts" || die "fs-safety smoke failed"

# 3) recreate cp-api WITH the tenant sandbox mount + TENANT_HOME_ROOT
log "recreating cp-api with sandbox mount ($SANDBOX)"
podman rm -f cp-api >/dev/null 2>&1 || true
podman run -d --name cp-api --network host \
  --workdir "$REPO" \
  -v "$REPO:$REPO:ro" \
  -v cp-audit-run:/run/audit \
  -v "/home/${TENANT}:/home/${TENANT}" \
  --secret "$PG_SECRET" --secret "$BOT_SECRET" --secret "$JWT_SECRET" \
  --restart=unless-stopped \
  "$NODE_IMAGE" \
  sh -c 'set -e; export HOST=127.0.0.1 PORT='"$API_PORT"' REDIS_URL=redis://127.0.0.1:6380 AUDIT_SOCKET=/run/audit/collector.sock TENANT_HOME_ROOT=/home;
    export TELEGRAM_BOT_TOKEN_FILE=/run/secrets/'"$BOT_SECRET"' JWT_SECRET_FILE=/run/secrets/'"$JWT_SECRET"';
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/'"$PG_SECRET"')@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/api/src/index.ts' >/dev/null

log "waiting for cp-api /healthz"
ok=""
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1 && { ok=1; echo "healthz OK"; break; }
  [ "$(podman inspect -f '{{.State.Status}}' cp-api 2>/dev/null)" = "running" ] || { podman logs --tail 30 cp-api 2>&1; die "cp-api not running"; }
  sleep 1
done
[ -n "$ok" ] || { podman logs --tail 40 cp-api 2>&1; die "cp-api did not answer /healthz"; }

# 4) fs acceptance (mint JWT → PUT/tree/GET/escape) in a throwaway container
log "fs acceptance (end-to-end via JWT)"
podman run --rm --network host \
  --workdir "$REPO" -v "$REPO:$REPO:ro" \
  --secret "$BOT_SECRET" \
  "$NODE_IMAGE" \
  sh -c 'export API=http://127.0.0.1:'"$API_PORT"' BOT_TOKEN_FILE=/run/secrets/'"$BOT_SECRET"' TG_ID=2112420187;
    exec node install/m5.1-fs-accept.mjs' \
  || { echo "acceptance FAILED"; die "m5.1 fs acceptance failed"; }

# 5) clean the acceptance test file
rm -f "${SANDBOX}/_authoring-selftest.md" 2>/dev/null || true

echo
echo "✅ M5.1 authoring fs API live on cp-api:${API_PORT} (GET /fs/tree, GET/PUT /fs/file)."
echo "   Boundary-1 save: writes own sandbox + audits + advisory, no judge. Next: sessions/build/ws, then M5.2 Mini App."
