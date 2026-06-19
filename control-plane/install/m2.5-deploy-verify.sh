#!/usr/bin/env bash
# M2.5 — deploy the metering code (restart cp-* to pick it up) and verify the
# path: synthetic usage.turn -> audit-collector -> usage_records -> /usage.
# Run as root. Idempotent. Touches only the dev cp-* services (not the live bot).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
REPO="$ROOT/control-plane"
OWNER="$(stat -c %U "$ROOT" 2>/dev/null)"; id "$OWNER" >/dev/null 2>&1 || OWNER=root
log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
podman container exists cp-api || { echo "cp-api missing (run M1.5)"; exit 1; }

log "ensure deps (drizzle-orm added to audit-collector) + restart services"
if [ "$OWNER" = root ]; then
  COREPACK_ENABLE_DOWNLOAD_PROMPT=0 bash -lc "cd '$REPO' && corepack pnpm install --silent"
else
  sudo -u "$OWNER" -H bash -lc "cd '$REPO' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm install --silent"
fi
podman restart cp-audit-collector cp-api >/dev/null
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://127.0.0.1:8080/healthz >/dev/null || { echo "cp-api not healthy:"; podman logs --tail 20 cp-api; exit 1; }

ACTOR="${BOOTSTRAP_ADMIN_USER:-$OWNER}"
log "inject a synthetic usage.turn (actor=$ACTOR) via the audit socket"
podman exec -e ACTOR="$ACTOR" cp-api node "$REPO/install/inject-usage.mjs"
sleep 1

log "usage_records rows (newest)"
podman exec cp-postgres psql -U cplane -d control_plane -tAF'  ' -c \
  "select model, tokens, \"window\" from usage_records order by id desc limit 3;"

log "authed GET /usage ($ACTOR)"
podman exec -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token -e API=http://127.0.0.1:8080 -e TG_ID=2112420187 \
  cp-api node "$REPO/install/usage-check.mjs"

echo
echo "✅ M2.5: metering path works (usage.turn -> usage_records -> /usage)"
