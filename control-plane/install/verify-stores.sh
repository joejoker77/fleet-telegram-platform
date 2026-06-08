#!/usr/bin/env bash
# Verify the M1.2 control-plane stores (also the M1.6 acceptance spot-check).
# Run as root on the host (the bot can't reach rootful podman). Read-only.
set -uo pipefail
PSQL=(podman exec cp-postgres psql -U cplane -d control_plane -tAc)

echo "== containers =="
podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}  {{.Ports}}'

echo "== public tables (expect 11) =="
"${PSQL[@]}" "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE';"

echo "== enums (expect 5: user_status, sub_tier, artifact_type, scanner_kind, verdict_kind) =="
"${PSQL[@]}" "select string_agg(typname, ', ' order by typname) from pg_type where typtype='e';"

echo "== pilot tenant =="
"${PSQL[@]}" "select os_username||' / tg='||telegram_user_id||' / '||status||' / admin='||is_admin from users;"
"${PSQL[@]}" "select 'subscription: '||tier||' '||status from subscriptions;"

echo "== applied migrations =="
"${PSQL[@]}" "select count(*) from drizzle.\"__drizzle_migrations\";" 2>/dev/null || echo "(could not read drizzle meta table)"

echo "== redis =="
podman exec cp-redis redis-cli ping
