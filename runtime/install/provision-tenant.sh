#!/usr/bin/env bash
# M2.6 — provision one tenant end-to-end (consolidates M2.1–M2.5). Idempotent.
# Run as root. Does NOT touch the live claude-tg@* bots.
#
#   provision-tenant.sh <os_user> <telegram_id> [--admin]
#
# Steps: OS account + .claude/work scaffold -> control-plane DB rows
# (users, containers) -> OneCLI agent <user>-bot (selective) + scoped token ->
# install wrapper+unit -> enable claude-pod@<user> (joins cl-net, egress locked,
# OneCLI CA trusted, metering Stop hook). Network lockdown (cl-net/nftables/UFW)
# is global and assumed already provisioned by m2.3-egress.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"

USER_NAME="${1:?usage: provision-tenant.sh <os_user> <telegram_id> [--admin]}"
TG_ID="${2:?telegram_id required}"
ADMIN=false; [ "${3:-}" = "--admin" ] && ADMIN=true
AGENT_IDENT="${USER_NAME}-bot"
RT="$ROOT/runtime"
TOKDIR=/etc/cl-egress
TOKFILE="$TOKDIR/$USER_NAME.token"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
psql_cp() { podman exec -i cp-postgres psql -U cplane -d control_plane -v ON_ERROR_STOP=1 "$@"; }

[ "$(id -u)" -eq 0 ] || die "run as root"
podman image exists localhost/claude-user:latest || die "image missing (M2.1)"
podman network exists cl-net || die "cl-net missing (run m2.3-egress.sh first)"
podman container exists cp-postgres || die "cp-postgres missing (M1.2)"
export HOME=/root
command -v onecli >/dev/null 2>&1 && onecli auth status >/dev/null 2>&1 || die "onecli not authenticated"

# 1) OS account + scaffold
log "OS account + .claude/work scaffold for $USER_NAME"
id "$USER_NAME" >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin "$USER_NAME"
install -d -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.claude" "/home/$USER_NAME/work"

# Seed ~/.claude.json (onboarding + trust state). Without it Claude Code treats
# the pod run as first-run and stops at the trust/onboarding prompt → the
# non-interactive pane hangs/exits → no session → supervisor restart-loop. The
# entrypoint's trust_workdir also patches this, but seeding here means the very
# first pod start is clean. Tenant-owned; trusts the tenant's ~/work.
CJSON="/home/$USER_NAME/.claude.json"
if [ ! -f "$CJSON" ]; then
  cat > "$CJSON" <<JSON
{
  "hasCompletedOnboarding": true,
  "trustDialogAccepted": true,
  "projects": {
    "/home/$USER_NAME/work": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true,
      "allowedTools": [],
      "mcpServers": {},
      "mcpContextUris": []
    }
  }
}
JSON
  chown "$USER_NAME:$USER_NAME" "$CJSON"; chmod 600 "$CJSON"
fi

# 1b) dormant iCloud scaffold (docs/12) — every tenant gets the mount point so the
# capability is "available to all" by default. It stays empty/inert until the USER
# authenticates via their own bot skill (creds -> host auth-helper -> OneCLI -> mount);
# claude-pod-run :rslave-propagates ~/icloud into the pod once it's actually mounted.
# 0700 tenant-owned matches the rclone mount unit's ExecStartPre expectations.
install -d -o "$USER_NAME" -g "$USER_NAME" -m 0700 "/home/$USER_NAME/icloud"

# 2) control-plane DB: users + containers
log "registering tenant in control-plane DB"
psql_cp <<SQL
insert into users (telegram_user_id, os_username, status, is_admin)
values (${TG_ID}, '${USER_NAME}', 'active', ${ADMIN})
on conflict (telegram_user_id) do update set os_username = excluded.os_username, status = 'active';
SQL
UID_CP="$(psql_cp -tAc "select id from users where os_username='${USER_NAME}';")"
[ -n "$UID_CP" ] || die "failed to resolve control-plane user id"
psql_cp <<SQL
insert into containers (user_id, state) values ('${UID_CP}', 'provisioned')
on conflict (user_id) do update set state = 'provisioned';
SQL
echo "control-plane user_id=$UID_CP"

# 3) OneCLI agent (selective) + scoped token
log "OneCLI agent $AGENT_IDENT (selective)"
mkdir -p "$TOKDIR"; chmod 0700 "$TOKDIR"
AID="$(onecli agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='${AGENT_IDENT}'),''))" 2>/dev/null || true)"
[ -z "$AID" ] && { onecli agents create --name "$USER_NAME" --identifier "$AGENT_IDENT" >/dev/null; AID="$(onecli agents list | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='${AGENT_IDENT}'),''))")"; }
[ -n "$AID" ] || die "could not create/find agent $AGENT_IDENT"
onecli agents set-secret-mode --id "$AID" --mode selective >/dev/null
TOKEN="$(onecli agents regenerate-token --id "$AID" | python3 -c "import json,sys;d=json.load(sys.stdin);a=d.get('data',d) if isinstance(d,dict) else d;print(a.get('accessToken',''))")"
[ -n "$TOKEN" ] || die "no token for $AID"
umask 077; printf '%s' "$TOKEN" > "$TOKFILE"; chmod 0600 "$TOKFILE"

# 4) install latest wrapper + unit, enable the pod
log "installing runtime unit + wrapper, enabling claude-pod@$USER_NAME"
install -m 0755 "$RT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
install -m 0644 "$RT/systemd/claude-pod@.service" /etc/systemd/system/claude-pod@.service
systemctl daemon-reload
systemctl enable --now "claude-pod@$USER_NAME" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do [ "$(podman inspect -f '{{.State.Running}}' claude-$USER_NAME 2>/dev/null)" = "true" ] && break; sleep 1; done

# 5) summary
log "provisioned tenant '$USER_NAME'"
echo "  control-plane user_id : $UID_CP   (tg=$TG_ID admin=$ADMIN)"
echo "  onecli agent          : $AGENT_IDENT ($AID, selective)"
echo "  container             : $(podman inspect -f '{{.State.Status}}' claude-$USER_NAME 2>/dev/null)"
echo "  egress                : cl-net (default-deny; only OneCLI proxy)"
podman ps --filter "name=claude-$USER_NAME" --format '  {{.Names}}  {{.Status}}'
echo "provision-tenant OK"
