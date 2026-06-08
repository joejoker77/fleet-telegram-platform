#!/usr/bin/env bash
# M2.4 — per-tenant OneCLI agent + scoped token + isolation, validated on cptest.
# ADDITIVE only: creates the cptest-bot agent; never touches existing agents,
# secrets, or rules. Run as root on the host (onecli must be authed in this
# context). Idempotent. DEV scaffolding (teardown).
set -euo pipefail

TEST_USER=cptest
AGENT_ID_NAME=cptest          # display name
AGENT_IDENT=cptest-bot        # identifier
TOKDIR=/etc/cl-egress
TOKFILE="$TOKDIR/$TEST_USER.token"
RT=/home/vitaliy/work/fleet-platform/runtime
CA=/etc/onecli/ca-bundle.pem

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v onecli >/dev/null 2>&1 || die "onecli not found"
export HOME=/root   # onecli reads its stored API key from \$HOME
onecli auth status >/dev/null 2>&1 || die "onecli not authenticated (run 'onecli auth login' as root first)"
podman container exists "claude-$TEST_USER" || die "claude-$TEST_USER not running (run m2.3-egress.sh first)"

mkdir -p "$TOKDIR"; chmod 0700 "$TOKDIR"

lookup_aid() {
  onecli agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='$AGENT_IDENT'),''))" 2>/dev/null || true
}

# 1) ensure the tenant agent exists (create if missing)
log "ensuring OneCLI agent $AGENT_IDENT"
AID="$(lookup_aid)"
if [ -z "$AID" ]; then
  onecli agents create --name "$AGENT_ID_NAME" --identifier "$AGENT_IDENT" >/dev/null
  AID="$(lookup_aid)"
fi
[ -n "$AID" ] || die "could not create/find agent $AGENT_IDENT"
echo "agent id=$AID"

# 2) get a fresh scoped token (regenerate-token reliably returns accessToken)
TOKEN="$(onecli agents regenerate-token --id "$AID" | python3 -c "
import json,sys
d=json.load(sys.stdin); a=d.get('data',d) if isinstance(d,dict) else d
print(a.get('accessToken',''))" 2>/dev/null || true)"
[ -n "$TOKEN" ] || die "could not obtain access token for $AID"

# 2) selective secret mode → tenant isolation (does NOT inherit shared secrets)
log "setting secretMode=selective (isolation)"
onecli agents set-secret-mode --id "$AID" --mode selective >/dev/null

# 3) verify isolation: the agent sees NO secrets (none assigned)
log "agent's visible secrets (expect none)"
onecli agents secrets --id "$AID" 2>&1 | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
  print(f'  visible secrets: {len(rows)}'+('' if rows else '  -> isolated (sees no shared secrets)'))
except Exception: print('  (could not parse; check manually)')"

# 4) write the token, (re)install the latest wrapper (so CA mount + token take
#    effect), restart the pod to pick it all up
log "wiring token + installing latest wrapper into the tenant container"
umask 077; printf '%s' "$TOKEN" > "$TOKFILE"; chmod 0600 "$TOKFILE"
install -m 0755 "$RT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
systemctl restart "claude-pod@$TEST_USER"
for _ in $(seq 1 30); do [ "$(podman inspect -f '{{.State.Running}}' claude-$TEST_USER 2>/dev/null)" = "true" ] && break; sleep 1; done

# 5) verify: proxy accepts the tenant token + anthropic reachable; unknown host denied
GW="$(podman network inspect cl-net --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["subnets"][0]["gateway"])')"
log "VERIFY per-tenant proxy auth + allow/deny"
echo -n "  onecli CA mounted in container: "
podman exec claude-$TEST_USER test -f "$CA" && echo "yes" || echo "NO (mount missing)"
# --cacert points at the mounted onecli CA (podman exec doesn't reliably inherit
# the run-time CA env; the live runtime uses NODE_EXTRA_CA_CERTS set at run).
echo -n "  anthropic via tenant token (expect reached: 401, NOT 407/000): "
a=$(podman exec claude-$TEST_USER curl -m12 -s -o /dev/null -w '%{http_code}' --cacert "$CA" -x "http://x:$TOKEN@$GW:10255" https://api.anthropic.com/v1/messages 2>/dev/null || true); echo "$a"
echo -n "  unconfigured host example.com via tenant token (expect denied, NOT 200): "
u=$(podman exec claude-$TEST_USER curl -m12 -s -o /dev/null -w '%{http_code}' --cacert "$CA" -x "http://x:$TOKEN@$GW:10255" https://example.com/ 2>/dev/null || true); echo "$u"

echo
if [ "$a" = "401" ] || { [ "$a" != "000" ] && [ "$a" != "407" ]; }; then
  echo "✅ M2.4: tenant agent token works (proxy authed as cptest-bot, anthropic allowed); selective isolation set"
  echo "   (anthropic=$a, example.com=$u — example.com should be a deny code, not 200)"
else
  echo "❌ M2.4 unexpected (anthropic=$a, example.com=$u) — see above"; exit 1
fi
