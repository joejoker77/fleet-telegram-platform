#!/usr/bin/env bash
# M4.2 (WP4) — install + verify the L4/L5/L6 scanner gate (@fleet/scanners).
#   - pnpm install (links @fleet/scanners + @fleet/shared)
#   - scanners smoke (deterministic fail-fast / judge-routed / fail-closed) — offline
#   - integration acceptance against the LIVE cp-judge (real LLM): obvious malware →
#     blocked by deterministic stage; subtly-bad → blocked by judge; clean → pass
#
# Requires cp-judge up (run m4.1-judge-orchestrator.sh first). Run as root.
# Idempotent. The scanner package is a library + the
# `fleet-scan` CLI; binding it to install/authoring trigger points is the next
# step (operator picks the first surface — see the WP4 report).
set -euo pipefail

# Repo root derived from this script's location: <root>/control-plane/install/<name>.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
OWNER="$(stat -c %U "$ROOT")"   # root on greenfield, the tenant user on the pilot
REPO="$ROOT/control-plane"
NODE_IMAGE=docker.io/library/node:22-alpine
PG_SECRET=cp_pg_password

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# Run a command as the repo owner: directly when owner is root, else via sudo -u.
run_as_owner() {
  if [ "$OWNER" = "root" ]; then bash -lc "$1"; else sudo -u "$OWNER" -H bash -lc "$1"; fi
}

command -v podman >/dev/null 2>&1 || die "podman not installed"
curl -sf "http://127.0.0.1:8090/healthz" >/dev/null 2>&1 || die "cp-judge not answering on :8090 (run m4.1 first)"

# ---- 1) deps (links the new package) ----------------------------------------
log "pnpm install (links @fleet/scanners + @fleet/shared)"
run_as_owner "cd '$REPO' && corepack pnpm install" || die "pnpm install failed"
[ -e "$REPO/packages/scanners/node_modules/@fleet/shared" ] \
  || die "@fleet/shared not linked into packages/scanners after install"

# ---- 2) smoke (offline logic proof) -----------------------------------------
log "scanners smoke (deterministic / judge-routed / fail-closed)"
run_as_owner "cd '$REPO' && node_modules/.bin/tsx packages/scanners/src/smoke.ts" \
  || die "scanners smoke failed"

# ---- 3) integration acceptance vs LIVE cp-judge (real LLM) ------------------
log "integration acceptance (ephemeral container → cp-judge:8090, real LLM)"
podman rm -f cp-scan-accept >/dev/null 2>&1 || true
podman run --rm --name cp-scan-accept --network host \
  --workdir "$REPO" -v "$REPO:$REPO:ro" -v cp-audit-run:/run/audit \
  --secret "$PG_SECRET" \
  "$NODE_IMAGE" \
  sh -c 'set -e; export JUDGE_URL=http://127.0.0.1:8090 AUDIT_SOCKET=/run/audit/collector.sock;
    exec node_modules/.bin/tsx packages/scanners/src/accept.ts' \
  || die "scanner integration acceptance failed (see output above)"

echo
echo "✅ M4.2 scanners verified: deterministic fail-fast + judge-routed blocking + fail-closed."
echo "   Next: bind the gate (fleet-scan CLI) to the first install/authoring trigger."
