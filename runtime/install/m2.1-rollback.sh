#!/usr/bin/env bash
# Rollback for M2.1 — remove the user runtime image and reclaim build layers.
# Run as root. Safe to run anytime; idempotent. One-command revert.
#
# DEV scaffolding (remove at end of dev — see project_fleet_dev_teardown).
set -uo pipefail
IMAGE=claude-user:latest
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "== removing $IMAGE =="
podman rmi -f "$IMAGE" 2>/dev/null && echo "removed" || echo "(not present)"

echo "== pruning dangling build layers =="
podman image prune -f >/dev/null 2>&1 || true

echo "== remaining cp-/claude- images =="
podman images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'claude-user|<none>' || echo "(none)"
echo "M2.1 rollback done"
