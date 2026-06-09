#!/usr/bin/env bash
# m0-wd-apply-tg-liveness-watchdog.sh
# Apply the Telegram-channel liveness-watchdog: rebuild the user image (so the
# extended entrypoint supervise loop is baked) + install the rate-limited unit +
# restart the vitaliy pod. Operator-run from the HOST as root.
#
# What this fixes: after a pod restart the Telegram channel sometimes fails to
# come up while `claude` itself is alive; the old supervisor watched only the tmux
# session, never noticed, so recovery needed a MANUAL `systemctl restart`. The new
# entrypoint also watches the plugin's bot.pid and exits → Restart=always when the
# channel can't come up / dies. StartLimit on the unit caps the restart rate.
#
# vitaliy PILOT ONLY. One-command rollback: m0-wd-rollback-tg-liveness-watchdog.sh
# DEV scaffolding — folds into install.sh at end of dev (project_fleet_dev_teardown).
set -euo pipefail

U=vitaliy
REPO=/home/vitaliy/work/fleet-platform
IMAGE=claude-user:latest
CTX="$REPO/runtime/image"
UNIT_SRC="$REPO/runtime/systemd/claude-pod@.service"
UNIT_DST=/etc/systemd/system/claude-pod@.service
MARKER='telegram channel did not come up within'   # unique string in the new entrypoint
TS="$(date -u +%Y%m%d-%H%M%S)"
BK="/home/$U/m0-wd-backups/$TS"
IMG_BK="claude-user:pre-m0wd-$TS"

log(){ printf '\n[m0-wd] %s\n' "$*"; }
die(){ printf '\n[m0-wd][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "this must run on the HOST, not inside a container"
command -v podman >/dev/null 2>&1 || die "podman not installed"
[ -f "$CTX/Containerfile" ] || die "Containerfile not found at $CTX"
[ -f "$UNIT_SRC" ]          || die "unit source not found at $UNIT_SRC"
grep -q "$MARKER" "$REPO/runtime/image/platform/entrypoint.sh" || die "entrypoint in repo is missing the watchdog (marker not found) — wrong checkout?"

log "1/6 backup -> $BK (current image tag + installed unit)"
mkdir -p "$BK"
if podman image exists "$IMAGE"; then
  podman tag "$IMAGE" "$IMG_BK"
  echo "$IMG_BK" > "$BK/image-backup-tag"
  echo "  tagged current image as $IMG_BK"
else
  echo "  (no existing $IMAGE to tag — first build)"
  echo "" > "$BK/image-backup-tag"
fi
if [ -f "$UNIT_DST" ]; then
  cp -a "$UNIT_DST" "$BK/claude-pod@.service"
  echo "  backed up $UNIT_DST"
else
  echo "  (no installed unit to back up)"
fi
ln -sfn "$BK" "/home/$U/m0-wd-backups/latest"

log "2/6 rebuild $IMAGE (apt/npm/bun layers are cached; only the platform COPY reruns)"
podman build -t "$IMAGE" -f "$CTX/Containerfile" "$CTX"

log "3/6 verify the watchdog is baked into the freshly built image"
podman run --rm --entrypoint /bin/sh "$IMAGE" -c "grep -q '$MARKER' /opt/platform/entrypoint.sh" \
  || die "rebuilt image does NOT contain the watchdog marker — aborting before restart"
echo "  ok: marker present in image /opt/platform/entrypoint.sh"

log "4/6 install rate-limited unit + daemon-reload"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl daemon-reload
echo "  installed $UNIT_DST; StartLimit: $(grep -E 'StartLimit' "$UNIT_DST" | tr '\n' ' ')"

log "5/6 restart claude-pod@$U (this kills the live bot session; it self-recovers)"
systemctl reset-failed "claude-pod@$U" 2>/dev/null || true
systemctl restart "claude-pod@$U"

log "6/6 verify the channel comes back up on its own (poll bot.pid, up to 180s)"
PIDF="/home/$U/.claude/channels/telegram-$U/bot.pid"
START_EPOCH="$(date +%s)"
ok=0
for i in $(seq 1 36); do   # 36 * 5s = 180s
  sleep 5
  [ -f "$PIDF" ] || continue
  # fresh pidfile (written after we kicked the restart) + live process inside the pod
  MT="$(stat -c %Y "$PIDF" 2>/dev/null || echo 0)"
  [ "$MT" -ge "$START_EPOCH" ] || continue
  P="$(cat "$PIDF" 2>/dev/null || echo)"
  if [ -n "$P" ] && podman exec "claude-$U" sh -c "kill -0 $P" 2>/dev/null; then
    ok=1; break
  fi
done
if [ "$ok" = 1 ]; then
  echo "  ✅ channel is polling again — fresh bot.pid=$(cat "$PIDF") alive in the pod"
  echo "  M0-wd apply OK. Rollback if ever needed:"
  echo "     bash $REPO/runtime/install/m0-wd-rollback-tg-liveness-watchdog.sh"
else
  echo "  ⚠️  channel not confirmed up within 180s. Check:"
  echo "     systemctl status claude-pod@$U --no-pager"
  echo "     podman logs claude-$U 2>&1 | tail -40"
  echo "     tail -20 /home/$U/.claude/channels/telegram-$U/logs/plugin_stderr.log"
  echo "  Rollback: bash $REPO/runtime/install/m0-wd-rollback-tg-liveness-watchdog.sh"
  exit 1
fi
