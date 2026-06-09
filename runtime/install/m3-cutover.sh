#!/usr/bin/env bash
# M3.3 — SEAMLESS CUTOVER of the live vitaliy bot onto the container runtime.
#
#   sudo bash m3-cutover.sh            # real run
#   DRYRUN=1 sudo bash m3-cutover.sh   # pre-flight asserts only, touches nothing
#
# ⚠️ The vitaliy bot IS the assistant. `systemctl stop claude-tg@vitaliy` kills
# the Claude session running it. THEREFORE THIS SCRIPT MUST BE RUN FROM THE
# OPERATOR'S OWN TERMINAL (or a detached systemd-run scope) — never from inside
# the bot's session, or it would kill its own driver mid-cutover. A guard below
# refuses to run if launched from within the claude-tg@vitaliy cgroup.
#
# Flow: pre-flight asserts -> stop old host poller (releases token + frees the
# shared OAuth) -> start container pod (same ~/.claude, same token, single
# instance => no rotation race, no 409) -> verify -> AUTO-ROLLBACK on any failure.
set -uo pipefail
U=vitaliy
RT=/home/vitaliy/work/fleet-platform/runtime
SD="/home/$U/.claude/channels/telegram-$U"
DEFAULT_SD="/home/$U/.claude/channels/telegram"   # plugin fallback if TELEGRAM_STATE_DIR not seen
LOG=/home/$U/work/m3-cutover-diag.txt
TOKFILE=/etc/cl-egress/$U.token
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo bash m3-cutover.sh)"; exit 1; }

# --- self-destruction guard: never run from inside the bot's own service ---
if grep -qE 'claude-tg@'"$U" /proc/self/cgroup 2>/dev/null; then
  echo "REFUSING: this is running inside claude-tg@$U (the bot's own session)."
  echo "Run it from your own terminal, or: sudo systemd-run --pipe --wait --collect bash $RT/install/m3-cutover.sh"
  exit 2
fi

say() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
: > "$LOG"; chown "$U:$U" "$LOG" 2>/dev/null || true

say "0) PRE-FLIGHT ASSERTS (read-only)"
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "  ok   $1" | tee -a "$LOG"; else echo "  MISS $1" | tee -a "$LOG"; fail=1; fi; }
chk "runtime image"          "podman image exists localhost/claude-user:latest"
chk "cl-net network"         "podman network exists cl-net"
chk "OneCLI proxy token ($TOKFILE)" "test -f $TOKFILE"
chk "live token .env"        "test -f $SD/.env"
chk "workspace trusted"      "python3 -c \"import json,sys; d=json.load(open('/home/$U/.claude.json')); sys.exit(0 if d.get('projects',{}).get('/home/$U/work',{}).get('hasTrustDialogAccepted') else 1)\""
chk "control-plane tenant"   "podman exec -i cp-postgres psql -U cplane -d control_plane -tAc \"select 1 from users where os_username='$U'\" | grep -q 1"
chk "pod unit installed"     "test -f /etc/systemd/system/claude-pod@.service"
if [ "$fail" = 1 ]; then echo "  ✗ pre-flight FAILED — fix the MISS rows (run m3-prep-vitaliy.sh) before cutover." | tee -a "$LOG"; exit 1; fi
echo "  ✓ pre-flight all green" | tee -a "$LOG"
[ "${DRYRUN:-0}" = 1 ] && { echo "DRYRUN: stopping before any change."; exit 0; }

say "1) STOP old host poller (claude-tg@$U) — releases token; this ends the live session"
systemctl stop "claude-tg@$U" 2>&1 | tee -a "$LOG"
for _ in $(seq 1 20); do [ -f "$SD/bot.pid" ] && kill -0 "$(cat "$SD/bot.pid" 2>/dev/null)" 2>/dev/null && sleep 1 || break; done
echo "  old poller stopped (bot.pid: $(cat "$SD/bot.pid" 2>/dev/null || echo gone))" | tee -a "$LOG"

say "2) START container pod (claude-pod@$U) — same creds/token, single instance"
podman rm -f "claude-$U" >/dev/null 2>&1 || true
systemctl start "claude-pod@$U" 2>&1 | tee -a "$LOG"

say "3) VERIFY (up to ~90s): container, session, bot.pid (both paths), polling, no 409"
ok=0
for i in $(seq 1 30); do
  run=$(podman inspect -f '{{.State.Running}}' "claude-$U" 2>/dev/null || echo no)
  pid=""; for d in "$SD" "$DEFAULT_SD"; do [ -f "$d/bot.pid" ] && pid="$d/bot.pid=$(cat "$d/bot.pid" 2>/dev/null)" && break; done
  poll=no; for d in "$SD" "$DEFAULT_SD"; do grep -qi 'polling as @' "$d/logs/plugin_stderr.log" 2>/dev/null && poll=yes && break; done
  c409=no; for d in "$SD" "$DEFAULT_SD"; do grep -qi '409' "$d/logs/plugin_stderr.log" 2>/dev/null && c409=yes; done
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
  echo "  (hot rollback still available: sudo bash $RT/install/m3-rollback.sh)" | tee -a "$LOG"
  exit 0
else
  say "❌ VERIFY FAILED — AUTO-ROLLBACK NOW"
  bash "$RT/install/m3-rollback.sh" 2>&1 | tee -a "$LOG"
  echo "  cutover failed and was rolled back; see $LOG and the plugin logs." | tee -a "$LOG"
  exit 1
fi
