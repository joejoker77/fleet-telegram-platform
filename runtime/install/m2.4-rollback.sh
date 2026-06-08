#!/usr/bin/env bash
# Rollback for M2.4 — delete the cptest-bot OneCLI agent and remove its token.
# The pod falls back to the no-auth proxy path (M2.3 state). Run as root.
# Idempotent. Never touches other agents/secrets. DEV scaffolding (teardown).
set -uo pipefail
TEST_USER=cptest
AGENT_IDENT=cptest-bot
TOKFILE="/etc/cl-egress/$TEST_USER.token"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
export HOME=/root

echo "== removing tenant proxy token =="
rm -f "$TOKFILE" && echo "removed $TOKFILE" || true

echo "== deleting OneCLI agent $AGENT_IDENT =="
if command -v onecli >/dev/null 2>&1 && onecli auth status >/dev/null 2>&1; then
  AID="$(onecli agents list --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='$AGENT_IDENT'),''))" 2>/dev/null || true)"
  if [ -n "$AID" ]; then onecli agents delete --id "$AID" >/dev/null 2>&1 && echo "deleted agent $AID" || echo "(delete failed)"; else echo "(agent not found)"; fi
else
  echo "(onecli unavailable/unauthed — delete cptest-bot manually)"
fi

echo "== restart pod so it drops the token (back to M2.3 no-auth proxy) =="
systemctl restart "claude-pod@$TEST_USER" 2>/dev/null || true
echo "M2.4 rollback done"
