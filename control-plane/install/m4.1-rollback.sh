#!/usr/bin/env bash
# M4.1 rollback — remove the Judge Orchestrator. One command, reversible.
# Leaves the judge_verdicts table in place (data, harmless; drop manually if you
# really want to). Does NOT touch cp-api / cp-audit-collector / the stores.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

OR_SECRET=cp_openrouter_key

echo "== removing cp-judge (+ any leftover accept instance) =="
podman rm -f cp-judge cp-judge-accept >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge-secret" ]; then
  podman secret rm "$OR_SECRET" >/dev/null 2>&1 && echo "removed secret $OR_SECRET" || true
fi

if [ "${1:-}" = "--drop-table" ] || [ "${2:-}" = "--drop-table" ]; then
  podman exec -i cp-postgres psql -U cplane -d control_plane -c 'DROP TABLE IF EXISTS judge_verdicts;' \
    && echo "dropped judge_verdicts"
fi

echo "✅ cp-judge removed. (secret/table kept unless --purge-secret / --drop-table given)"
