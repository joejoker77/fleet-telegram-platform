#!/usr/bin/env bash
# egress-probe.sh — answer the M3.0-smoke OPEN question in isolation:
#   "Does the official Telegram plugin's poller (bun server.ts) come up and reach
#    Telegram from inside the runtime container?"
#
# WHY this design (decided 2026-06-08 EOD, see M3-smoke-findings-2026-06-08.md):
#   - cl-net is NOT built yet (M2.3) → the runtime falls back to the DEFAULT bridge =
#     direct internet. So there is no locked egress to blame; this reproduces the
#     SAME network the failed smoke poller used.
#   - server.ts runs STANDALONE: it connects MCP over stdio, then fires a
#     fire-and-forget polling loop (bot.start) that logs "polling as @<bot>" on
#     success or the exact error (incl. 409) on failure. So we do NOT need Claude,
#     a Claude login, or any copied OAuth credentials — which is what dropped the
#     live bot's login last time ([[feedback_no_shared_oauth_across_claude_instances]]).
#   - ZERO impact on the live vitaliy bot: different token (@my_wordzilla_remply_bot,
#     so no 409 against @vitaliy_claude_bot), throwaway --rm container, no tenant user,
#     no claude, temp token file purged on exit.
#
# Run as root:  egress-probe.sh <test_bot_token>
set -euo pipefail

TOKEN="${1:?usage: egress-probe.sh <test_bot_token>}"
IMG=claude-user:latest
RT=/home/vitaliy/work/fleet-platform/runtime
PLUGDIR=/home/vitaliy/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6
DIAG=/home/vitaliy/work/egress-probe-diag.txt
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -f "$PLUGDIR/server.ts" ] || { echo "plugin server.ts not found at $PLUGDIR"; exit 1; }

# Temp state dir holds the token .env (mode 600) + bot.pid/logs the poller writes.
# Purged on exit so the token never lingers on disk.
STATE="$(mktemp -d /tmp/egress-probe.XXXXXX)"
cleanup() { podman rm -f egress-probe >/dev/null 2>&1 || true; rm -rf "$STATE"; }
trap cleanup EXIT
mkdir -p "$STATE/logs"
umask 077
# The plugin reads the token from $TELEGRAM_STATE_DIR/.env (server.ts line 30) —
# faithful to the real poller path. $TOKEN is a shell var; never echoed.
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$STATE/.env"
chmod 600 "$STATE/.env"

: > "$DIAG"
log() { printf '\n== %s ==\n' "$*" | tee -a "$DIAG"; }

log "0) context"
{
  echo -n "  cl-net network: "; podman network exists cl-net 2>/dev/null && echo "EXISTS (locked egress)" || echo "ABSENT → default bridge = direct internet (matches the failed smoke)"
  echo -n "  runtime image $IMG: "; podman image exists "$IMG" 2>/dev/null && echo "present" || echo "MISSING — will rebuild"
} | tee -a "$DIAG"

if ! podman image exists "$IMG" 2>/dev/null; then
  log "0b) rebuild runtime image (pure sandbox, no live impact)"
  bash "$RT/install/m2.1-build-image.sh" | tail -3 | tee -a "$DIAG"
fi

log "1) run the plugin poller (bun server.ts) STANDALONE for ~15s — no claude, no login"
# stdin via a fifo whose write end we hold open, so MCP StdioServerTransport
# doesn't see EOF and exit; the polling loop runs independently regardless.
# IMPORTANT: the runtime image sets ENTRYPOINT=/opt/platform/entrypoint.sh (the full
# Claude launcher, which ignores any passed command). We MUST override it with
# --entrypoint so our `sh -c` actually runs the poller standalone — otherwise the
# container launches Claude (no login → hangs) and server.ts never runs.
podman run -d --name egress-probe --rm \
  --network podman \
  --entrypoint /bin/sh \
  -e HOME=/root -e TELEGRAM_STATE_DIR=/state \
  -v "$PLUGDIR:/srv:ro" -v "$STATE:/state" \
  "$IMG" \
  -c 'cd /state; mkfifo .kp 2>/dev/null || true; sleep 30 > .kp & exec bun /srv/server.ts < .kp > /state/server.out 2>&1' \
  >/dev/null
echo "  container started; waiting 15s for poll result..." | tee -a "$DIAG"
sleep 15

log "2) result"
{
  echo -n "  bot.pid written?     "; [ -f "$STATE/bot.pid" ] && echo "yes ($(cat "$STATE/bot.pid"))" || echo "NO"
  echo -n "  polling confirmed?   "; grep -qi 'polling as @' "$STATE/server.out" 2>/dev/null && echo "YES — $(grep -i 'polling as @' "$STATE/server.out" | tail -1)" || echo "NO"
  echo -n "  409 conflict?        "; grep -qi '409' "$STATE/server.out" 2>/dev/null && echo "YES" || echo "none"
  echo    "  --- full server.ts stdout/stderr ---"
  sed 's/^/      /' "$STATE/server.out" 2>/dev/null || echo "      (no output captured)"
  echo    "  --- plugin_stderr.log ---"
  sed 's/^/      /' "$STATE/logs/plugin_stderr.log" 2>/dev/null || echo "      (none)"
} | tee -a "$DIAG"

log "3) plain egress reachability (no token) — sanity that api.telegram.org is routable"
# --entrypoint /bin/sh (see step 1) + an outer timeout so a stuck container can never
# wedge the terminal again, even if curl/--max-time misbehaves.
timeout 20 podman run --rm --network podman --entrypoint /bin/sh "$IMG" \
  -c 'curl -s -o /dev/null -w "api.telegram.org http=%{http_code} time=%{time_total}s\n" --max-time 8 https://api.telegram.org 2>&1 || echo "curl failed (no route?)"' \
  2>&1 | sed 's/^/  /' | tee -a "$DIAG" || echo "  (step 3 timed out / container error)" | tee -a "$DIAG"

chown vitaliy:vitaliy "$DIAG" 2>/dev/null || true
echo
echo "Done. Full result in $DIAG (the vitaliy bot reads it directly). Token file purged."
if grep -qi 'polling as @' "$DIAG" 2>/dev/null; then
  echo "✅ Poller reaches Telegram standalone → the network/poller path is GOOD; the smoke gap is in how CLAUDE spawns the plugin (next: separate-account full test)."
else
  echo "❌ Poller did NOT confirm polling even standalone → see server.ts output above for the exact error (DNS/timeout/409/token)."
fi
