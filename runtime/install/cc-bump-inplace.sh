#!/usr/bin/env bash
# Bump ONLY the Claude Code version in the existing tenant image.
#
#   cc-bump-inplace.sh 2.1.280
#   cc-bump-inplace.sh 2.1.284 --canary <tenant>   build cc2.1.284, pin ONE tenant to it
#                                                   (/etc/claudeapp/image-pin/<tenant>),
#                                                   leave :latest alone for everyone else
#
# Layers the new CLI on top of whatever :latest is today instead of rebuilding
# from the Containerfile. That matters on a host whose image is months old: a
# full rebuild would also pull in every unrelated change made to the build
# context since, which is a much bigger event than "update Claude". This changes
# one thing.
#
# Use the full build (cc-upgrade-*.sh) when the host's image is already current
# and you want the Containerfile to stay the source of truth.
#
# Does NOT restart anything. Rollback tag is printed at the end.
set -euo pipefail

VER="${1:-}"
[ -n "$VER" ] || { echo "usage: $0 <claude-code-version> [--canary <tenant>]   e.g. $0 2.1.280"; exit 1; }
CANARY=""
[ "${2:-}" = "--canary" ] && { CANARY="${3:?--canary needs a tenant}"; id "$CANARY" >/dev/null || exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

IMAGE=localhost/claude-user
NEW_TAG="cc$VER"
STAMP="$(date -u +%Y%m%d)"
BACKUP_TAG="pre-cc$VER-$STAMP"

log() { printf '\n== %s ==\n' "$*"; }

log "current image"
cur="$(podman run --rm --entrypoint /bin/sh "$IMAGE:latest" -c 'claude --version' | awk '{print $1}')"
echo "  :latest carries claude $cur"
[ "$cur" = "$VER" ] && { echo "  already $VER — nothing to do"; exit 0; }
# A canary builds from :latest but must not overwrite an existing cc<ver> tag.
if [ -n "$CANARY" ] && podman image exists "$IMAGE:$NEW_TAG"; then
  echo "  $IMAGE:$NEW_TAG already built — pinning $CANARY to it"
  mkdir -p /etc/claudeapp/image-pin; echo "$NEW_TAG" > "/etc/claudeapp/image-pin/$CANARY"
  echo "  pinned. Restart $CANARY's pod to use it. Rollback: rm /etc/claudeapp/image-pin/$CANARY"
  exit 0
fi

log "keep it for rollback → $BACKUP_TAG"
if podman image exists "$IMAGE:$BACKUP_TAG"; then
  echo "  $BACKUP_TAG already exists — keeping the original"
else
  podman tag "$IMAGE:latest" "$IMAGE:$BACKUP_TAG"
fi
echo "  $BACKUP_TAG -> $(podman image inspect -f '{{.Id}}' "$IMAGE:$BACKUP_TAG" | cut -c1-12)"

log "layering claude $VER onto it"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/Containerfile" <<EOF
FROM $IMAGE:$BACKUP_TAG
RUN npm install -g "@anthropic-ai/claude-code@$VER"
EOF
podman build -t "$IMAGE:$NEW_TAG" -f "$tmp/Containerfile" "$tmp"

log "the built image must actually carry $VER — ask the binary, not the tag"
got="$(podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" -c 'claude --version' | awk '{print $1}')"
[ "$got" = "$VER" ] || { echo "image reports '$got', expected $VER — not moving :latest"; exit 1; }
echo "  claude --version -> $got"

log "the entrypoint must have survived the layer"
for m in wait_for_egress 'tmux respawn-window'; do
  podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" -c "grep -qF -- '$m' /opt/platform/entrypoint.sh 2>/dev/null" \
    && echo "  ok: $m" || echo "  note: '$m' not present (fine if this host never had it)"
done

if [ -n "$CANARY" ]; then
  log "canary: pinning $CANARY to $NEW_TAG (:latest untouched)"
  mkdir -p /etc/claudeapp/image-pin
  echo "$NEW_TAG" > "/etc/claudeapp/image-pin/$CANARY"
  echo "  /etc/claudeapp/image-pin/$CANARY -> $NEW_TAG"
  echo
  echo "Restart $CANARY's pod to use it. Rollback: rm /etc/claudeapp/image-pin/$CANARY (then restart)."
  echo "Promote to everyone later: podman tag $IMAGE:$NEW_TAG $IMAGE:latest"
  exit 0
fi

log "moving :latest"
podman tag "$IMAGE:$NEW_TAG" "$IMAGE:latest"
echo "  latest -> $(podman image inspect -f '{{.Id}}' "$IMAGE:latest" | cut -c1-12)"

cat <<NEXT

Done. Running pods keep their current container until restarted.
Rollback:  podman tag $IMAGE:$BACKUP_TAG $IMAGE:latest   (then restart the pods)

NEXT
