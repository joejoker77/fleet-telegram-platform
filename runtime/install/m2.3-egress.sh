#!/usr/bin/env bash
# M2.3 — egress lockdown for tenant containers, validated on throwaway cptest.
# Reuses the OneCLI proxy as the single egress chokepoint (no fragile IP
# allowlist). cl-net's subnet is podman-assigned (collision-free); the nft rules,
# forwarder, and wrapper all derive from it. Run as root. Idempotent. Does NOT
# touch the live bot, the M1 cp-* containers, or the shared OneCLI config.
# DEV scaffolding (teardown).
set -euo pipefail

RT=/home/vitaliy/work/fleet-platform/runtime
FWD_UNIT=/etc/systemd/system/cl-egress-forwarder.service
ENV_FILE=/etc/cl-egress.env
NFT_FILE=/etc/cl-egress.nft
TEST_USER=cptest

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# 0) deps
command -v nft   >/dev/null 2>&1 || { log "installing nftables"; DEBIAN_FRONTEND=noninteractive apt-get install -y nftables; }
command -v socat >/dev/null 2>&1 || { log "installing socat";     DEBIAN_FRONTEND=noninteractive apt-get install -y socat; }

# 1) ensure the M2.2 testbed (idempotent)
log "ensuring M2.2 testbed"
bash "$RT/install/m2.2-runtime-testbed.sh"

# 2) dedicated egress network — let podman auto-pick a free subnet (avoids the
#    10.89.0.0/24 collision with the host/docker stack).
if ! podman network exists cl-net; then
  log "creating cl-net (auto subnet)"
  podman network create cl-net >/dev/null
fi

# 3) derive subnet + gateway from cl-net, write the forwarder EnvironmentFile
log "reading cl-net subnet/gateway"
podman network inspect cl-net > /tmp/clnet.json
python3 - "$ENV_FILE" <<'PY'
import json, sys
d = json.load(open('/tmp/clnet.json'))[0]
s = d['subnets'][0]
open(sys.argv[1], 'w').write(f"SUBNET={s['subnet']}\nGW={s['gateway']}\n")
PY
. "$ENV_FILE"
[ -n "${SUBNET:-}" ] && [ -n "${GW:-}" ] || die "could not read cl-net subnet/gateway"
echo "cl-net: subnet=$SUBNET gateway=$GW"

# 4) generate + load the isolated nftables lockdown for this subnet
log "loading nftables table inet cl_egress"
sed -e "s#__SUBNET__#$SUBNET#g" -e "s#__GW__#$GW#g" "$RT/nftables/cl-egress.nft.tmpl" > "$NFT_FILE"
nft -f "$NFT_FILE"
nft list table inet cl_egress >/dev/null || die "cl_egress table not loaded"

# 4b) the host runs UFW with input policy=drop; a separate-table accept can't
#     override it, so allow the tenant subnet to reach the proxy port via UFW.
#     Scoped (subnet -> :10255 only) and reversible (rollback does ufw delete).
#     UFW manages its own 'ip filter' table; this does NOT touch inet cl_egress.
if command -v ufw >/dev/null 2>&1; then
  log "ufw: allow $SUBNET -> tcp/10255 (proxy)"
  ufw allow from "$SUBNET" to any port 10255 proto tcp >/dev/null || true
fi

# 5) restart the pod so it joins cl-net (adaptive wrapper picks it up)
log "restarting claude-pod@$TEST_USER onto cl-net"
systemctl restart "claude-pod@$TEST_USER"
ok=""
for _ in $(seq 1 30); do
  [ "$(podman inspect -f '{{.State.Running}}' claude-$TEST_USER 2>/dev/null)" = "true" ] && { ok=1; break; }
  sleep 1
done
[ -n "$ok" ] || { journalctl -u "claude-pod@$TEST_USER" -n 30 --no-pager; die "pod not running on cl-net"; }
echo "container networks: $(podman inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' claude-$TEST_USER 2>/dev/null)"

# 6) forwarder (bridge gateway -> OneCLI proxy on host loopback)
log "installing + starting cl-egress-forwarder (bind $GW)"
install -m 0644 "$RT/systemd/cl-egress-forwarder.service" "$FWD_UNIT"
systemctl daemon-reload
systemctl enable --now cl-egress-forwarder
sleep 2
systemctl is-active cl-egress-forwarder >/dev/null || { journalctl -u cl-egress-forwarder -n 20 --no-pager; die "forwarder not active"; }

# 7) verify egress (FULL OUTBOUND policy, 2026-06-15 owner decision — agents must
#    reach remote servers). Direct internet is now reachable BY DESIGN; the proxy
#    path stays intact (HTTP tools keep secret injection + audit); host services
#    stay confined by the unchanged `input` chain (only :10255).
log "VERIFY egress (full outbound; from inside claude-$TEST_USER)"
echo -n "  direct internet (1.1.1.1, no proxy) — expect REACHABLE now (non-000): "
# curl prints the http_code (000 on connection failure); `|| true` only
# neutralises the non-zero exit under set -e (no extra echo → no '000000').
direct=$(podman exec claude-$TEST_USER curl --noproxy '*' -m 6 -s -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null || true)
echo "$direct"
echo -n "  via proxy to api.anthropic.com — expect REACHABLE (non-000, e.g. 401/405/407): "
viaproxy=$(podman exec claude-$TEST_USER curl -m 12 -s -o /dev/null -w '%{http_code}' -x "http://$GW:10255" https://api.anthropic.com/v1/messages 2>/dev/null || true)
echo "$viaproxy"

echo
if [ "$direct" != "000" ] && [ "$viaproxy" != "000" ]; then
  echo "✅ M2.3 egress OK — full outbound reachable; HTTP still via proxy (subnet $SUBNET); host confined by the input chain (:10255 only)"
else
  echo "❌ M2.3 egress NOT as expected (direct=$direct viaproxy=$viaproxy) — see above"
  exit 1
fi
