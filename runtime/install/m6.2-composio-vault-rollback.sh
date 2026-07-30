#!/usr/bin/env bash
# m6.2-composio-vault-rollback.sh — one-command rollback for m6.2-composio-vault.sh.
#   1. Restores the vitaliy-bot agent's secret bindings to the saved pre-state
#      (or, if no pre-state file, current bindings minus these secrets).
#   2. Deletes the OneCLI secrets vitaliy-composio-api and vitaliy-composio-mcp.
# After this, key-less Composio calls from the pod get 401 again; the bot's
# composio MCP entry stops working until the key is re-staged.
# Run as root on the host.
set -euo pipefail

USER_NAME="${KV_USER:-vitaliy}"   # honor KV_USER (add-user/remove-user set it per tenant)
AGENT_IDENT="${USER_NAME}-bot"
SECRET_NAMES=("${USER_NAME}-composio-api" "${USER_NAME}-composio-mcp")
PRESTATE=/etc/cl-egress/${USER_NAME}-composio.prestate
ONECLI=/usr/local/bin/onecli

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
export HOME=/root
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated"

py_ids() { python3 -c '
import json,sys
d=json.load(sys.stdin); rows=d.get("data",d) if isinstance(d,dict) else d
print("\n".join(r if isinstance(r,str) else r.get("id","") for r in rows))'; }

secret_id_by_name() { "$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$1'),''))"; }

AID="$("$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='$AGENT_IDENT'),''))")"
[ -n "$AID" ] || die "agent $AGENT_IDENT not found"

SIDS=""
for name in "${SECRET_NAMES[@]}"; do
  SID="$(secret_id_by_name "$name")"
  [ -n "$SID" ] && SIDS="$SIDS $SID"
done

log "restoring agent bindings"
if [ -f "$PRESTATE" ]; then
  KEEP="$(grep -v '^$' "$PRESTATE" | sort -u || true)"
  echo "using saved pre-state ($PRESTATE)"
else
  KEEP="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | py_ids | grep -v '^$' | sort -u || true)"
  for sid in $SIDS; do KEEP="$(printf '%s\n' "$KEEP" | grep -vx "$sid" || true)"; done
  echo "no pre-state file; using current bindings minus composio secrets"
fi
if [ -n "$KEEP" ]; then
  # shellcheck disable=SC2086
  "$ONECLI" agents set-secrets --id "$AID" --secret-ids $(echo $KEEP | tr ' ' ',') >/dev/null \
    || "$ONECLI" agents set-secrets --id "$AID" --secret-ids $KEEP >/dev/null
else
  "$ONECLI" agents set-secrets --id "$AID" --secret-ids "" >/dev/null || true
fi

log "deleting secrets"
for name in "${SECRET_NAMES[@]}"; do
  SID="$(secret_id_by_name "$name")"
  if [ -n "$SID" ]; then
    "$ONECLI" secrets delete --id "$SID" >/dev/null && echo "deleted $name ($SID)"
  else
    echo "$name not found — nothing to delete"
  fi
done
rm -f "$PRESTATE"

log "DONE — composio in the pod is key-less-broken until the key is re-staged"
