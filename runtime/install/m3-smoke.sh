#!/usr/bin/env bash
# M3.0-smoke — prove the full bot-in-container on a THROWAWAY test bot token,
# WITHOUT touching the live vitaliy bot (different token, different container).
# Run as root:  m3-smoke.sh <test_bot_token>
#
# Rebuilds the image (new entrypoint), provisions tenant m3smoke with the test
# token, copies the telegram plugin cache + Claude OAuth from vitaliy (option A;
# 2nd first-party Claude Code on the same subscription), brings up the pod, and
# verifies the plugin actually polls the test bot (no 409) and Claude launched.
# Fully reversible: m3-smoke-rollback.sh (deprovision --purge-user).
set -euo pipefail

TOKEN="${1:?usage: m3-smoke.sh <test_bot_token>}"
U=m3smoke
TG_ID=8376649513            # @my_wordzilla_remply_bot
RT=/home/vitaliy/work/fleet-platform/runtime
SRC=/home/vitaliy/.claude
DST="/home/$U/.claude"
log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

log "1) rebuild runtime image (new entrypoint + metering hook)"
bash "$RT/install/m2.1-build-image.sh"

log "2) create test tenant OS account + dirs"
id "$U" >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin "$U"
install -d -o "$U" -g "$U" "$DST" "$DST/channels/telegram-$U" "$DST/channels/telegram-$U/logs" "/home/$U/work"

log "3) copy telegram plugin cache + Claude OAuth + top-level config from vitaliy"
cp -a "$SRC/plugins" "$DST/plugins"
cp -a "$SRC/.credentials.json" "$DST/.credentials.json"
# ~/.claude.json (onboarding/trust state) lives in HOME, not under ~/.claude;
# without it Claude does first-run onboarding and exits in the pane.
cp -a /home/vitaliy/.claude.json "/home/$U/.claude.json"
chown -R "$U:$U" "$DST/plugins" "$DST/.credentials.json" "/home/$U/.claude.json"
chmod 600 "$DST/.credentials.json"

log "4) minimal tenant settings (model pin + metering hook; NOT vitaliy's host-path hooks)"
cat > "$DST/settings.json" <<'JSON'
{
  "model": "claude-opus-4-8",
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "node /opt/platform/hooks/metering-stop-hook.mjs" } ] } ]
  }
}
JSON
chown "$U:$U" "$DST/settings.json"

log "5) write the test bot .env (token + remote-control name)"
umask 077
cat > "$DST/channels/telegram-$U/.env" <<EOF
TELEGRAM_BOT_TOKEN=$TOKEN
REMOTE_CONTROL_NAME=$U-main
EOF
chown "$U:$U" "$DST/channels/telegram-$U/.env"; chmod 600 "$DST/channels/telegram-$U/.env"

log "6) provision the tenant (DB rows + OneCLI agent + token + unit + start pod)"
bash "$RT/install/provision-tenant.sh" "$U" "$TG_ID"

log "7) wait for the plugin to start polling"
SDIR="$DST/channels/telegram-$U"
ok=""
for _ in $(seq 1 40); do
  if grep -qiE 'polling|getUpdates|my_wordzilla|@.*bot' "$SDIR/logs/plugin_stderr.log" 2>/dev/null || [ -f "$SDIR/bot.pid" ]; then ok=1; break; fi
  sleep 2
done

log "8) verdict"
echo -n "  container running:     "; podman inspect -f '{{.State.Running}}' "claude-$U" 2>/dev/null || echo "?"
echo -n "  claude tmux session:   "; podman exec "claude-$U" tmux has-session -t claude 2>/dev/null && echo "alive" || echo "MISSING"
echo -n "  bot.pid present:       "; [ -f "$SDIR/bot.pid" ] && echo "yes ($(cat "$SDIR/bot.pid"))" || echo "no"
echo    "  plugin log tail:"; tail -n 8 "$SDIR/logs/plugin_stderr.log" 2>/dev/null | sed 's/^/      /' || echo "      (no log yet)"
echo -n "  409 conflict in log?   "; grep -qi '409' "$SDIR/logs/plugin_stderr.log" 2>/dev/null && echo "YES (BAD)" || echo "none"

echo
if [ -n "$ok" ] && ! grep -qi '409' "$SDIR/logs/plugin_stderr.log" 2>/dev/null; then
  echo "✅ M3.0-smoke: bot-in-container launched + polling the test bot, no 409."
  echo "   Optional round-trip: message @my_wordzilla_remply_bot and confirm a reply."
else
  echo "❌ M3.0-smoke: plugin not confirmed polling — see log tail above."
  echo "   claude pane log (launch errors):"; tail -n 30 "$SDIR/logs/claude-pane.log" 2>/dev/null | sed 's/^/      /' || echo "      (none)"
  echo "   container logs:"; podman logs --tail 25 "claude-$U" 2>&1 | sed 's/^/      /'
  exit 1
fi
