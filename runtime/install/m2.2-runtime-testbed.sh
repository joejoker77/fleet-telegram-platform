#!/usr/bin/env bash
# M2.2 — install the claude-pod@ unit + wrapper and validate it on a THROWAWAY
# test tenant (cptest). Does NOT touch the live claude-tg@vitaliy bot. Run as
# root. Idempotent. DEV scaffolding (teardown — see project_fleet_dev_teardown).
set -euo pipefail

TEST_USER=cptest
RT=/home/vitaliy/work/fleet-platform/runtime
WRAPPER=/usr/local/sbin/claude-pod-run
UNIT=/etc/systemd/system/claude-pod@.service

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
podman image exists localhost/claude-user:latest || die "image missing (run m2.1 first)"

# 1) throwaway test tenant + dirs
if ! id "$TEST_USER" >/dev/null 2>&1; then
  log "creating test tenant $TEST_USER"
  useradd --create-home --shell /usr/sbin/nologin "$TEST_USER"
fi
install -d -o "$TEST_USER" -g "$TEST_USER" "/home/$TEST_USER/.claude" "/home/$TEST_USER/work"

# 2) install wrapper + unit
log "installing wrapper + unit"
install -m 0755 "$RT/systemd/claude-pod-run" "$WRAPPER"
install -m 0644 "$RT/systemd/claude-pod@.service" "$UNIT"
systemctl daemon-reload

# 3) enable + start for the test tenant
log "enabling claude-pod@$TEST_USER"
systemctl enable --now "claude-pod@$TEST_USER" || true

# 4) wait for the container to come up
log "waiting for container claude-$TEST_USER"
ok=""
for _ in $(seq 1 30); do
  if [ "$(podman inspect -f '{{.State.Running}}' "claude-$TEST_USER" 2>/dev/null)" = "true" ]; then ok=1; echo "running"; break; fi
  sleep 1
done
if [ -z "$ok" ]; then
  echo "container not running — diagnostics:"
  systemctl status "claude-pod@$TEST_USER" --no-pager -l | tail -20 || true
  journalctl -u "claude-pod@$TEST_USER" --no-pager -n 30 || true
  podman logs --tail 30 "claude-$TEST_USER" 2>&1 || true
  exit 1
fi

# 5) verify hardening + limits actually applied
log "verifying hardening on claude-$TEST_USER"
echo -n "unit active:   "; systemctl is-active "claude-pod@$TEST_USER"
echo    "runs as user:  $(podman inspect -f '{{.Config.User}}' claude-$TEST_USER)  (expect $(id -u $TEST_USER):$(id -g $TEST_USER))"
echo    "read-only fs:  $(podman inspect -f '{{.HostConfig.ReadonlyRootfs}}' claude-$TEST_USER)  (expect true)"
echo    "no-new-privs:  $(podman inspect -f '{{.HostConfig.SecurityOpt}}' claude-$TEST_USER)"
echo    "caps dropped:  $(podman inspect -f '{{.HostConfig.CapDrop}}' claude-$TEST_USER)"
echo    "mem limit:     $(podman inspect -f '{{.HostConfig.Memory}}' claude-$TEST_USER)  (expect 4294967296)"
echo    "pids limit:    $(podman inspect -f '{{.HostConfig.PidsLimit}}' claude-$TEST_USER)"
echo    "init (tini):   $(podman inspect -f '{{.HostConfig.Init}}' claude-$TEST_USER)  (expect true)"
echo -n "uid inside:    "; podman exec "claude-$TEST_USER" id -u 2>/dev/null || echo "(exec n/a)"

log "M2.2 testbed OK"
podman ps --filter "name=claude-$TEST_USER" --format '{{.Names}}  {{.Status}}'
