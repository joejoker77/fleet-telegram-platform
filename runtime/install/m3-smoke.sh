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
IMG=claude-user:latest
DIAG=/home/vitaliy/work/m3-smoke-diag.txt   # full untruncated evidence; the vitaliy bot reads this directly
: > "$DIAG" 2>/dev/null || true
log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

log "1) rebuild runtime image (new entrypoint + metering hook)"
bash "$RT/install/m2.1-build-image.sh"

log "1b) assert rebuilt image carries the new entrypoint (catch a stale/cached image)"
if podman run --rm --entrypoint cat "$IMG" /opt/platform/entrypoint.sh 2>/dev/null | grep -q 'hasTrustDialogAccepted'; then
  echo "  image entrypoint: trust-injection present ✓" | tee -a "$DIAG"
else
  die "rebuilt image is STALE — its entrypoint lacks the trust-injection (build-cache issue)"
fi

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

log "7) wait for the plugin to start polling (with liveness timeline)"
SDIR="$DST/channels/telegram-$U"
ok=""
{
  echo "=== liveness timeline (container / claude-tmux-session / bot.pid) ==="
  for i in $(seq 1 40); do
    cr=$(podman inspect -f '{{.State.Running}}' "claude-$U" 2>/dev/null || echo "gone")
    if podman exec "claude-$U" tmux has-session -t claude 2>/dev/null; then ts=alive; else ts=MISSING; fi
    bp=$([ -f "$SDIR/bot.pid" ] && echo yes || echo no)
    printf '  t+%02ds  container=%s  session=%s  bot.pid=%s\n' "$((i*2))" "$cr" "$ts" "$bp"
    if grep -qiE 'polling|getUpdates|my_wordzilla|@.*bot' "$SDIR/logs/plugin_stderr.log" 2>/dev/null || [ -f "$SDIR/bot.pid" ]; then ok=1; break; fi
    sleep 2
  done
} | tee -a "$DIAG"

log "8) verdict"
{
  echo "=== verdict ==="
  echo -n "  container running:     "; podman inspect -f '{{.State.Running}}' "claude-$U" 2>/dev/null || echo "?"
  echo -n "  claude tmux session:   "; podman exec "claude-$U" tmux has-session -t claude 2>/dev/null && echo "alive" || echo "MISSING"
  echo -n "  bot.pid present:       "; [ -f "$SDIR/bot.pid" ] && echo "yes ($(cat "$SDIR/bot.pid"))" || echo "no"
  echo    "  plugin log tail:"; tail -n 8 "$SDIR/logs/plugin_stderr.log" 2>/dev/null | sed 's/^/      /' || echo "      (no log yet)"
  echo -n "  409 conflict in log?   "; grep -qi '409' "$SDIR/logs/plugin_stderr.log" 2>/dev/null && echo "YES (BAD)" || echo "none"

  echo
  echo "=== in-container ~/.claude.json trust state (did the entrypoint injection take?) ==="
  podman exec "claude-$U" python3 -c "import json;d=json.load(open('/home/$U/.claude.json'));p=d.get('projects',{});w='/home/$U/work';print('  trustDialogAccepted        :',d.get('trustDialogAccepted'));print('  hasCompletedOnboarding     :',d.get('hasCompletedOnboarding'));print('  proj[work].hasTrustDialog  :',p.get(w,{}).get('hasTrustDialogAccepted'));print('  proj[work].projOnboarding  :',p.get(w,{}).get('hasCompletedProjectOnboarding'));print('  project keys               :',list(p.keys()))" 2>&1 | sed 's/^/  /' || echo "  (container gone — see host copy)"
  echo "  host-copy project keys:"; python3 -c "import json;d=json.load(open('/home/$U/.claude.json'));print(list(d.get('projects',{}).keys()))" 2>&1 | sed 's/^/    /'

  echo
  echo "=== FULL claude pane log (TUI / launch errors) ==="; cat "$SDIR/logs/claude-pane.log" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo
  echo "=== FULL container logs (entrypoint stdout/stderr) ==="; podman logs "claude-$U" 2>&1 | sed 's/^/  /' || echo "  (container gone)"
} | tee -a "$DIAG"

chown vitaliy:vitaliy "$DIAG" 2>/dev/null || true
echo
echo "FULL DIAGNOSTIC written to $DIAG — the vitaliy bot can read it directly (no truncation)."

if [ -n "$ok" ] && ! grep -qi '409' "$SDIR/logs/plugin_stderr.log" 2>/dev/null; then
  echo "✅ M3.0-smoke: bot-in-container launched + polling the test bot, no 409."
  echo "   Optional round-trip: message @my_wordzilla_remply_bot and confirm a reply."
else
  echo "❌ M3.0-smoke: plugin not confirmed polling — full timeline + logs in $DIAG"
  exit 1
fi
