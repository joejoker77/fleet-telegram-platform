#!/usr/bin/env bash
# Rollback for M2.3 (and the M2.2 testbed it ensures) — one command, full revert.
# Removes the nftables lockdown table, the forwarder, the cl-net network, and the
# throwaway test tenant. Run as root. Idempotent. Live bot + M1 cp-* untouched.
#
# DEV scaffolding (remove at end of dev — see project_fleet_dev_teardown).
set -uo pipefail
RT=/home/vitaliy/work/fleet-platform/runtime
FWD_UNIT=/etc/systemd/system/cl-egress-forwarder.service
TEST_USER=cptest
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "== removing nftables table inet cl_egress =="
nft delete table inet cl_egress 2>/dev/null && echo "deleted" || echo "(not present)"

echo "== stopping + removing forwarder =="
systemctl disable --now cl-egress-forwarder 2>/dev/null || true
rm -f "$FWD_UNIT"
systemctl daemon-reload

echo "== stopping pod so the network can be removed =="
systemctl stop "claude-pod@$TEST_USER" 2>/dev/null || true
podman rm -f "claude-$TEST_USER" 2>/dev/null || true

echo "== removing cl-net =="
podman network rm cl-net 2>/dev/null && echo "removed" || echo "(not present)"

echo "== removing the M2.2 testbed (unit, wrapper, test user) =="
bash "$RT/install/m2.2-rollback.sh" || true

echo "== sanity: live bot + M1 stores untouched =="
echo -n "claude-tg@vitaliy: "; systemctl is-active claude-tg@vitaliy 2>/dev/null || true
podman ps --filter 'name=cp-' --format '{{.Names}} {{.Status}}'
echo "M2.3 rollback done"
