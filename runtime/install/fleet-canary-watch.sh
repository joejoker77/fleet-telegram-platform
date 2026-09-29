#!/usr/bin/env bash
# Guard a pilot restart: wait for <user>'s pod to restart (graceful-restart-pod-bot triggers
# it when the tenant is idle), then require the Telegram channel within CHANNEL_WAIT seconds.
# If it does not come up, take <user> out of every fleet-policy rollout, restart the pod, and
# say so loudly. Written after 2026-09-29, when a pilot restart left daria-rudenko's bot
# silent for 20 minutes while features were turned off by hand one per restart.
#
#   setsid nohup fleet-canary-watch.sh <user> >/var/log/fleet-canary-<user>.log 2>&1 &
set -uo pipefail
U="${1:?user}"
CHANNEL_WAIT="${CHANNEL_WAIT:-120}"
MAX_WAIT="${MAX_WAIT:-3900}"
POLICY=/etc/claudeapp/fleet-policy.json
ts() { date -u +%FT%TZ; }
since0="$(systemctl show -p ActiveEnterTimestampMonotonic --value "claude-pod@$U")"
echo "$(ts) watching $U (restart not seen yet)"
for ((i = 0; i < MAX_WAIT; i += 5)); do
  sleep 5
  [ "$(systemctl show -p ActiveEnterTimestampMonotonic --value "claude-pod@$U")" != "$since0" ] && break
done
[ "$i" -ge "$MAX_WAIT" ] && { echo "$(ts) no restart within ${MAX_WAIT}s — nothing to guard"; exit 0; }
echo "$(ts) pod restarted; waiting up to ${CHANNEL_WAIT}s for the Telegram channel"
for ((j = 0; j < CHANNEL_WAIT; j += 5)); do
  sleep 5
  if podman exec "claude-$U" ps -eo args 2>/dev/null | grep -q "bun server.ts"; then
    echo "$(ts) CHANNEL UP after ~$((j + 5))s — pilot restart OK"
    podman exec "claude-$U" sh -c 'tr "\0" "\n" < /proc/1/environ' | grep -E "BUN_OPTIONS|SUBAGENT_MODEL|^PATH=" || true
    exit 0
  fi
done
echo "$(ts) CHANNEL NOT UP after ${CHANNEL_WAIT}s — reverting $U out of every rollout"
U="$U" python3 - "$POLICY" <<'PY'
import json, os, sys
p = json.load(open(sys.argv[1])); u = os.environ["U"]
for k in ("subagent_model", "effort_cap", "context_window"):
    r = (p.get(k) or {}).get("rollout")
    if isinstance(r, list) and u in r:
        r.remove(u)
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
systemctl restart "claude-pod@$U"
echo "$(ts) REVERTED and restarted. Mirror $POLICY into git."
