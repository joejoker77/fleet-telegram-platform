#!/usr/bin/env bash
# m9.2-grapple-replica-gateway.sh — a second read-only SQL gateway, this one in front of
# Grapple's read-only replica of their database (the redacted ai_analytics views).
#
# WHY A GATEWAY AND NOT A .pgpass IN EACH POD. Grapple asked for the password to be stored
# per pod as a 600 pgpass or a podman secret, never in env, a repo or the image. Two facts
# on this host push it one step further:
#   1. A tenant pod has no working DNS of its own. Everything a pod reaches goes out through
#      the OneCLI egress proxy, which resolves on its behalf; a direct libpq connection to
#      db.<ref>.supabase.co therefore cannot resolve the name inside the pod, although the
#      route to the address itself is open.
#   2. The platform's rule, written into the m9.1 gateway this file is modelled on: a tenant
#      process NEVER holds a credential. A pod that holds a database password can be talked
#      into printing it, and these pods read client data.
# So the password stays host-side in a podman secret and tenants get an HTTP endpoint, which
# satisfies every constraint Grapple set and one they could not know about.
#
# The replica is read-only at the server (pg_is_in_recovery() = t) and the role can only
# SELECT the six redacted views, so this gateway adds bounds, not the primary control.
#
# Run it through the broker by its path:
#   <this script>                 install / re-install
#   <this script> --grant <user>  mint a token for one tenant
#   <this script> --revoke <user>
#   <this script> --test          re-run the connection test
#
# The password is typed at a hidden prompt when run on a terminal; with no terminal it is
# read as the first line of stdin. It never appears in argv, in a file on disk, in the
# gateway's environment, or in any log.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RT="$REPO/runtime"
NODE_IMAGE="${NODE_IMAGE:-docker.io/library/node:22-alpine}"
GW_PORT=8093                 # host loopback (gateway container, --network host)
POD_PORT=10258               # what tenant pods talk to, on the cl-net gateway IP
PW_SECRET=cp_grapple_password
STATE_DIR=/etc/claudeapp/grapple-replica
TOKENS_FILE="$STATE_DIR/tokens.json"
TOKEN_NAME=grapple.token     # the tenant-side file name, beside dbread.token
MATRIX_SRC="$RT/install/role-matrix.json"
MATRIX_DST="$STATE_DIR/role-matrix.json"
FWD_UNIT=/etc/systemd/system/cl-grapple-forwarder.service
SERVICE_KEY=grapple_replica  # this gateway's own row in role-matrix.json
CONTAINER=cp-grapple

# Connection parameters (non-secret), as supplied by Grapple 2026-11-03. The direct port,
# not the pooler, was their explicit instruction.
PG_HOST="${GRAPPLE_HOST:-db.xoluhviwobrwkieyxbkg-rr-eu-west-2-swwjh.supabase.co}"
PG_PORT="${GRAPPLE_PORT:-5432}"
PG_DB="${GRAPPLE_DB:-postgres}"
PG_USER="${GRAPPLE_USER:-ai_analytics}"
PG_SSL="${GRAPPLE_SSL:-require}"

log(){ printf '\n== %s ==\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

install -d -m 0700 "$STATE_DIR"
[ -f "$TOKENS_FILE" ] || { printf '{}\n' > "$TOKENS_FILE"; chmod 600 "$TOKENS_FILE"; }

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
m = {d: t for d, t in m.items() if t != os.environ["U"]}
m[os.environ["DIGEST"]] = os.environ["U"]
json.dump(m, open(p, "w"), indent=1)
PY
  chmod 600 "$TOKENS_FILE"
  local dir="/home/$u/.claude"
  install -d -o "$u" -g "$u" -m 0700 "$dir"
  umask 077; printf '%s' "$tok" > "$dir/$TOKEN_NAME"
  chown "$u:$u" "$dir/$TOKEN_NAME"; chmod 600 "$dir/$TOKEN_NAME"
  echo "  granted Grapple replica access to $u (role=$(tr -d ' \t\r\n' < "/etc/claude-role/$u"))"
  echo "  token file: $dir/$TOKEN_NAME (tenant-owned, 600)"
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
  rm -f "/home/$u/.claude/$TOKEN_NAME"
  echo "  revoked Grapple replica access for $u"
}

