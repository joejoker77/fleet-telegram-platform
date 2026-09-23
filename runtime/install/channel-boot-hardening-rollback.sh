#!/usr/bin/env bash
# One command back to the image that was live before channel-boot-hardening.sh.
# Moves the live tags back and rolls the fleet onto them, one pod at a time.
set -euo pipefail

IMAGE=localhost/claude-user
BACKUP_TAG="pre-chanboot-20260923"
LIVE_TAGS=(latest cc2.1.259)

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
podman image exists "$IMAGE:$BACKUP_TAG" \
  || { echo "no $BACKUP_TAG image — nothing to roll back to"; exit 1; }

for t in "${LIVE_TAGS[@]}"; do
  podman tag "$IMAGE:$BACKUP_TAG" "$IMAGE:$t"
  echo "$t -> $(podman image inspect -f '{{.Id}}' "$IMAGE:$t" | cut -c1-12)"
done

echo
echo "rolling pods back onto it, one at a time"
for u in $(ls /etc/claude-role/ 2>/dev/null); do
  systemctl restart "claude-pod@$u.service"
  printf '  %s\n' "$u"
  sleep 20
done
echo "done — the fleet is back on $BACKUP_TAG"
