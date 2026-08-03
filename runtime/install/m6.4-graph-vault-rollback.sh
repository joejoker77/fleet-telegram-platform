#!/usr/bin/env bash
# m6.4-graph-vault-rollback.sh — remove the Microsoft Graph client credentials from the vault.
# Deleting the secret also drops every agent's grant on it, so no tenant can obtain a Graph
# token afterwards. The Azure app registration itself is untouched — revoke the secret in Azure
# too if the intent is to invalidate it there.
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root
SECRET_NAME=ms-graph-client
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in r if s.get('name')=='$SECRET_NAME'),''))")"

if [ -z "$SID" ]; then
  echo "  $SECRET_NAME is not in the vault — nothing to do"
else
  "$ONECLI" secrets delete --id "$SID" >/dev/null 2>&1 && echo "  deleted $SECRET_NAME ($SID)" \
    || { echo "  FAILED to delete $SECRET_NAME ($SID)"; exit 1; }
fi

echo "  verifying it is really gone:"
"$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print('   still present' if any(s.get('name')=='$SECRET_NAME' for s in r) else '   confirmed absent')"
echo
echo "== rollback DONE (the Azure app registration was not modified) =="
