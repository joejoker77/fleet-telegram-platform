#!/usr/bin/env bash
# M4.4 acceptance — validate the auto-suspend DETECTOR safely: synthesize abuse
# signals into a throwaway log dir and run the monitor in alert-only mode with a
# stubbed alerter. Proves threshold logic WITHOUT touching the real log, sending
# real alerts, or pausing any pod. Run as root (the monitor is root-installed).
set -uo pipefail
u="${1:-vitaliy}"
TDIR="$(mktemp -d)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rc=0

# 1) at-threshold (3 RESTORED in window) → should fire (WOULD SUSPEND)
LOG="$TDIR/$u.log"
for _ in 1 2 3; do
  echo "$now settings-guard: RESTORED settings.json from golden (protected keys drifted: ['permissions'])" >> "$LOG"
done
AGENTSHIELD_LOG_DIR="$TDIR" WINDOW_MIN=60 THRESHOLD=3 ENFORCE=0 SECURITY_ALERTER=/bin/true \
  /usr/local/sbin/auto-suspend-monitor "$u" >/dev/null 2>&1 || true
if grep -q "WOULD SUSPEND" "$LOG"; then
  echo "✅ at-threshold (3≥3) → detector fired: $(grep 'WOULD SUSPEND' "$LOG" | tail -1 | sed 's/.*auto-suspend: //')"
else
  echo "❌ at-threshold did NOT fire"; rc=1
fi

# 2) sub-threshold (1 event) → must NOT fire
LOG2="$TDIR/${u}sub.log"
echo "$now settings-guard: RESTORED settings.json from golden (protected keys drifted: ['permissions'])" > "$LOG2"
AGENTSHIELD_LOG_DIR="$TDIR" WINDOW_MIN=60 THRESHOLD=3 ENFORCE=0 SECURITY_ALERTER=/bin/true \
  /usr/local/sbin/auto-suspend-monitor "${u}sub" >/dev/null 2>&1 || true
if grep -q "WOULD SUSPEND" "$LOG2"; then echo "❌ sub-threshold (1<3) wrongly fired"; rc=1; else echo "✅ sub-threshold (1<3) correctly ignored"; fi

# 3) old events outside window → must NOT fire
LOG3="$TDIR/${u}old.log"
old="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '2000-01-01T00:00:00Z')"
for _ in 1 2 3; do echo "$old settings-guard: RESTORED ..." >> "$LOG3"; done
AGENTSHIELD_LOG_DIR="$TDIR" WINDOW_MIN=60 THRESHOLD=3 ENFORCE=0 SECURITY_ALERTER=/bin/true \
  /usr/local/sbin/auto-suspend-monitor "${u}old" >/dev/null 2>&1 || true
if grep -q "WOULD SUSPEND" "$LOG3"; then echo "❌ stale events (3h old) wrongly fired"; rc=1; else echo "✅ stale events (outside 60m window) correctly ignored"; fi

rm -rf "$TDIR"
echo
[ "$rc" -eq 0 ] && echo "✅ M4.4 detector acceptance PASS (no pods touched, no real alerts)" || echo "❌ M4.4 detector acceptance FAILED"
exit "$rc"
