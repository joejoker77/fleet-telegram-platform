#!/usr/bin/env bash
# M2.3 — egress lockdown for tenant containers, validated on throwaway cptest.
# Reuses the OneCLI proxy as the single egress chokepoint (no fragile IP
# allowlist). Run as root. Idempotent. Does NOT touch the live bot, the M1 cp-*
# containers, or the shared OneCLI config. DEV scaffolding (teardown).
set -euo pipefail

RT=/home/vitaliy/work/fleet-platform/runtime
FWD_UNIT=/etc/systemd/system/cl-egress-forwarder.service
SUBNET=10.89.0.0/24
GW=10.89.0.1
TEST_USER=cptest

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# 0) deps
command -v nft   >/dev/null 2>&1 || { log "installing nftables"; DEBIAN_FRONTEND=noninteractive apt-get install -y nftables; }
command -v socat >/dev/null 2>&1 || { log "installing socat";     DEBIAN_FRONTEND=noninteractive apt-get install -y socat; }

# 1) ensure the M2.2 testbed (idempotent) — recreates cptest + unit + wrapper if
#    a prior rollback removed them. Brings the pod up on the default bridge first.
log "ensuring M2.2 testbed"
bash "$RT/install/m2.2-runtime-testbed.sh"

# 2) isolated nftables lockdown (own table; cannot affect existing perimeter)
log "loading nftables table inet cl_egress"
nft -f "$RT/nftables/cl-egress.nft"
nft list table inet cl_egress >/dev/null || die "cl_egress table not loaded"

# 3) dedicated egress network
if ! podman network exists cl-net; then
  log "creating cl-net ($SUBNET gw $GW)"
  podman network create --subnet "$SUBNET" --gateway "$GW" cl-net >/dev/null
fi

# 4) restart the pod so it joins cl-net (adaptive wrapper picks it up)
log "restarting claude-pod@$TEST_USER onto cl-net"
systemctl restart "claude-pod@$TEST_USER"
ok=""
for _ in $(seq 1 30); do
  [ "$(podman inspect -f '{{.State.Running}}' claude-$TEST_USER 2>/dev/null)" = "true" ] && { ok=1; break; }
  sleep 1
done
[ -n "$ok" ] || { journalctl -u "claude-pod@$TEST_USER" -n 30 --no-pager; die "pod not running on cl-net"; }
echo "container network: $(podman inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{end}}' claude-$TEST_USER)"

# 5) forwarder (bridge gateway -> OneCLI proxy on host loopback)
log "installing + starting cl-egress-forwarder"
install -m 0644 "$RT/systemd/cl-egress-forwarder.service" "$FWD_UNIT"
systemctl daemon-reload
systemctl enable --now cl-egress-forwarder
sleep 2
systemctl is-active cl-egress-forwarder || { journalctl -u cl-egress-forwarder -n 20 --no-pager; die "forwarder not active"; }

# 6) verify lockdown from inside the container
log "VERIFY egress lockdown (from inside claude-$TEST_USER)"
echo -n "  direct internet (1.1.1.1, no proxy) — expect BLOCKED (000): "
direct=$(podman exec claude-$TEST_USER curl --noproxy '*' -m 6 -s -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null || echo 000)
echo "$direct"
echo -n "  via proxy to api.anthropic.com — expect REACHABLE (non-000, e.g. 401/407): "
viaproxy=$(podman exec claude-$TEST_USER curl -m 12 -s -o /dev/null -w '%{http_code}' -x http://$GW:10255 https://api.anthropic.com/v1/messages 2>/dev/null || echo 000)
echo "$viaproxy"

echo
if [ "$direct" = "000" ] && [ "$viaproxy" != "000" ]; then
  echo "✅ M2.3 LOCKDOWN OK — direct internet blocked, egress only via the proxy"
else
  echo "❌ M2.3 lockdown NOT as expected (direct=$direct viaproxy=$viaproxy) — see above"
  exit 1
fi
