#!/usr/bin/env bash
# m0-wd-rollback-tg-liveness-watchdog.sh — one-command revert of the apply script.
# Restores the most recent pre-apply image tag + unit, then restarts the pod.
# Operator-run from the HOST as root. Pass a specific backup dir as $1 to pin one;
# defaults to the 'latest' symlink the apply script maintains.
set -euo pipefail

U=vitaliy
IMAGE=claude-user:latest
UNIT_DST=/etc/systemd/system/claude-pod@.service
BKROOT="/home/$U/m0-wd-backups"
BK="${1:-$BKROOT/latest}"

log(){ printf '\n[m0-wd-rollback] %s\n' "$*"; }
die(){ printf '\n[m0-wd-rollback][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "run on the HOST, not inside a container"
[ -d "$BK" ] || die "backup dir not found: $BK (pass one explicitly: $0 $BKROOT/<TS>)"

log "rolling back from $BK"

# 1) image: retag the backed-up image back to :latest (if there was one)
IMG_BK="$(cat "$BK/image-backup-tag" 2>/dev/null || echo)"
if [ -n "$IMG_BK" ] && podman image exists "$IMG_BK"; then
  podman tag "$IMG_BK" "$IMAGE"
  echo "  restored image $IMAGE <- $IMG_BK"
else
  echo "  ⚠️  no usable backup image tag in $BK — leaving current $IMAGE as-is"
fi

# 2) unit: restore the backed-up unit file + daemon-reload
if [ -f "$BK/claude-pod@.service" ]; then
  install -m 0644 "$BK/claude-pod@.service" "$UNIT_DST"
  systemctl daemon-reload
  echo "  restored $UNIT_DST"
else
  echo "  ⚠️  no unit backup in $BK — leaving installed unit as-is"
fi

# 3) restart the pod onto the restored image/unit
log "restart claude-pod@$U"
systemctl reset-failed "claude-pod@$U" 2>/dev/null || true
systemctl restart "claude-pod@$U"
echo "  done. Verify: systemctl status claude-pod@$U --no-pager ; \\"
echo "                ls -l /home/$U/.claude/channels/telegram-$U/bot.pid"
