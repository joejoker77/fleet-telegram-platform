#!/usr/bin/env bash
# m9.1-dbread-gateway.sh — stand up the read-only SQL gateway to the firm's Supabase
# Postgres, plus the per-tenant grant helper.
#
# WHY. Supabase secret keys cannot be made read-only (they bypass RLS), so the firm
# provisioned a real read-only PostgreSQL login instead (claude_readonly: no write grants,
# default_transaction_read_only=on, BYPASSRLS so it sees every row). That is a proper
# database-enforced control, but it is a libpq credential, not an HTTP key — and this
# platform's rule is that a tenant process NEVER holds a credential (the vault holds it and
# the egress proxy injects headers). A connection string cannot be injected that way, and a
# pod that holds a database password can leak it under prompt injection.
#
# So the password stays host-side in a podman secret, and tenants get an HTTP endpoint.
# Entitlement is decided by role-matrix.json — the same single source of truth as CLAUDE.md
# and the vault bindings — so this cannot drift from what tenants are told they may access.
#
# Usage:
#   sudo bash m9.1-dbread-gateway.sh                 # install / re-install the gateway
#   sudo bash m9.1-dbread-gateway.sh --grant <user>  # mint a token for one tenant
#   sudo bash m9.1-dbread-gateway.sh --revoke <user> # drop that tenant's token
# Rollback: m9.1-dbread-gateway-rollback.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RT="$REPO/runtime"
NODE_IMAGE="${NODE_IMAGE:-docker.io/library/node:22-alpine}"
GW_PORT=8092          # host loopback (gateway container, --network host)
POD_PORT=10256        # what tenant pods talk to, on the cl-net gateway IP
PW_SECRET=cp_dbread_password
STATE_DIR=/etc/claudeapp/dbread
TOKENS_FILE="$STATE_DIR/tokens.json"
MATRIX_SRC="$RT/install/role-matrix.json"
MATRIX_DST="$STATE_DIR/role-matrix.json"
FWD_UNIT=/etc/systemd/system/cl-dbread-forwarder.service

log(){ printf '\n== %s ==\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

install -d -m 0700 "$STATE_DIR"
[ -f "$TOKENS_FILE" ] || { printf '{}\n' > "$TOKENS_FILE"; chmod 600 "$TOKENS_FILE"; }

# ── per-tenant grant / revoke ────────────────────────────────────────────────
# The token is an IDENTITY assertion, not a database credential: it grants exactly what the
# tenant's role already grants, and the gateway re-checks the role on every request. Only its
# sha256 is stored host-side, so the map is not itself usable to authenticate.
grant_tenant(){
  local u="${1:?--grant needs a user}" tok digest
  id "$u" >/dev/null 2>&1 || die "no such user: $u"
  [ -f "/etc/claude-role/$u" ] || die "$u has no /etc/claude-role entry (not provisioned?)"
  tok="$(openssl rand -hex 32)"
  digest="$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)"
  TOKENS_FILE="$TOKENS_FILE" U="$u" DIGEST="$digest" python3 - <<'PY'
import json, os
p = os.environ["TOKENS_FILE"]
try: m = json.load(open(p))
except Exception: m = {}
# one live token per tenant: drop any previous digest for this user
m = {d: t for d, t in m.items() if t != os.environ["U"]}
m[os.environ["DIGEST"]] = os.environ["U"]
json.dump(m, open(p, "w"), indent=1)
PY
  chmod 600 "$TOKENS_FILE"
  # The token goes where the tenant's agent can read it and nowhere else.
  local dir="/home/$u/.claude"
  install -d -o "$u" -g "$u" -m 0700 "$dir"
  umask 077; printf '%s' "$tok" > "$dir/dbread.token"
  chown "$u:$u" "$dir/dbread.token"; chmod 600 "$dir/dbread.token"
  echo "  granted DB read access to $u (role=$(tr -d ' \t\r\n' < "/etc/claude-role/$u"))"
  echo "  token file: $dir/dbread.token (tenant-owned, 600)"
}

revoke_tenant(){
  local u="${1:?--revoke needs a user}"
  TOKENS_FILE="$TOKENS_FILE" U="$u" python3 - <<'PY'
import json, os
p = os.environ["TOKENS_FILE"]
try: m = json.load(open(p))
except Exception: m = {}
json.dump({d: t for d, t in m.items() if t != os.environ["U"]}, open(p, "w"), indent=1)
PY
  chmod 600 "$TOKENS_FILE"
  rm -f "/home/$u/.claude/dbread.token"
  echo "  revoked DB read access for $u"
}

case "${1:-}" in
  --grant)  grant_tenant "${2:-}"; exit 0 ;;
  --revoke) revoke_tenant "${2:-}"; exit 0 ;;
  "" ) ;;
  * ) die "unknown argument: $1 (use --grant <user> / --revoke <user>)" ;;
