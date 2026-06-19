#!/usr/bin/env bash
# M4.1 (WP3) — bring up the Judge Orchestrator (cp-judge) as a Podman container on
# host network, alongside cp-api / cp-audit-collector. Mirrors m1.5-services.sh.
#
#   - ensures bullmq is installed (pnpm install, run as the repo owner — needs a
#     writable HOME cache, which exists on the host but NOT inside a tenant pod)
#   - adds the judge_verdicts table (idempotent; enums already exist from m1.2)
#   - stores the OpenRouter judge key as a podman secret (never a file/argv); the
#     key is the $10/week-capped judge key — used ONLY on a cache-miss /judge call
#   - brings up cp-judge on 127.0.0.1:8090
#   - runs the HTTP acceptance with a throwaway JUDGE_STUB=pass instance on :8091
#     (ZERO LLM spend): same artifact twice → 2nd is cacheHit=true
#
# Run as root on the host. Idempotent. Teardown-tracked.
# Rollback: install/m4.1-rollback.sh
set -euo pipefail

# Repo root derived from this script's location: <root>/control-plane/install/<name>.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
OWNER="$(stat -c %U "$ROOT" 2>/dev/null)"; id "$OWNER" >/dev/null 2>&1 || OWNER=root   # root on greenfield, tenant on pilot; unresolvable uid → root
REPO="$ROOT/control-plane"
NODE_IMAGE=docker.io/library/node:22-alpine
PG_SECRET=cp_pg_password
OR_SECRET=cp_openrouter_key
JUDGE_PORT=8090
ACCEPT_PORT=8091

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# Run a command as the repo owner: directly when owner is root, else via sudo -u.
run_as_owner() {
  if [ "$OWNER" = "root" ]; then bash -lc "$1"; else sudo -u "$OWNER" -H bash -lc "$1"; fi
}

# ---- preflight -------------------------------------------------------------
command -v podman >/dev/null 2>&1 || die "podman not installed"
podman container exists cp-postgres || die "cp-postgres not found (run m1.2-stores.sh first)"
podman container exists cp-redis    || die "cp-redis not found (run m1.2-stores.sh first)"
podman secret inspect "$PG_SECRET" >/dev/null 2>&1 || die "$PG_SECRET secret missing (m1.2)"

# ---- 1) deps (bullmq) — install as the repo owner on the host ----------------
log "pnpm install (adds bullmq for @fleet/judge-orchestrator)"
run_as_owner "cd '$REPO' && corepack pnpm install" \
  || die "pnpm install failed — check $OWNER can reach the npm registry via the proxy"
# pnpm puts a package's deps in ITS OWN node_modules (symlinked to the store),
# NOT the workspace root — so check the app's node_modules, not $REPO's.
[ -e "$REPO/apps/judge-orchestrator/node_modules/bullmq" ] \
  || die "bullmq still not present after install (expected apps/judge-orchestrator/node_modules/bullmq)"

# ---- 2) smoke (logic proof, no stores/LLM) ----------------------------------
log "judge core smoke (dedup + breaker + fail-closed)"
run_as_owner "cd '$REPO' && node_modules/.bin/tsx apps/judge-orchestrator/src/smoke.ts" \
  || die "judge smoke failed"

# ---- 3) judge_verdicts table (idempotent; enums exist from m1.2) ------------
log "ensuring judge_verdicts table"
podman exec -i cp-postgres psql -U cplane -d control_plane -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS judge_verdicts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  artifact_hash text NOT NULL,
  kind scanner_kind NOT NULL,
  ruleset_version text NOT NULL,
  model_version text NOT NULL,
  verdict verdict_kind NOT NULL,
  severity text,
  report_ref text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS judge_verdicts_key
  ON judge_verdicts (artifact_hash, ruleset_version, model_version);
SQL
echo "  judge_verdicts ready"

# ---- 4) OpenRouter judge key as a podman secret -----------------------------
# Outbound LLM-judge key. NOTE (open decision): podman-secret here matches cp-api's
# bot/jwt handling; alternative is OneCLI vault + routing cp-judge egress via the
# proxy. If you skip this, cp-judge boots but real judge calls return verdict=error
# (fail-closed) until the key is set; the stub acceptance below still passes.
if ! podman secret inspect "$OR_SECRET" >/dev/null 2>&1; then
  printf 'Paste the OpenRouter judge key ($10/wk-capped) [Enter to skip]: ' >&2
  read -rs OR_KEY; echo >&2
  if [ -n "${OR_KEY:-}" ]; then
    printf '%s' "$OR_KEY" | podman secret create "$OR_SECRET" - >/dev/null
    unset OR_KEY
    echo "  stored $OR_SECRET"
  else
    echo "  skipped — cp-judge will fail-closed on real calls until $OR_SECRET is set"
  fi
