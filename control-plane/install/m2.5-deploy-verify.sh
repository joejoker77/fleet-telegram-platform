#!/usr/bin/env bash
# M2.5 — deploy the metering code (restart cp-* to pick it up) and verify the
# path: synthetic usage.turn -> audit-collector -> usage_records -> /usage.
# Run as root. Idempotent. Touches only the dev cp-* services (not the live bot).
set -euo pipefail
REPO=/home/vitaliy/work/fleet-platform/control-plane
log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
podman container exists cp-api || { echo "cp-api missing (run M1.5)"; exit 1; }

log "ensure deps (drizzle-orm added to audit-collector) + restart services"
sudo -u vitaliy -H bash -lc "cd '$REPO' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm install --silent"
podman restart cp-audit-collector cp-api >/dev/null
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://127.0.0.1:8080/healthz >/dev/null || { echo "cp-api not healthy:"; podman logs --tail 20 cp-api; exit 1; }

log "inject a synthetic usage.turn (actor=vitaliy) via the audit socket"
podman exec -e ACTOR=vitaliy cp-api node "$REPO/install/inject-usage.mjs"
sleep 1

log "usage_records rows (newest)"
podman exec cp-postgres psql -U cplane -d control_plane -tAc \
  "select model||'  tokens='||tokens||'  win='||window from usage_records order by id desc limit 3;"

log "authed GET /usage (vitaliy)"
podman exec -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token -e API=http://127.0.0.1:8080 -e TG_ID=2112420187 \
  cp-api node "$REPO/install/usage-check.mjs"

echo
echo "✅ M2.5: metering path works (usage.turn -> usage_records -> /usage)"
