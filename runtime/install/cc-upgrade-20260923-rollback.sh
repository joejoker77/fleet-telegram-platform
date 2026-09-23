#!/usr/bin/env bash
# One command back to the image that was live before cc-upgrade-20260923.sh.
# Restores :latest and the per-tenant pins, then rolls the fleet one pod at a time.
set -euo pipefail

IMAGE=localhost/claude-user
BACKUP_TAG="pre-cc2.1.280-20260923"
PIN_DIR=/etc/claudeapp/image-pin

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
podman image exists "$IMAGE:$BACKUP_TAG" \
  || { echo "no $BACKUP_TAG image — nothing to roll back to"; exit 1; }

podman tag "$IMAGE:$BACKUP_TAG" "$IMAGE:latest"
echo "latest -> $(podman image inspect -f '{{.Id}}' "$IMAGE:latest" | cut -c1-12)"

if [ -d "$PIN_DIR/.bak-20260923" ]; then
  for f in "$PIN_DIR/.bak-20260923"/*; do
    [ -f "$f" ] || continue
    cp -a "$f" "$PIN_DIR/$(basename "$f")"
    printf '  pin restored: %-22s %s\n' "$(basename "$f")" "$(cat "$f")"
  done
fi

echo
echo "rolling pods back onto it, one at a time"
for u in $(ls /etc/claude-role/ 2>/dev/null); do
  systemctl restart "claude-pod@$u.service"
  printf '  %s\n' "$u"
  sleep 20
done
echo "done — the fleet is back on $BACKUP_TAG"