# ── the connection test Grapple asked for ────────────────────────────────────
# Runs in a throw-away container with the podman secret mounted, so the password is read
# from /run/secrets and nowhere else: not argv, not the environment, not a file we wrote.
# It proves the credential works, that the server really is a replica
# (pg_is_in_recovery() = t, which is also why no write probe is needed — a server in
# recovery physically cannot be written to), and which views the role can see.
write_test_script(){
  cat > "$STATE_DIR/selftest.mjs" <<'JS'
import { readFileSync } from "node:fs";
import pg from "pg";
const password = readFileSync(process.env.PW_FILE, "utf8").trim();
const client = new pg.Client({
  host: process.env.PG_HOST,
  port: Number(process.env.PG_PORT),
  database: process.env.PG_DB,
  user: process.env.PG_USER,
  password,
  ssl: process.env.PG_SSL === "disable" ? false : { rejectUnauthorized: false },
  connectionTimeoutMillis: 15000,
});
try {
  await client.connect();
} catch (err) {
  console.log("CONNECT FAILED: " + (err?.message ?? err));
  process.exit(2);
}
const who = await client.query(
  "select pg_is_in_recovery() as replica, current_user as who, inet_server_addr() as addr");
console.log("  connected as      : " + who.rows[0].who + " @ " + who.rows[0].addr);
console.log("  pg_is_in_recovery : " +
  (who.rows[0].replica ? "t  (read-only replica, as expected)" : "f  *** NOT a replica ***"));
const views = await client.query(
  "select table_name, table_type from information_schema.tables where table_schema = 'ai_analytics' order by 1");
console.log("  ai_analytics      : " + views.rowCount + " object(s) visible to this role");
for (const r of views.rows) console.log("      " + r.table_name + "  (" + r.table_type + ")");
await client.end();
process.exit(who.rows[0].replica ? 0 : 3);
JS
  chmod 644 "$STATE_DIR/selftest.mjs"
}

run_test(){
  podman secret inspect "$PW_SECRET" >/dev/null 2>&1 || die "no $PW_SECRET secret yet — install first"
  write_test_script
  log "testing the connection (pg_is_in_recovery, and what the role can see)"
  podman run --rm --network host \
    --workdir "$REPO/control-plane" -v "$REPO:$REPO:ro" -v "$STATE_DIR:$STATE_DIR:ro" \
    --secret "$PW_SECRET" \
    -e NODE_PATH="$REPO/control-plane/node_modules" \
    -e PW_FILE="/run/secrets/$PW_SECRET" \
    -e PG_HOST="$PG_HOST" -e PG_PORT="$PG_PORT" -e PG_DB="$PG_DB" -e PG_USER="$PG_USER" -e PG_SSL="$PG_SSL" \
    "$NODE_IMAGE" node "$STATE_DIR/selftest.mjs"
}

case "${1:-}" in
  --grant)  grant_tenant "${2:-}"; exit 0 ;;
  --revoke) revoke_tenant "${2:-}"; exit 0 ;;
  --test)   run_test; exit $? ;;
  "" ) ;;
  * ) die "unknown argument: $1 (use --grant <user> / --revoke <user> / --test)" ;;
esac

log "Grapple read-only replica gateway for $PG_USER@$PG_HOST/$PG_DB"

# ── reachability, before anything else ───────────────────────────────────────
# Supabase direct database hosts are often IPv6-only and this host has no IPv6, so this is
# the check that explains a later timeout instead of leaving it a mystery.
ADDR4="$(getent ahostsv4 "$PG_HOST" 2>/dev/null | awk 'NR==1{print $1}')"
ADDR6="$(getent ahostsv6 "$PG_HOST" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}')"
if [ -n "$ADDR4" ]; then
  echo "  resolves to IPv4 $ADDR4"
