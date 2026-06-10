#!/usr/bin/env bash
# M4.3 (WP7) — acceptance test for "the tenant cannot disable the platform
# deny-list/hooks" (ADR-003). Simulates a tenant tampering with its own
# settings.json deny-list and verifies the host-side agentshield-gate restores it
# from git HEAD within a window + (best-effort) that an alert was raised.
#
# SAFETY: the test removes ONE deny entry as the tenant, then waits for the gate.
# Whatever happens, it ALWAYS ensures the entry is present again before exiting
# (self-restores from HEAD if the gate didn't), so the bot is never left with a
# weakened deny-list. Read-only to everything else. Run as root on the host.
set -euo pipefail

USER_NAME="${1:-vitaliy}"
ENTRY='Bash(sudo *)'          # a deny entry that MUST survive tampering
WINDOW=30                     # seconds to wait for the gate to heal
D="/home/${USER_NAME}/.claude"
SETTINGS="${D}/settings.json"

log() { printf '%s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$SETTINGS" ] || { echo "no settings.json for ${USER_NAME}" >&2; exit 1; }

has_entry() {  # 1 = present, 0 = absent, in the given file
  python3 - "$1" "$ENTRY" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    deny = d.get("permissions", {}).get("deny", [])
    sys.exit(0 if sys.argv[2] in deny else 1)
except Exception:
    sys.exit(2)
PY
}

restore_from_head() {  # last-resort safety: put the file back to HEAD as the tenant
  runuser -u "$USER_NAME" -- env HOME="/home/${USER_NAME}" git -C "$D" restore settings.json 2>/dev/null || true
}

log "== M4.3 tamper test for ${USER_NAME} (entry: '${ENTRY}') =="

# 0) precondition: HEAD must carry the entry (else the gate can't restore it)
if ! runuser -u "$USER_NAME" -- env HOME="/home/${USER_NAME}" git -C "$D" show HEAD:settings.json 2>/dev/null \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "'"$ENTRY"'" in d.get("permissions",{}).get("deny",[]) else 1)'; then
  echo "PRECONDITION FAIL: '${ENTRY}' is not in HEAD:settings.json — commit it first (agentshield-rebaseline)"; exit 1
fi
has_entry "$SETTINGS" || { echo "PRECONDITION FAIL: live settings.json missing '${ENTRY}' before test"; exit 1; }
log "  precondition OK: '${ENTRY}' present in HEAD and live"

# 1) TAMPER as the tenant: drop the entry from the live settings.json
log "  tampering (removing '${ENTRY}') as ${USER_NAME}..."
runuser -u "$USER_NAME" -- env HOME="/home/${USER_NAME}" python3 - "$SETTINGS" "$ENTRY" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
deny = d.get("permissions", {}).get("deny", [])
d["permissions"]["deny"] = [x for x in deny if x != sys.argv[2]]
json.dump(d, open(p, "w"), indent=2)
PY
if has_entry "$SETTINGS"; then
  echo "  NOTE: entry still present right after tamper (gate may have already healed)"
else
  log "  tamper applied: entry removed from live file"
fi

# 2) wait for the gate to restore from HEAD
log "  waiting up to ${WINDOW}s for agentshield-gate to heal..."
healed=""
for i in $(seq 1 "$WINDOW"); do
  if has_entry "$SETTINGS"; then healed="$i"; break; fi
  sleep 1
done

# 3) best-effort: did the gate log/alert a restore?
ALERT="(alert log not found / not readable)"
for p in /var/log/agentshield/${USER_NAME}.log /var/log/agentshield.log; do
  [ -r "$p" ] && ALERT="$(tail -n 5 "$p" 2>/dev/null)"
done

# 4) SAFETY: ensure restored no matter what
if ! has_entry "$SETTINGS"; then
  log "  gate did NOT restore within ${WINDOW}s — self-restoring from HEAD (safety)"
  restore_from_head
fi

echo
if [ -n "$healed" ]; then
  echo "✅ PASS — agentshield-gate restored '${ENTRY}' from HEAD in ~${healed}s. Tenant cannot durably disable the deny-list (ADR-003 criterion #2)."
else
  echo "❌ FAIL — entry NOT restored within ${WINDOW}s (self-restored for safety). agentshield-gate@${USER_NAME} may be down / not watching ${D}. Investigate before relying on heal-from-HEAD."
fi
echo "--- agentshield alert tail ---"; echo "$ALERT"
has_entry "$SETTINGS" && echo "final state: '${ENTRY}' present ✓" || echo "final state: STILL MISSING ✗ (manual fix needed)"
