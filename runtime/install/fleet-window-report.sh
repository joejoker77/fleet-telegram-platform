#!/usr/bin/env bash
# fleet-window-report — what the context-window module has been doing for one tenant.
# Read-only, no LLM, run on demand on the firm host:
#
#   fleet-window-report <user> [since]      since: anything journalctl accepts, default "-6h"
#
# Shows: the tap's latest usage snapshot and how fresh it is; the window the governor has set;
# every window CHANGE the governor made, plus one "stays" line per hour so the usage trend is
# visible; and the auto-compactions that actually happened in the tenant's sessions — the only
# proof a window change reached Claude Code.
set -uo pipefail
U="${1:?usage: fleet-window-report <user> [since]}"
SINCE="${2:--6h}"
H="/home/$U"

echo "== usage snapshot (written by the tap inside Claude Code)"
if [ -f "$H/.claude/fleet-usage.json" ]; then
  python3 - "$H/.claude/fleet-usage.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); age = int(time.time() - d.get("ts", 0))
f = lambda w: "-" if not w else f"{w['utilization']*100:.0f}% (reset in {(w['resets_at']-time.time())/3600:.1f}h)"
print(f"  5h: {f(d.get('five_hour'))}   7d: {f(d.get('seven_day'))}   age: {age}s"
      + ("   <- stale, governor holds its decision" if age > 600 else ""))
PY
else
  echo "  none — the tap has not written yet (pod without the module, or no request since start)"
fi

echo "== window the governor has set: $(cat /var/lib/fleet/ctl/$U/window 2>/dev/null || echo '(no control file)')"

echo "== governor decisions since $SINCE (changes + one sample per hour)"
journalctl -u fleet-governor --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -F "$U:" | awk '
  / stays / { h = substr($1, 2, 13); if (h != last) { print "  " $0; last = h }; next }
  { print "  >>> " $0 }' | cut -c1-240

echo "== auto-compactions in $U's sessions since $SINCE"
since_epoch=$(date -d "$(echo "$SINCE" | sed -E 's/^-([0-9]+)h$/\1 hours ago/; s/^-([0-9]+)min$/\1 minutes ago/')" +%s 2>/dev/null || echo 0)
find "$H/.claude/projects" -name '*.jsonl' -newermt "@$since_epoch" 2>/dev/null | while read -r f; do
  grep -h '"compact_boundary"\|"isCompactSummary":true' "$f" 2>/dev/null | python3 -c '
import json, sys
for l in sys.stdin:
    try: d = json.loads(l)
    except Exception: continue
    m = d.get("compactMetadata") or {}
    if d.get("subtype") == "compact_boundary":
        print("  ", d.get("timestamp", "?")[:19], m.get("trigger", "?"), "pre_tokens=%s" % m.get("preTokens", "?"))'
done | sort | tail -20
