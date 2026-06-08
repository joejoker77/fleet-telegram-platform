#!/usr/bin/env bash
# M2.6 — deprovision a tenant (reverse of provision-tenant.sh). Idempotent.
# Run as root.  deprovision-tenant.sh <os_user> [--purge-user]
# Removes: pod + unit instance, OneCLI agent + token, control-plane DB rows.
# With --purge-user also userdel's the OS account + home. Never touches other
# tenants, the live bots, or shared infra (cl-net/nft/UFW stay — they're global).
set -uo pipefail
USER_NAME="${1:?usage: deprovision-tenant.sh <os_user> [--purge-user]}"
PURGE=false; [ "${2:-}" = "--purge-user" ] && PURGE=true
AGENT_IDENT="${USER_NAME}-bot"
TOKFILE="/etc/cl-egress/$USER_NAME.token"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
export HOME=/root
psql_cp() { podman exec -i cp-postgres psql -U cplane -d control_plane "$@"; }

echo "== stop + disable claude-pod@$USER_NAME =="
systemctl disable --now "claude-pod@$USER_NAME" 2>/dev/null || true
podman rm -f "claude-$USER_NAME" 2>/dev/null || true

echo "== remove OneCLI agent $AGENT_IDENT + token =="
rm -f "$TOKFILE"
if command -v onecli >/dev/null 2>&1 && onecli auth status >/dev/null 2>&1; then
  AID="$(onecli agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='${AGENT_IDENT}'),''))" 2>/dev/null || true)"
  [ -n "$AID" ] && onecli agents delete --id "$AID" >/dev/null 2>&1 && echo "deleted agent $AID" || echo "(agent not found)"
fi

echo "== remove control-plane DB rows =="
if podman container exists cp-postgres; then
  psql_cp -c "delete from users where os_username='${USER_NAME}';" 2>&1 || true
  # containers/usage_records/etc cascade via FK ON DELETE CASCADE
fi

if [ "$PURGE" = true ] && id "$USER_NAME" >/dev/null 2>&1; then
  echo "== purging OS account $USER_NAME =="
  userdel -r "$USER_NAME" 2>/dev/null || userdel "$USER_NAME" 2>/dev/null || true
fi
echo "deprovision-tenant done"
