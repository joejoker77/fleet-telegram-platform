#!/usr/bin/env bash
# Bake the 2026-09-23 channel-startup fixes into the tenant image.
#
#   1. launch_claude/session-restore/notice-injection target "claude:0", not the
#      ambiguous "claude" — which tmux resolved to the rc listener's window on
#      roughly half the pods, so every channel self-heal respawned the wrong
#      session and fixed nothing.
#   2. wait_for_egress() holds claude until the proxy answers, because claude
#      decides once at startup whether it has channels and never reconsiders.
#   3. the self-heal escalates to ONE pod restart instead of giving up silently.
#
# Does NOT restart anything: rolling the fleet is a separate, staggered step, and
# a restart storm is what caused the incident in the first place.
# Rollback: channel-boot-hardening-rollback.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
CTX="$REPO/runtime/image"
EP="$CTX/platform/entrypoint.sh"
IMAGE=localhost/claude-user
BACKUP_TAG="pre-chanboot-20260923"
# Every tenant runs one of these two tags and they point at the same image, so
# both have to move or half the fleet silently keeps the old entrypoint.
LIVE_TAGS=(latest cc2.1.259)

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -f "$EP" ] || { echo "no entrypoint at $EP — wrong checkout?"; exit 1; }

# Markers: one per fix, so a half-applied checkout cannot pass as applied.
MARKERS=(
  'tmux respawn-window -k -t "${SESSION}:0"'
  'wait_for_egress'
  'restarting the whole pod (once)'
)
log "checking the repo entrypoint actually carries all three fixes"
for m in "${MARKERS[@]}"; do
  grep -qF -- "$m" "$EP" || { echo "MISSING in repo: $m"; exit 1; }
  echo "  ok: $m"
done
bash -n "$EP" || { echo "entrypoint does not parse"; exit 1; }

log "tagging the current image for rollback → $BACKUP_TAG"
if podman image exists "$IMAGE:$BACKUP_TAG"; then
  echo "  $BACKUP_TAG already exists — keeping the original (an earlier run made it)"
else
  podman tag "$IMAGE:latest" "$IMAGE:$BACKUP_TAG"
  echo "  $BACKUP_TAG -> $(podman image inspect -f '{{.Id}}' "$IMAGE:$BACKUP_TAG" | cut -c1-12)"
fi

log "building"
podman build -t "$IMAGE:chanboot-20260923" -f "$CTX/Containerfile" "$CTX"

log "verifying the markers INSIDE the built image, not just in the checkout"
for m in "${MARKERS[@]}"; do
  podman run --rm --entrypoint /bin/sh "$IMAGE:chanboot-20260923" \
    -c "grep -qF -- '$m' /opt/platform/entrypoint.sh" \
    || { echo "marker missing inside the image: $m"; exit 1; }
  echo "  ok: $m"
done

log "moving the live tags"
for t in "${LIVE_TAGS[@]}"; do
  podman tag "$IMAGE:chanboot-20260923" "$IMAGE:$t"
  echo "  $t -> $(podman image inspect -f '{{.Id}}' "$IMAGE:$t" | cut -c1-12)"
done

cat <<'NEXT'

Image is in place. Running pods still carry the OLD entrypoint until they are
restarted — do that one at a time, verifying each before taking the next:

  for u in $(ls /etc/claude-role/); do
    systemctl restart claude-pod@$u.service
    sleep 25
  done

NEXT
