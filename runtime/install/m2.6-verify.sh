#!/usr/bin/env bash
# M2.6 verify — provision the test tenant cptest end-to-end, then confirm
# metering now resolves to it (it finally has a control-plane users row).
# Run as root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
RT="$ROOT/runtime"
CP="$ROOT/control-plane"
log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

log "provision test tenant cptest (telegram_id 999000001, fake)"
bash "$RT/install/provision-tenant.sh" cptest 999000001

log "inject a usage.turn as cptest (now that it's a known tenant)"
podman exec -e ACTOR=cptest cp-api node "$CP/install/inject-usage.mjs"
sleep 1

log "usage_records joined to the cptest tenant (expect a row)"
out="$(podman exec cp-postgres psql -U cplane -d control_plane -tAF'  ' -c \
  "select u.os_username, ur.model, ur.tokens from usage_records ur join users u on u.id=ur.user_id where u.os_username='cptest' order by ur.id desc limit 3;")"
echo "$out"

echo
if echo "$out" | grep -q '^cptest'; then
  echo "✅ M2.6: provisioner created the tenant end-to-end + metering resolves to it"
else
  echo "❌ M2.6: no usage_records resolved to cptest — see above"; exit 1
fi
