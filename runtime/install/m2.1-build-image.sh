#!/usr/bin/env bash
# M2.1 — build the user runtime image (claude-user:latest) with rootful podman.
# Run as root on the host (bot can't run podman / write system paths). Idempotent:
# rebuilds the tag. Network needed (apt/npm/bun/code-server downloads).
#
# DEV scaffolding: this and m2.1-rollback.sh are removed/consolidated into the
# productized install.sh at end of dev (see memory project_fleet_dev_teardown).
set -euo pipefail

IMAGE=claude-user:latest
CTX=/home/vitaliy/work/fleet-platform/runtime/image

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
command -v podman >/dev/null 2>&1 || { echo "podman not installed (run M1.2 first)"; exit 1; }
[ -f "$CTX/Containerfile" ] || { echo "Containerfile not found at $CTX"; exit 1; }

log "building $IMAGE"
podman build -t "$IMAGE" -f "$CTX/Containerfile" "$CTX"

log "verify toolchain inside the image"
podman run --rm "$IMAGE" sh -c 'echo -n "claude "; claude --version; echo -n "node "; node --version; echo -n "bun "; bun --version; echo -n "code-server "; code-server --version | head -1'

log "image"
podman images --filter reference="$IMAGE" --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
echo "M2.1 build OK"
