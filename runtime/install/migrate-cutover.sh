#!/usr/bin/env bash
# SEAMLESS CUTOVER of a live per-user bot onto the container runtime (generalized
# from the proven m3-cutover.sh). Parameterized by <user>.
#
#   sudo bash migrate-cutover.sh <os_user>            # real run
#   DRYRUN=1 sudo bash migrate-cutover.sh <os_user>   # pre-flight asserts only
#
# ⚠️ `systemctl stop claude-tg@<user>` kills the live Claude session of that bot.
# RUN FROM THE OPERATOR'S OWN TERMINAL — never from inside the target bot's own
# session (a guard below refuses if launched from within claude-tg@<user>).
#
# Flow: pre-flight asserts -> stop old host poller (releases token + the shared
# OAuth) -> start container pod (same ~/.claude, same token, single instance =>
# no rotation race, no 409) -> verify -> AUTO-ROLLBACK on any failure.
set -uo pipefail
U="${1:?usage: migrate-cutover.sh <os_user>}"
RT=/home/vitaliy/work/fleet-platform/runtime
SD="/home/$U/.claude/channels/telegram-$U"
DEFAULT_SD="/home/$U/.claude/channels/telegram"   # plugin fallback if TELEGRAM_STATE_DIR not seen
LOG="/home/$U/work/migrate-cutover-diag.txt"
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo bash migrate-cutover.sh <user>)"; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "no such OS user: $U"; exit 1; }

# --- self-destruction guard: never run from inside the target bot's service ---
if grep -qE 'claude-tg@'"$U"'(\b|\.)' /proc/self/cgroup 2>/dev/null; then
  echo "REFUSING: this is running inside claude-tg@$U (the target bot's own session)."
  echo "Run it from your own terminal, or: sudo systemd-run --pipe --wait --collect bash $RT/install/migrate-cutover.sh $U"
  exit 2
fi

say() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
: > "$LOG"; chown "$U:$U" "$LOG" 2>/dev/null || true

say "0) PRE-FLIGHT ASSERTS (read-only) for $U"
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "  ok   $1" | tee -a "$LOG"; else echo "  MISS $1" | tee -a "$LOG"; fail=1; fi; }
chk "runtime image"          "podman image exists localhost/claude-user:latest"
chk "cl-net network"         "podman network exists cl-net"
chk "OneCLI proxy token (/etc/cl-egress/$U.token)" "test -f /etc/cl-egress/$U.token"
chk "live token .env"        "test -f $SD/.env"
chk "workspace trusted"      "python3 -c \"import json,sys; d=json.load(open('/home/$U/.claude.json')); sys.exit(0 if d.get('projects',{}).get('/home/$U/work',{}).get('hasTrustDialogAccepted') else 1)\""
chk "control-plane tenant"   "podman exec -i cp-postgres psql -U cplane -d control_plane -tAc \"select 1 from users where os_username='$U'\" | grep -q 1"
chk "pod unit installed"     "test -f /etc/systemd/system/claude-pod@.service"
if [ "$fail" = 1 ]; then echo "  ✗ pre-flight FAILED — fix the MISS rows (run migrate-prep.sh $U <telegram_id>) before cutover." | tee -a "$LOG"; exit 1; fi
echo "  ✓ pre-flight all green" | tee -a "$LOG"
[ "${DRYRUN:-0}" = 1 ] && { echo "DRYRUN: stopping before any change."; exit 0; }

say "1) STOP old host poller (claude-tg@$U) — releases token; this ends the live session"
systemctl stop "claude-tg@$U" 2>&1 | tee -a "$LOG"
for _ in $(seq 1 20); do [ -f "$SD/bot.pid" ] && kill -0 "$(cat "$SD/bot.pid" 2>/dev/null)" 2>/dev/null && sleep 1 || break; done
echo "  old poller stopped (bot.pid: $(cat "$SD/bot.pid" 2>/dev/null || echo gone))" | tee -a "$LOG"

# Anchor the verify to lines written AFTER the pod starts (plugin_stderr.log is
# append-only + shared via the mounted ~/.claude; grepping the whole file
# false-matches stale residue). Record each candidate log's current size; VERIFY
# only inspects bytes beyond it.
declare -A LOGOFF
for d in "$SD" "$DEFAULT_SD"; do
  f="$d/logs/plugin_stderr.log"
  LOGOFF["$f"]=$( [ -f "$f" ] && wc -c < "$f" 2>/dev/null || echo 0 )
done
newlog(){ local f="$1"; [ -f "$f" ] || return 0; tail -c "+$(( ${LOGOFF[$1]:-0} + 1 ))" "$f" 2>/dev/null; }

say "2) START container pod (claude-pod@$U) — same creds/token, single instance"
podman rm -f "claude-$U" >/dev/null 2>&1 || true
systemctl start "claude-pod@$U" 2>&1 | tee -a "$LOG"

say "3) VERIFY (up to ~90s): container, session, bot.pid (both paths), polling, no 409"
ok=0
for i in $(seq 1 30); do
  run=$(podman inspect -f '{{.State.Running}}' "claude-$U" 2>/dev/null || echo no)
  pid=""; for d in "$SD" "$DEFAULT_SD"; do [ -f "$d/bot.pid" ] && pid="$d/bot.pid=$(cat "$d/bot.pid" 2>/dev/null)" && break; done
  poll=no; for d in "$SD" "$DEFAULT_SD"; do newlog "$d/logs/plugin_stderr.log" | grep -qi 'polling as @' && poll=yes && break; done
  c409=no; for d in "$SD" "$DEFAULT_SD"; do newlog "$d/logs/plugin_stderr.log" | grep -qiE '409:? *conflict|terminated by other getUpdates' && c409=yes; done
  printf '  t=%02ds run=%s botpid=%s polling=%s 409=%s\n' "$((i*3))" "$run" "${pid:-none}" "$poll" "$c409" | tee -a "$LOG"
  if [ "$run" = true ] && [ "$poll" = yes ] && [ "$c409" = no ]; then ok=1; break; fi
  sleep 3
done

# getMe sanity (token never printed)
TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$SD/.env" 2>/dev/null)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null || echo 000)"
echo "  getMe http=$code" | tee -a "$LOG"

if [ "$ok" = 1 ]; then
  say "✅ CUTOVER VERIFIED — container poller live, no 409. Send the bot a message to confirm round-trip."
  echo "  (hot rollback still available: sudo bash $RT/install/migrate-rollback.sh $U)" | tee -a "$LOG"
  exit 0
else
  say "❌ VERIFY FAILED — AUTO-ROLLBACK NOW"
  bash "$RT/install/migrate-rollback.sh" "$U" 2>&1 | tee -a "$LOG"
  echo "  cutover failed and was rolled back; see $LOG and the plugin logs." | tee -a "$LOG"
  exit 1
fi
