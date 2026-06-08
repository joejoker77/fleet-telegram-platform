#!/usr/bin/env bash
# Rollback for M2.2 — stop/remove the test tenant runtime, the unit + wrapper,
# and the throwaway test user. Run as root. Idempotent. One-command revert.
# Does NOT touch the live claude-tg@vitaliy bot or the M1 cp-* containers.
#
# DEV scaffolding (remove at end of dev — see project_fleet_dev_teardown).
set -uo pipefail
TEST_USER=cptest
WRAPPER=/usr/local/sbin/claude-pod-run
UNIT=/etc/systemd/system/claude-pod@.service
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "== stopping/disabling claude-pod@$TEST_USER =="
systemctl disable --now "claude-pod@$TEST_USER" 2>/dev/null || true
podman rm -f "claude-$TEST_USER" 2>/dev/null || true

echo "== removing unit + wrapper =="
rm -f "$UNIT" "$WRAPPER"
systemctl daemon-reload

echo "== removing throwaway test user $TEST_USER (and its home) =="
if id "$TEST_USER" >/dev/null 2>&1; then
  userdel -r "$TEST_USER" 2>/dev/null || userdel "$TEST_USER" 2>/dev/null || true
  echo "removed"
else
  echo "(not present)"
fi

echo "== sanity: live bot + M1 stores untouched =="
echo -n "claude-tg@vitaliy: "; systemctl is-active claude-tg@vitaliy 2>/dev/null || true
podman ps --filter 'name=cp-' --format '{{.Names}} {{.Status}}'
echo "M2.2 rollback done"