esac

# ── connection parameters (non-secret) ───────────────────────────────────────
# Baked in from the firm's read-only role. Overridable via env for a different project.
DBREAD_HOST="${DBREAD_HOST:-db.jdjxlczkggckdnpeluuw.supabase.co}"
DBREAD_PORT="${DBREAD_PORT:-5432}"
DBREAD_DB="${DBREAD_DB:-chatbot_v3_fork_prod}"
DBREAD_USER="${DBREAD_USER:-claude_readonly}"
# Supabase mandates TLS, so 'require' is the production default. Only a local test target
# (plain Postgres, no TLS) needs DBREAD_SSL=disable.
DBREAD_SSL="${DBREAD_SSL:-require}"

log "read-only DB gateway for $DBREAD_USER@$DBREAD_HOST/$DBREAD_DB"

# ── password → podman secret (never a file on disk, never in argv) ───────────
if podman secret inspect "$PW_SECRET" >/dev/null 2>&1; then
  echo "  podman secret $PW_SECRET already exists — keeping (delete it to re-enter)"
else
  if [ -n "${DBREAD_PASSWORD:-}" ]; then
    printf '%s' "$DBREAD_PASSWORD" | podman secret create "$PW_SECRET" - >/dev/null \
      || die "could not store the password as a podman secret"
    echo "  stored $PW_SECRET (from environment)"
  elif [ -t 0 ]; then
    # Interactive is the intended path: the person who owns the credential types it here and
    # it goes straight into the secret store — it never lands in a file or the shell history.
    printf 'Password for PostgreSQL role %s (input hidden): ' "$DBREAD_USER" >&2
    read -rs PW; echo >&2
    [ -n "$PW" ] || die "empty password"
    printf '%s' "$PW" | podman secret create "$PW_SECRET" - >/dev/null || die "secret create failed"
    unset PW
    echo "  stored $PW_SECRET"
  else
    die "no password: run interactively, or pass DBREAD_PASSWORD in the environment"
  fi
fi

# ── role matrix snapshot the gateway reads (entitlement source of truth) ─────
[ -f "$MATRIX_SRC" ] || die "role-matrix.json not found at $MATRIX_SRC"
install -m 0644 "$MATRIX_SRC" "$MATRIX_DST"
echo "  role matrix → $MATRIX_DST"

# ── dependencies + container ─────────────────────────────────────────────────
log "installing gateway dependencies (pnpm)"
( cd "$REPO/control-plane" && corepack pnpm install --silent >/dev/null 2>&1 ) \
  || echo "  WARN: pnpm install reported an issue — continuing (deps may already be present)"

podman image exists "$NODE_IMAGE" || { log "pulling $NODE_IMAGE"; podman pull "$NODE_IMAGE" >/dev/null; }