else
  echo "  $OR_SECRET already exists"
fi

podman image exists "$NODE_IMAGE" || { log "pulling $NODE_IMAGE"; podman pull "$NODE_IMAGE" >/dev/null; }

SECRET_ARGS=""
podman secret inspect "$OR_SECRET" >/dev/null 2>&1 && SECRET_ARGS="--secret $OR_SECRET"

# ---- 5) acceptance: throwaway stub instance on :8091 (zero LLM spend) --------
# Remove BOTH the accept container AND any prior production cp-judge FIRST: a
# leftover cp-judge (--restart=unless-stopped) from an earlier run is a worker on
# the SAME shared BullMQ queue (cp-redis); if cp-postgres's password was rotated
# since (m1.2 wipes + regenerates each run), that stale worker grabs the accept
# job and fails with "password authentication failed" → flaky accept. Clearing it
# before enqueuing guarantees only the fresh accept worker consumes the job.
log "acceptance: ephemeral cp-judge-accept (JUDGE_STUB=pass) on :$ACCEPT_PORT"
podman rm -f cp-judge-accept cp-judge >/dev/null 2>&1 || true
podman run -d --name cp-judge-accept --network host \
  --workdir "$REPO" -v "$REPO:$REPO:ro" -v cp-audit-run:/run/audit \
  --secret "$PG_SECRET" \
  "$NODE_IMAGE" \
  sh -c 'set -e; export HOST=127.0.0.1 PORT='"$ACCEPT_PORT"' REDIS_URL=redis://127.0.0.1:6380 AUDIT_SOCKET=/run/audit/collector.sock JUDGE_STUB=pass;
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/'"$PG_SECRET"')@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/judge-orchestrator/src/index.ts' >/dev/null
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$ACCEPT_PORT/healthz" >/dev/null 2>&1 && break; sleep 1; done
run_as_owner "cd '$REPO' && JUDGE_URL='http://127.0.0.1:$ACCEPT_PORT' node install/m4.1-accept.mjs" \
  || { podman logs --tail 30 cp-judge-accept; podman rm -f cp-judge-accept >/dev/null 2>&1; die "acceptance failed"; }
podman rm -f cp-judge-accept >/dev/null 2>&1 || true

# ---- 6) production cp-judge on :8090 ----------------------------------------
log "starting cp-judge (127.0.0.1:$JUDGE_PORT)"
podman rm -f cp-judge >/dev/null 2>&1 || true
# shellcheck disable=SC2086
podman run -d --name cp-judge --network host \
  --workdir "$REPO" -v "$REPO:$REPO:ro" -v cp-audit-run:/run/audit \
  --secret "$PG_SECRET" $SECRET_ARGS \
  --restart=unless-stopped \
  "$NODE_IMAGE" \
  sh -c 'set -e; export HOST=127.0.0.1 PORT='"$JUDGE_PORT"' REDIS_URL=redis://127.0.0.1:6380 AUDIT_SOCKET=/run/audit/collector.sock;
    [ -f /run/secrets/'"$OR_SECRET"' ] && export OPENROUTER_API_KEY_FILE=/run/secrets/'"$OR_SECRET"';
    export DATABASE_URL="postgres://cplane:$(cat /run/secrets/'"$PG_SECRET"')@127.0.0.1:5433/control_plane";
    exec node_modules/.bin/tsx apps/judge-orchestrator/src/index.ts' >/dev/null

systemctl enable podman-restart.service >/dev/null 2>&1 || true

log "waiting for cp-judge /healthz"
ok=""
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$JUDGE_PORT/healthz" >/dev/null 2>&1; then ok=1; echo "healthz OK"; break; fi
  [ "$(podman inspect -f '{{.State.Status}}' cp-judge 2>/dev/null)" = "running" ] || { podman logs --tail 30 cp-judge 2>&1; die "cp-judge not running"; }
  sleep 1
done
[ -n "$ok" ] || { podman logs --tail 40 cp-judge 2>&1; die "cp-judge did not answer /healthz"; }

log "status"
podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}  {{.Ports}}'
echo
echo "✅ M4.1 cp-judge up + acceptance passed (dedup/cache_hit). breaker proven by smoke."