elif [ -n "$ADDR6" ]; then
  die "$PG_HOST has only an IPv6 address ($ADDR6) and this host has no IPv6 route — ask Grapple for an IPv4 endpoint"
else
  die "$PG_HOST does not resolve from this host"
fi
PG_HOST_ADDR="$ADDR4" PG_PORT="$PG_PORT" python3 - <<'PY' || die "tcp port not reachable from this host (their firewall, or the wrong port)"
import os, socket, sys
addr, port = os.environ["PG_HOST_ADDR"], int(os.environ["PG_PORT"])
s = socket.socket(); s.settimeout(10)
try:
    s.connect((addr, port)); print(f"  tcp/{port} reachable from the host")
except Exception as e:
    print(f"  tcp/{port} NOT reachable: {e}"); sys.exit(1)
finally:
    s.close()
PY

# ── password → podman secret (never a file on disk, never in argv) ───────────
if podman secret inspect "$PW_SECRET" >/dev/null 2>&1; then
  echo "  podman secret $PW_SECRET already exists — keeping (remove it to re-enter)"
else
  if [ -t 0 ]; then
    printf 'Password for PostgreSQL role %s (input hidden): ' "$PG_USER" >&2
    read -rs PW; echo >&2
  else
    # No terminal (run through the audited broker, or from an automation): the password is
    # the first line of stdin and is never echoed.
    IFS= read -r PW || true
  fi
  [ -n "${PW:-}" ] || die "no password given (type it at the prompt, or send it as the first line of stdin)"
  printf '%s' "$PW" | podman secret create "$PW_SECRET" - >/dev/null || die "could not store the password as a podman secret"
  unset PW
  echo "  stored $PW_SECRET (podman secret; not on disk, not in any environment)"
fi

# ── role matrix snapshot the gateway reads (entitlement source of truth) ─────
[ -f "$MATRIX_SRC" ] || die "role-matrix.json not found at $MATRIX_SRC"
install -m 0644 "$MATRIX_SRC" "$MATRIX_DST"
MATRIX_DST="$MATRIX_DST" SERVICE_KEY="$SERVICE_KEY" python3 - <<'PY' || die "role-matrix.json has no such service — add it before installing"
import json, os, sys
m = json.load(open(os.environ["MATRIX_DST"]))
svc = (m.get("services") or {}).get(os.environ["SERVICE_KEY"])
if not svc:
    sys.exit(1)
roles = ", ".join(f"{r}:{s}" for r, s in (svc.get("roles") or {}).items()) or "nobody yet"
print(f"  role matrix → entitled: {roles}")
PY

# ── dependencies + container ─────────────────────────────────────────────────
( cd "$REPO/control-plane" && corepack pnpm install --silent >/dev/null 2>&1 ) \
  || echo "  WARN: pnpm install reported an issue — continuing (deps may already be present)"
podman image exists "$NODE_IMAGE" || { log "pulling $NODE_IMAGE"; podman pull "$NODE_IMAGE" >/dev/null; }

log "starting $CONTAINER (127.0.0.1:$GW_PORT)"
podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
podman run -d --name "$CONTAINER" --network host \
  --workdir "$REPO/control-plane" -v "$REPO:$REPO:ro" \
  -v "$STATE_DIR:$STATE_DIR:ro" -v /etc/claude-role:/etc/claude-role:ro \
  --secret "$PW_SECRET" \
  --restart=always \
  "$NODE_IMAGE" \
  sh -c 'set -e; export HOST=127.0.0.1 PORT='"$GW_PORT"';
    export DBREAD_HOST='"$PG_HOST"' DBREAD_PORT='"$PG_PORT"' DBREAD_DB='"$PG_DB"' DBREAD_USER='"$PG_USER"' DBREAD_SSL='"$PG_SSL"';
    export DBREAD_PASSWORD_FILE=/run/secrets/'"$PW_SECRET"';
    export DBREAD_TOKENS_FILE='"$TOKENS_FILE"' ROLE_MATRIX_FILE='"$MATRIX_DST"';
    export DBREAD_SERVICE='"$SERVICE_KEY"';
    exec node_modules/.bin/tsx apps/dbread-gateway/src/index.ts' >/dev/null

