#!/usr/bin/env bash
# Bake Claude Code 2.1.280 into the tenant image (was 2.1.259).
#
# The pods already self-update to this version at session start, so this changes
# what a pod runs BEFORE that update lands — which is the whole point now that
# the fleet is pinned to claude-opus-5-5: 2.1.259 refuses that model by name, so
# a pod that starts without egress can neither self-update nor run.
#
# Does NOT restart anything. Rollback: cc-upgrade-20260923-rollback.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
CTX="$REPO/runtime/image"
IMAGE=localhost/claude-user
VER=2.1.280
NEW_TAG="cc$VER"
BACKUP_TAG="pre-cc$VER-20260923"
PIN_DIR=/etc/claudeapp/image-pin

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

log "the checkout must already ask for $VER"
grep -q "^ARG CLAUDE_VERSION=$VER\$" "$CTX/Containerfile" \
  || { echo "Containerfile does not pin $VER — wrong checkout?"; exit 1; }
echo "  ok"

log "keep the current image for rollback → $BACKUP_TAG"
if podman image exists "$IMAGE:$BACKUP_TAG"; then
  echo "  $BACKUP_TAG already exists — keeping the original"
else
  podman tag "$IMAGE:latest" "$IMAGE:$BACKUP_TAG"
  echo "  $BACKUP_TAG -> $(podman image inspect -f '{{.Id}}' "$IMAGE:$BACKUP_TAG" | cut -c1-12)"
fi

log "building"
podman build -t "$IMAGE:$NEW_TAG" -f "$CTX/Containerfile" "$CTX"

log "the built image must actually carry $VER — ask the binary, not the tag"
got="$(podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" -c 'claude --version' | awk '{print $1}')"
[ "$got" = "$VER" ] || { echo "image reports '$got', expected $VER"; exit 1; }
echo "  claude --version -> $got"

log "and it must still know the model the fleet is pinned to"
podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" \
  -c 'claude --bare --strict-mcp-config --mcp-config "{\"mcpServers\":{}}" --model claude-opus-5-5 --print hi 2>&1 | head -2' \
  | grep -qi "isn't described by this version" \
  && { echo "  the image REFUSES claude-opus-5-5 — stopping before anything is moved"; exit 1; }
echo "  ok: no catalog rejection (an auth error here is expected and fine)"

log "moving :latest"
podman tag "$IMAGE:$NEW_TAG" "$IMAGE:latest"
echo "  latest -> $(podman image inspect -f '{{.Id}}' "$IMAGE:latest" | cut -c1-12)"

log "repointing the per-tenant pins that still name the old build"
# Leaving them on cc2.1.259 would quietly hold 14 tenants on the old image while
# the other 18 move — and the tag name would be a lie if we just retagged it.
if [ -d "$PIN_DIR" ]; then
  mkdir -p "$PIN_DIR/.bak-20260923"
  n=0
  for f in "$PIN_DIR"/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "cc2.1.259" ] || { printf '  %-22s %s (left alone)\n' "$(basename "$f")" "$(cat "$f")"; continue; }
    cp -a "$f" "$PIN_DIR/.bak-20260923/$(basename "$f")"
    printf '%s\n' "$NEW_TAG" > "$f"
    n=$((n+1))
  done
  echo "  repointed $n pin(s) to $NEW_TAG (originals in $PIN_DIR/.bak-20260923)"
fi

cat <<NEXT

Image is in place. Running pods keep their current container until restarted.
The overnight idle-gated restart is the separate, deliberate step:

  /usr/local/sbin/claude-restart-all-idle

NEXT
