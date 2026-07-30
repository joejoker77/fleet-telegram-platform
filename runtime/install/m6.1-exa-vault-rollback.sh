#!/usr/bin/env bash
# m6.1-exa-vault-rollback.sh — one-command rollback for m6.1-exa-vault.sh.
#   1. Restores the vitaliy-bot agent's secret bindings to the saved pre-state
#      (or, if no pre-state file, current bindings minus this secret).
#   2. Deletes the OneCLI secret vitaliy-exa-api.
# After this, key-less exa calls from the pod lose auth on paid tools; the bot
# restores the inline key in /home/vitaliy/work/.mcp.json (the operator pastes
# the key back to the bot, or re-runs m6.1-exa-vault.sh later).
# Run as root on the host.
set -euo pipefail

USER_NAME="${KV_USER:-vitaliy}"   # honor KV_USER (add-user/remove-user set it per tenant)
AGENT_IDENT="${USER_NAME}-bot"
SECRET_NAME="${USER_NAME}-exa-api"
PRESTATE=/etc/cl-egress/${USER_NAME}-exa-api.prestate
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

AID="$("$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='$AGENT_IDENT'),''))")"
[ -n "$AID" ] || die "agent $AGENT_IDENT not found"

SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$SECRET_NAME'),''))")"

log "restoring agent bindings"
if [ -f "$PRESTATE" ]; then
  KEEP="$(grep -v '^$' "$PRESTATE" | sort -u || true)"
  echo "using saved pre-state ($PRESTATE)"
else
  KEEP="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | py_ids | grep -v '^$' | grep -vx "${SID:-NONE}" | sort -u || true)"
  echo "no pre-state file; using current bindings minus $SECRET_NAME"
fi
if [ -n "$KEEP" ]; then
  # shellcheck disable=SC2086
  "$ONECLI" agents set-secrets --id "$AID" --secret-ids $(echo $KEEP | tr ' ' ',') >/dev/null \
    || "$ONECLI" agents set-secrets --id "$AID" --secret-ids $KEEP >/dev/null
else
  "$ONECLI" agents set-secrets --id "$AID" --secret-ids "" >/dev/null || true
fi

log "deleting secret $SECRET_NAME"
if [ -n "$SID" ]; then
  "$ONECLI" secrets delete --id "$SID" >/dev/null && echo "deleted ($SID)"
else
  echo "secret not found — nothing to delete"
fi
rm -f "$PRESTATE"

log "DONE — remind the bot to restore the inline exaApiKey in ~/work/.mcp.json (see header)"
