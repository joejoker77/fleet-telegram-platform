#!/usr/bin/env bash
# Does the graceful-restart watcher survive the systemd job that armed it?
#
# Arms a restart for one tenant with thresholds so large it can never fire, from
# inside a transient oneshot unit shaped exactly like fleet-restart-requests.service,
# then looks for the watcher once that unit has gone. Cancels either way, so the
# tenant is never restarted. Pass the unit a KillMode with -k to test the fix.
set -uo pipefail
U="${1:?usage: watcher-survival-proof.sh <tenant> [killmode]}"
KM="${2:-}"
BIN=/usr/local/sbin/graceful-restart-pod-bot
STATE=/run/graceful-restart-pod-bot/$U.state
UNIT="watcher-proof-$$"

"$BIN" "$U" cancel >/dev/null 2>&1 || true
rm -f "$STATE"

args=(--unit="$UNIT" --quiet --collect --property=Type=oneshot
      --setenv=IDLE_THRESHOLD_SEC=99999 --setenv=HARD_TIMEOUT_SEC=99999)
[ -n "$KM" ] && args+=(--property=KillMode="$KM")
echo "arming $U from a oneshot unit${KM:+ with KillMode=$KM}"
systemd-run "${args[@]}" "$BIN" "$U" || { echo "could not arm"; exit 1; }

# Wait for the transient unit to be gone, then look for the watcher.
for _ in $(seq 1 20); do
  systemctl is-active "$UNIT.service" >/dev/null 2>&1 || break
  sleep 0.5
done
sleep 2

pid=$(awk -F= '/^pid=/{print $2}' "$STATE" 2>/dev/null)
if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
  echo "RESULT: watcher ALIVE (pid=$pid) — the restart would really happen"
  rc=0
else
  echo "RESULT: watcher DEAD (state pid=${pid:-none}) — 'restart scheduled' is a lie"
  rc=1
fi
"$BIN" "$U" cancel >/dev/null 2>&1 || true
rm -f "$STATE"
echo "cancelled; $U was not restarted"
exit $rc
