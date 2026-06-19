#!/usr/bin/env bash
# M2.3 — egress lockdown for tenant containers, validated on throwaway cptest.
# Reuses the OneCLI proxy as the single egress chokepoint (no fragile IP
# allowlist). cl-net's subnet is podman-assigned (collision-free); the nft rules,
# forwarder, and wrapper all derive from it. Run as root. Idempotent. Does NOT
# touch the live bot, the M1 cp-* containers, or the shared OneCLI config.
# DEV scaffolding (teardown).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
RT="$ROOT/runtime"
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

# 1) (removed) the M2.2 cptest testbed was a DEV validation harness — a product
#    install must NOT spin a tenant pod here (it would need Claude creds the fresh
#    host doesn't have yet). The egress perimeter is verified below by inspecting
#    the loaded rules + forwarder + gateway, not by running a test tenant. Real
#    tenants are created later by add-user (with creds) and exercise egress live.

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

# 4c) reboot persistence for the nft rules: cl_egress lives in its own table and
#     does NOT survive a reboot. Install a boot unit that reloads $NFT_FILE (the
#     rules are pure IP-subnet matches, so they load independent of cl-net being
#     up; the cl-net subnet is podman-persistent so $NFT_FILE stays valid). The
#     infra containers (--restart=always) + podman-restart.service handle the
#     bridge/forwarder; the forwarder self-retries (Restart=always) until the
#     bridge is up. Without this, the egress lockdown was lost after a VPS reboot.
log "installing cl-egress-boot.service (reboot persistence for nft rules)"
install -m 0644 "$RT/systemd/cl-egress-boot.service" /etc/systemd/system/cl-egress-boot.service
systemctl daemon-reload
systemctl enable cl-egress-boot.service >/dev/null 2>&1 || true

# 4b) the host runs UFW with input policy=drop; a separate-table accept can't
#     override it, so allow the tenant subnet to reach the proxy port via UFW.
#     Scoped (subnet -> :10255 only) and reversible (rollback does ufw delete).
#     UFW manages its own 'ip filter' table; this does NOT touch inet cl_egress.
if command -v ufw >/dev/null 2>&1; then
  log "ufw: allow $SUBNET -> tcp/10255 (proxy)"
  ufw allow from "$SUBNET" to any port 10255 proto tcp >/dev/null || true
fi

# 5) keep the cl-net bridge up so the forwarder can bind the gateway IP. podman/
#    netavark only brings the bridge (and gateway IP) up while >=1 container is
#    attached; with no tenant pod yet, a tiny idle ANCHOR container holds it online.
#    NOT a tenant — no Claude, no creds; purely a network anchor (like a k8s pause
#    container). Real tenant pods later share the same bridge; the anchor stays
#    harmless. Removed by m2.3-rollback / uninstall.
ANCHOR_IMAGE="${ANCHOR_IMAGE:-docker.io/library/ubuntu:24.04}"
podman image exists "$ANCHOR_IMAGE" || { log "pulling anchor image"; podman pull "$ANCHOR_IMAGE" >/dev/null; }
log "ensuring cl-net anchor (keeps the bridge/gateway up)"
podman rm -f cl-net-anchor >/dev/null 2>&1 || true
podman run -d --name cl-net-anchor --network cl-net --restart=always \
  "$ANCHOR_IMAGE" sleep infinity >/dev/null
up=""
for _ in $(seq 1 20); do
  ip -o addr show 2>/dev/null | grep -q "$GW" && { up=1; break; }
  sleep 1
done
[ -n "$up" ] || die "cl-net gateway $GW did not come up on the host bridge"
echo "cl-net bridge up (gateway $GW present via anchor)"

# 6) forwarder (bridge gateway -> OneCLI proxy on host loopback)
log "installing + starting cl-egress-forwarder (bind $GW)"
install -m 0644 "$RT/systemd/cl-egress-forwarder.service" "$FWD_UNIT"
systemctl daemon-reload
systemctl enable --now cl-egress-forwarder
sleep 2
systemctl is-active cl-egress-forwarder >/dev/null || { journalctl -u cl-egress-forwarder -n 20 --no-pager; die "forwarder not active"; }

# 7) verify the egress PERIMETER is installed correctly — by inspecting the loaded
#    rules + services, NOT by running a tenant pod (credential-free, deterministic):
#    - the nft cl_egress table is loaded and scopes the cl-net subnet
#    - the cl-egress-forwarder service is active (bridge gateway -> OneCLI proxy)
#    - the OneCLI gateway (the forwarder's backend) is listening on 127.0.0.1:10255
log "VERIFY egress perimeter (rules + forwarder + gateway)"
nft list table inet cl_egress >/dev/null 2>&1 || die "cl_egress nft table not loaded"
nft list table inet cl_egress | grep -q "$SUBNET" || die "cl_egress table missing the cl-net subnet ($SUBNET) rule"
systemctl is-active cl-egress-forwarder >/dev/null 2>&1 || die "cl-egress-forwarder not active"
ss -ltn 2>/dev/null | grep -q '127.0.0.1:10255' || die "OneCLI gateway not listening on 127.0.0.1:10255 (run m1.1-onecli.sh first)"
echo
echo "✅ M2.3 egress perimeter OK — nft cl_egress loaded for $SUBNET; cl-egress-forwarder active; OneCLI gateway up on 127.0.0.1:10255."
echo "   (Live tenant egress is exercised when a real tenant pod joins cl-net via add-user.)"
