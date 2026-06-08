#!/usr/bin/env bash
# Rollback for M2.5 — remove the synthetic test usage rows and restart cp-*.
# (A full code revert is `git revert` of the M2.5 commit + this restart; the code
# is bind-mounted from the repo.) Run as root. Idempotent. DEV scaffolding.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "== removing synthetic test usage rows (model='claude-test-model') =="
podman exec cp-postgres psql -U cplane -d control_plane -c \
  "delete from usage_records where model='claude-test-model';" 2>&1 || true

echo "== restart cp-* (picks up whatever code is currently in the repo) =="
podman restart cp-audit-collector cp-api >/dev/null 2>&1 || true
echo "M2.5 rollback done (for a full code revert: git revert the M2.5 commit, then re-run restart)"