log "starting cp-dbread (127.0.0.1:$GW_PORT)"
podman rm -f cp-dbread >/dev/null 2>&1 || true
podman run -d --name cp-dbread --network host \
  --workdir "$REPO/control-plane" -v "$REPO:$REPO:ro" \
  -v "$STATE_DIR:$STATE_DIR:ro" -v /etc/claude-role:/etc/claude-role:ro \
  --secret "$PW_SECRET" \
  --restart=always \
  "$NODE_IMAGE" \
  sh -c 'set -e; export HOST=127.0.0.1 PORT='"$GW_PORT"';
    export DBREAD_HOST='"$DBREAD_HOST"' DBREAD_PORT='"$DBREAD_PORT"' DBREAD_DB='"$DBREAD_DB"' DBREAD_USER='"$DBREAD_USER"' DBREAD_SSL='"$DBREAD_SSL"';
    export DBREAD_PASSWORD_FILE=/run/secrets/'"$PW_SECRET"';
    export DBREAD_TOKENS_FILE='"$TOKENS_FILE"' ROLE_MATRIX_FILE='"$MATRIX_DST"';
    exec node_modules/.bin/tsx apps/dbread-gateway/src/index.ts' >/dev/null

log "waiting for cp-dbread /healthz"
ok=""
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$GW_PORT/healthz" >/dev/null 2>&1; then ok=1; echo "healthz OK"; break; fi
  [ "$(podman inspect -f '{{.State.Status}}' cp-dbread 2>/dev/null)" = "running" ] \
    || { podman logs --tail 30 cp-dbread 2>&1; die "cp-dbread is not running"; }
  sleep 1
done
[ -n "$ok" ] || { podman logs --tail 30 cp-dbread 2>&1; die "cp-dbread never became healthy"; }

# ── expose to tenant pods: forwarder on the bridge gateway + nft hole ───────
[ -f /etc/cl-egress.env ] || die "/etc/cl-egress.env missing — run m2.3-egress.sh first"
# shellcheck disable=SC1091
. /etc/cl-egress.env
[ -n "${GW:-}" ] && [ -n "${SUBNET:-}" ] || die "GW/SUBNET not set in /etc/cl-egress.env"

log "installing + starting cl-dbread-forwarder (bind $GW:$POD_PORT)"
install -m 0644 "$RT/systemd/cl-dbread-forwarder.service" "$FWD_UNIT"
systemctl daemon-reload
systemctl enable --now cl-dbread-forwarder >/dev/null 2>&1 || true
systemctl is-active cl-dbread-forwarder >/dev/null \
  || { journalctl -u cl-dbread-forwarder -n 20 --no-pager; die "forwarder not active"; }

log "allowing $SUBNET -> host tcp/$POD_PORT (scoped; everything else stays dropped)"
# The perimeter drops pod->host by default (verified: only :22 and :10255 are open), so the
# gateway needs one explicit, narrow hole. Inserted before the drop rule in the same chain.
if nft list chain inet cl_egress input 2>/dev/null | grep -q "dport $POD_PORT"; then
  echo "  rule already present"
else
  nft insert rule inet cl_egress input ip saddr "$SUBNET" tcp dport "$POD_PORT" counter accept \
    || die "could not insert the nft rule"
  echo "  rule inserted"
fi
# Persist for reboots the same way m2.3 does (its template is re-applied by cl-egress-boot).
TMPL="$RT/nftables/cl-egress.nft.tmpl"
if [ -f "$TMPL" ] && ! grep -q "dport $POD_PORT" "$TMPL"; then
  sed -i "s#\(.*ip saddr __SUBNET__ tcp dport 10255 counter accept\)#\1\n    ip saddr __SUBNET__ tcp dport $POD_PORT counter accept#" "$TMPL"
  echo "  added to $TMPL for reboot persistence"
fi
ufw status >/dev/null 2>&1 && { ufw allow from "$SUBNET" to any port "$POD_PORT" proto tcp >/dev/null 2>&1 || true; }

cat <<EOF

== DONE ==
gateway:    http://$GW:$POD_PORT   (tenants)   /  127.0.0.1:$GW_PORT (host)
database:   $DBREAD_USER@$DBREAD_HOST:$DBREAD_PORT/$DBREAD_DB (read-only role)
password:   podman secret $PW_SECRET — never in a file, never in the pod
entitlement: role-matrix.json ($MATRIX_DST) — service 'supabase' (any role granted it)

Next, per tenant that should have DB read access:
  sudo bash $HERE/m9.1-dbread-gateway.sh --grant <user>

Rollback: sudo bash $HERE/m9.1-dbread-gateway-rollback.sh
EOF
