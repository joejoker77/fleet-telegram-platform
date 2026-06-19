#!/usr/bin/env bash
# m4.3-rollback-managed-settings.sh — one-command revert of M4 #3.
#
# Operator-run from the HOST as root. Restores the pre-apply state:
#   1. retag the saved :m4.3-prev image back to :latest (drops the baked managed
#      layer from the LIVE image — the repo source keeps it for a future re-apply)
#   2. restore the latest tenant settings.json backup (brings the security hooks +
#      deny rules back into the tenant layer)
#   3. restart claude-pod@<user> so the bot comes up on the prior image + settings
#
#   bash m4.3-rollback-managed-settings.sh [<os_user>]   # defaults to the pilot
#
# Security is never absent during rollback: the prior settings.json carries the
# security hooks/denies, so the moment the pod restarts on the prior image it is
# guarded by the tenant layer again (the same state as before M4 #3).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
U="${1:-vitaliy}"   # pilot default
REPO="$ROOT"
IMAGE=localhost/claude-user:latest
PREV=localhost/claude-user:m4.3-prev
CTR=claude-$U
SETTINGS="/home/$U/.claude/settings.json"
BKROOT="/home/$U/m4.3-backups"

log(){ printf '\n[m4.3-rollback] %s\n' "$*"; }
die(){ printf '\n[m4.3-rollback][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "this is running INSIDE a container — run on the HOST"

log "1/3 retag prior image -> :latest"
if podman image exists "$PREV"; then
  podman tag "$PREV" "$IMAGE" && echo "  $PREV -> $IMAGE (managed layer dropped from live image)"
else
  echo "  ⚠️ $PREV not found — image rollback skipped (only settings restored)."
  echo "     To fully drop the managed layer, rebuild from a Containerfile without the"
  echo "     /etc/claude-code COPY, or re-tag a known-good image manually."
fi

log "2/3 restore latest tenant settings.json backup"
LAST="$(ls -1dt "$BKROOT"/*/ 2>/dev/null | head -n1)"
[ -n "$LAST" ] || die "no backup found under $BKROOT — cannot restore settings.json"
[ -f "$LAST/settings.json" ] || die "backup at $LAST has no settings.json"
cp -a "$LAST/settings.json" "$SETTINGS"
echo "  restored $SETTINGS from $LAST"
command -v jq >/dev/null 2>&1 && { jq -e . "$SETTINGS" >/dev/null || die "restored settings.json is not valid JSON"; echo "  restored file is valid JSON"; }

log "3/3 restart claude-pod@$U"
systemctl restart "claude-pod@$U"
echo "  restart issued"
ok=""
for i in $(seq 1 30); do
  sleep 2
  systemctl is-active --quiet "claude-pod@$U" && podman container exists "$CTR" && { ok=1; break; }
done
[ -n "$ok" ] || die "pod did not come back up within 60s — check: systemctl status claude-pod@$U"
echo "  ✅ claude-pod@$U back up on the prior image + restored settings.json"
echo
echo "[m4.3-rollback] DONE — reverted to the pre-M4.3 state."
