#!/usr/bin/env bash
# M3.2 — ONE-COMMAND ROLLBACK for the live vitaliy cutover.
#
#   sudo bash m3-rollback.sh
#
# Reverses M3.3: releases the Telegram token from the container and hands it
# back to the original host launcher. Operator-held — run this if the bot goes
# silent after cutover. Idempotent and safe to run even if already rolled back.
#
# Ordering is the whole point: the container is stopped FIRST (releases the
# token + the shared ~/.claude OAuth) so that when claude-tg@vitaliy comes back
# there is only ONE Claude instance on the creds — no token rotation race
# (the failure mode that dropped the login on 2026-06-08).
set -uo pipefail
U=vitaliy
SD="/home/$U/.claude/channels/telegram-$U"
LOG=/home/$U/work/m3-rollback-diag.txt
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo bash m3-rollback.sh)"; exit 1; }

say() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
: > "$LOG"

say "1) stop the container poller (release token + OAuth)"
systemctl stop "claude-pod@$U" 2>&1 | tee -a "$LOG" || true
podman rm -f "claude-$U" >/dev/null 2>&1 || true
# wait until the container is really gone
for _ in $(seq 1 20); do
  [ "$(podman inspect -f '{{.State.Running}}' claude-$U 2>/dev/null)" = "true" ] || break
  sleep 1
done
echo "  container running now? $(podman inspect -f '{{.State.Running}}' claude-$U 2>/dev/null || echo no)" | tee -a "$LOG"

say "2) start the original host launcher (retakes the token)"
systemctl start "claude-tg@$U" 2>&1 | tee -a "$LOG"

say "3) verify the host bot is back (bot.pid + getMe)"
ok=no
for _ in $(seq 1 24); do
  if [ -f "$SD/bot.pid" ] && kill -0 "$(cat "$SD/bot.pid" 2>/dev/null)" 2>/dev/null; then ok=yes; break; fi
  sleep 2
done
echo "  host bot.pid alive? $ok ($(cat "$SD/bot.pid" 2>/dev/null || echo none))" | tee -a "$LOG"
# getMe sanity (token never printed)
if [ -f "$SD/.env" ]; then
  TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$SD/.env")"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null || echo 000)"
  echo "  getMe http=$code (200=token valid & reachable)" | tee -a "$LOG"
fi

say "ROLLBACK DONE"
echo "  claude-tg@$U: $(systemctl is-active claude-tg@$U)   claude-pod@$U: $(systemctl is-active claude-pod@$U)" | tee -a "$LOG"
chown "$U:$U" "$LOG" 2>/dev/null || true
[ "$ok" = yes ] && echo "  ✅ host bot restored — message the bot to confirm." || echo "  ⚠️ host bot.pid not confirmed yet — check $LOG and 'journalctl -u claude-tg@$U'."
