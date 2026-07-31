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
  # Distinguish "no such agent" from "deletion failed": the old one-liner collapsed both into
  # "(agent not found)", which hid the fact that the shim had no agents/delete at all and every
  # offboarding was leaving the agent behind in the vault.
  if [ -z "$AID" ]; then
    echo "(no agent $AGENT_IDENT — nothing to delete)"
  elif onecli agents delete --id "$AID" >/dev/null 2>&1; then
    echo "deleted agent $AID"
  else
    echo "WARN: agent $AGENT_IDENT ($AID) could NOT be deleted — remove it manually, it still exists"
  fi
fi

echo "== remove the role marker =="
# provision-tenant.sh writes /etc/claude-role/<user>, and every matrix-driven loop treats that
# directory as the list of live tenants (onboard-integrations.sh, onboard-user-keys.sh,
# rebind-shared-secrets.sh). Leaving it behind creates a ghost tenant that those scripts then
# try to bind secrets for — observed after a failed onboarding.
rm -f "/etc/claude-role/$USER_NAME" && echo "removed /etc/claude-role/$USER_NAME"

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
