#!/usr/bin/env bash
# M1.6 — control-plane foundation acceptance gate. Run as root on the host
# AFTER m1.5-services.sh. Read-only except for the audit event the round-trip
# writes. Exercises every M1 acceptance criterion from doc 07.
set -uo pipefail
REPO=/home/vitaliy/work/fleet-platform/control-plane
NODE_IMAGE=docker.io/library/node:22-alpine
fail=0

echo "############ 1) stores: schema (11 tables), enums (5), pilot tenant ############"
bash "$REPO/install/verify-stores.sh" || fail=1

echo
echo "############ 2) services running ############"
podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}' || fail=1

echo
echo "############ 3) auth round-trip: initData -> /auth/session -> /me (+ tamper=401) ############"
podman run --rm --network cp-net --workdir "$REPO" -v "$REPO:$REPO:ro" \
  --secret cp_bot_token \
  -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token -e API=http://cp-api:8080 -e TG_ID=2112420187 \
  "$NODE_IMAGE" node install/auth-roundtrip.mjs || fail=1

echo
echo "############ 4) audit hash-chain verifies (incl. the auth.session event above) ############"
podman exec cp-audit-collector sh -c "cd '$REPO' && AUDIT_DIR=/srv/audit node_modules/.bin/tsx apps/audit-collector/src/verify.ts" || fail=1

echo
echo "############ 5) non-interference: vitaliy bot untouched ############"
echo -n "claude-tg@vitaliy: "; systemctl is-active claude-tg@vitaliy
echo -n "NRestarts: "; systemctl show claude-tg@vitaliy -p NRestarts --value

echo
if [ "$fail" -eq 0 ]; then echo "✅ M1.6 ACCEPTANCE PASSED"; else echo "❌ M1.6 had failures (see above)"; fi
exit "$fail"
