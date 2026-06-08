#!/usr/bin/env bash
# M2.7 — M2 acceptance gate. Roll-up verification of the whole tenant runtime
# perimeter on the provisioned cptest tenant + non-interference with the live
# stack. Read-mostly (one synthetic usage event). Run as root after M2.6.
set -uo pipefail
C=claude-cptest
CA=/etc/onecli/ca-bundle.pem
CP=/home/vitaliy/work/fleet-platform/control-plane
fail=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
hdr() { printf '\n### %s\n' "$1"; }
export HOME=/root

podman container exists "$C" || { echo "cptest not provisioned — run m2.6-verify.sh first"; exit 1; }
GW="$(podman network inspect cl-net --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["subnets"][0]["gateway"])')"
TOK="$(cat /etc/cl-egress/cptest.token 2>/dev/null)"

hdr "1) container hardening + limits"
[ "$(podman inspect -f '{{.State.Running}}' $C)" = "true" ]            && ok "running"        || bad "not running"
[ "$(podman inspect -f '{{.HostConfig.ReadonlyRootfs}}' $C)" = "true" ] && ok "read-only rootfs" || bad "rootfs not read-only"
[ "$(podman inspect -f '{{.HostConfig.Init}}' $C)" = "true" ]           && ok "init (tini)"    || bad "no init"
[ "$(podman inspect -f '{{.HostConfig.Memory}}' $C)" = "4294967296" ]   && ok "mem limit 4G"   || bad "mem limit wrong"
# podman expands --cap-drop=ALL into the list of dropped caps; verify the ground
# truth instead — the container's capability bounding set is empty.
capbnd=$(podman exec $C sh -c 'grep CapBnd /proc/self/status | awk "{print \$2}"' 2>/dev/null || echo "?")
[ "$capbnd" = "0000000000000000" ] && ok "all caps dropped (CapBnd=$capbnd)" || bad "caps present (CapBnd=$capbnd)"
[ "$(podman inspect -f '{{.Config.User}}' $C)" = "$(id -u cptest):$(id -g cptest)" ] && ok "runs as tenant uid" || bad "wrong user"

hdr "2) egress default-deny (only via the OneCLI proxy)"
d=$(podman exec $C curl --noproxy '*' -m6 -s -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null || true)
[ "$d" = "000" ] && ok "direct internet blocked (000)" || bad "direct internet NOT blocked ($d)"
p=$(podman exec $C curl -m12 -s -o /dev/null -w '%{http_code}' --cacert "$CA" -x "http://x:$TOK@$GW:10255" https://api.anthropic.com/v1/messages 2>/dev/null || true)
{ [ -n "$p" ] && [ "$p" != "000" ] && [ "$p" != "407" ]; } && ok "anthropic reachable via tenant token through MITM ($p)" || bad "anthropic via proxy failed ($p)"

hdr "3) OneCLI per-tenant isolation"
AID="$(onecli agents list 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('data',d);print(next((a['id'] for a in r if a.get('identifier')=='cptest-bot'),''))" 2>/dev/null)"
n="$(onecli agents secrets --id "$AID" 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);r=d.get('data',d);print(len(r))" 2>/dev/null || echo '?')"
[ "$n" = "0" ] && ok "cptest-bot sees 0 shared secrets (isolated)" || bad "cptest-bot sees $n secrets"
# NOTE: OneCLI is default-allow pass-through (its rules only block/rate_limit —
# no allowlist action), so an unconfigured host IS reachable *through the proxy*.
# The enforced guarantee is "egress ONLY via the audited proxy" (direct blocked,
# check 2), not a strict per-host allowlist. Informational, not a gate failure.
u=$(podman exec $C curl -m10 -s -o /dev/null -w '%{http_code}' --cacert "$CA" -x "http://x:$TOK@$GW:10255" https://example.com/ 2>/dev/null || true)
echo "  · info: example.com via proxy = $u (OneCLI default-allow; egress is proxy-only + audited, not strict whitelist — see M2.7 note)"

hdr "4) per-tenant metering resolves"
podman exec -e ACTOR=cptest cp-api node "$CP/install/inject-usage.mjs" >/dev/null 2>&1
sleep 1
m=$(podman exec cp-postgres psql -U cplane -d control_plane -tAc "select count(*) from usage_records ur join users u on u.id=ur.user_id where u.os_username='cptest';" 2>/dev/null || echo 0)
[ "${m:-0}" -ge 1 ] && ok "usage_records resolves to cptest ($m rows)" || bad "no usage_records for cptest"

hdr "5) non-interference with the live stack"
[ "$(systemctl is-active claude-tg@vitaliy)" = "active" ] && ok "claude-tg@vitaliy still active (NRestarts=$(systemctl show claude-tg@vitaliy -p NRestarts --value))" || bad "vitaliy bot not active"
dc=$(podman ps --filter 'name=cp-' --format '{{.Names}}' | wc -l)
[ "$dc" -ge 2 ] && ok "control-plane services up ($dc cp-* running)" || bad "cp-* services missing"
sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q n8n && ok "prototype docker stack intact" || bad "prototype stack disturbed?"

echo
if [ "$fail" -eq 0 ]; then echo "✅ M2.7 ACCEPTANCE PASSED — tenant runtime perimeter verified end-to-end"; else echo "❌ M2.7 had failures (see ✗ above)"; fi
exit "$fail"