log "waiting for $CONTAINER /healthz"
ok=""
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$GW_PORT/healthz" >/dev/null 2>&1; then ok=1; echo "healthz OK"; break; fi
  [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "running" ] \
    || { podman logs --tail 30 "$CONTAINER" 2>&1; die "$CONTAINER is not running"; }
  sleep 1
done
[ -n "$ok" ] || { podman logs --tail 30 "$CONTAINER" 2>&1; die "$CONTAINER never became healthy"; }

# ── expose to tenant pods: forwarder on the bridge gateway + one nft hole ────
[ -f /etc/cl-egress.env ] || die "/etc/cl-egress.env missing — run m2.3-egress.sh first"
# shellcheck disable=SC1091
. /etc/cl-egress.env
[ -n "${GW:-}" ] && [ -n "${SUBNET:-}" ] || die "GW/SUBNET not set in /etc/cl-egress.env"

log "installing + starting cl-grapple-forwarder (bind $GW:$POD_PORT)"
install -m 0644 "$RT/systemd/cl-grapple-forwarder.service" "$FWD_UNIT"
systemctl daemon-reload
systemctl enable --now cl-grapple-forwarder >/dev/null 2>&1 || true
systemctl is-active cl-grapple-forwarder >/dev/null \
  || { journalctl -u cl-grapple-forwarder -n 20 --no-pager; die "forwarder not active"; }

log "allowing $SUBNET -> host tcp/$POD_PORT (scoped; everything else stays dropped)"
if nft list chain inet cl_egress input 2>/dev/null | grep -q "dport $POD_PORT"; then
  echo "  rule already present"
else
  nft insert rule inet cl_egress input ip saddr "$SUBNET" tcp dport "$POD_PORT" counter accept \
    || die "could not insert the nft rule"
  echo "  rule inserted"
fi
# Persistence: the boot unit re-applies the RENDERED template, so a rule added only to the
# live ruleset is lost the next time this machine starts up (that is how the host-sudo port
# was lost on 2026-09-07). It goes in the template too.
TMPL="$RT/nftables/cl-egress.nft.tmpl"
if [ -f "$TMPL" ] && ! grep -q "dport $POD_PORT" "$TMPL"; then
  sed -i "s#\(.*ip saddr __SUBNET__ tcp dport 10255 counter accept\)#\1\n    ip saddr __SUBNET__ tcp dport $POD_PORT counter accept#" "$TMPL"
  echo "  added to $TMPL so it survives a restart of the machine"
fi
ufw status >/dev/null 2>&1 && { ufw allow from "$SUBNET" to any port "$POD_PORT" proto tcp >/dev/null 2>&1 || true; }

run_test; test_rc=$?

cat <<EOF

== DONE ==
gateway:     http://$GW:$POD_PORT   (tenants)   /  127.0.0.1:$GW_PORT (host)
database:    $PG_USER@$PG_HOST:$PG_PORT/$PG_DB (read-only replica, direct port)
password:    podman secret $PW_SECRET — never in a file, never in a pod
entitlement: role-matrix.json service '$SERVICE_KEY'
connection test exit code: $test_rc (0 = connected and in recovery)

Per tenant that should reach it:
  <this script> --grant <user>      → /home/<user>/.claude/$TOKEN_NAME

How a tenant queries it:
  curl -s -X POST http://$GW:$POD_PORT/query \\
    -H "Authorization: Bearer \$(cat ~/.claude/$TOKEN_NAME)" \\
    -H 'Content-Type: application/json' \\
    -d '{"sql":"select * from ai_analytics.<view> limit 20"}'
EOF
exit "$test_rc"
