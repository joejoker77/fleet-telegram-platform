#!/usr/bin/env bash
# SAFE pre-cutover prep for ANY live per-user bot (generalized from the proven
# m3-prep-vitaliy.sh). Parameterized by <user>; also ensures the control-plane
# tenant row exists (the cutover pre-flight requires it).
#
# NO live impact: never starts the pod, never stops the running claude-tg@<user>.
# Idempotent.
#
#   sudo bash migrate-prep.sh <os_user> <telegram_id>
#   SKIP_TOKEN=1 sudo bash migrate-prep.sh <os_user> <telegram_id>   # steps 1-3 only
#
# Steps:
#   1. Full TIMESTAMPED backup of /home/<user>/.claude + ~/work -> rollback point.
#   2. Ensure control-plane users+containers rows (state 'provisioned'). No start.
#   3. Install the runtime unit + wrapper (file install only; pod NOT started).
#   4. OneCLI proxy token /etc/cl-egress/<user>.token by REUSING the live host
#      bot's token (no regenerate -> no rotation -> rollback-safe).
set -uo pipefail
U="${1:?usage: migrate-prep.sh <os_user> <telegram_id>}"
TG_ID="${2:?telegram_id required (for the control-plane tenant row)}"
RT=/home/vitaliy/work/fleet-platform/runtime
TOKDIR=/etc/cl-egress; TOKFILE="$TOKDIR/$U.token"
SD="/home/$U/.claude/channels/telegram-$U"
STAMP_FILE="/home/$U/work/.migrate-backup-path"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "no such OS user: $U"; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }
psql_cp() { podman exec -i cp-postgres psql -U cplane -d control_plane -v ON_ERROR_STOP=1 "$@"; }

say "1) backup live state (rollback point)"
# Write the archive OUTSIDE the trees being archived (~/work is archived, so a
# backup under ~/work would self-include). Timestamped so re-runs never clobber
# a known-good backup.
BK="/home/$U/migrate-backups"; mkdir -p "$BK"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$BK/backup-$STAMP.tar.gz"
tar --warning=no-file-changed \
    --exclude='.claude/tmux-*' --exclude='*/.git/objects' \
    -czf "$OUT" -C "/home/$U" .claude work
rc=$?
[ "$rc" -le 1 ] || { echo "  ✗ backup tar failed (rc=$rc)"; exit 1; }   # tar rc=1 = harmless warnings
chown -R "$U:$U" "$BK"
ls -lh "$OUT" | sed 's/^/  /'
echo "$OUT" > "$STAMP_FILE"; chown "$U:$U" "$STAMP_FILE"
echo "  backup written to $OUT (outside archived trees)"

say "2) ensure control-plane tenant row (no pod start)"
podman container exists cp-postgres || { echo "  ✗ cp-postgres missing (M1.2)"; exit 1; }
export HOME=/root
psql_cp <<SQL
insert into users (telegram_user_id, os_username, status, is_admin)
values (${TG_ID}, '${U}', 'active', false)
on conflict (telegram_user_id) do update set os_username = excluded.os_username, status = 'active';
SQL
UID_CP="$(psql_cp -tAc "select id from users where os_username='${U}';")"
[ -n "$UID_CP" ] || { echo "  ✗ failed to resolve control-plane user id"; exit 1; }
psql_cp <<SQL
insert into containers (user_id, state) values ('${UID_CP}', 'provisioned')
on conflict (user_id) do update set state = 'provisioned';
SQL
echo "  control-plane user_id=$UID_CP (tg=$TG_ID)"

say "3) install runtime unit + wrapper (NO start)"
install -m 0755 "$RT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
install -m 0644 "$RT/systemd/claude-pod@.service" /etc/systemd/system/claude-pod@.service
systemctl daemon-reload
echo "  installed claude-pod@.service + claude-pod-run (pod NOT enabled/started)"

if [ "${SKIP_TOKEN:-0}" = 1 ]; then
  say "4) SKIPPED OneCLI token (SKIP_TOKEN=1) — safe steps 1-3 done"
  exit 0
fi

say "4) OneCLI proxy token -> $TOKFILE  (REUSE host token, NO regenerate)"
# The live host bot authenticates to the OneCLI proxy with a token embedded in
# its HTTPS_PROXY (http://x:<token>@127.0.0.1:10255). Regenerating the <user>-bot
# agent token would rotate THAT out from under the live bot and break its egress.
# So reuse the exact same token for the container (same agent identity, no
# rotation, rollback-safe). The token is piped straight to the file, never printed.
mkdir -p "$TOKDIR"; chmod 0700 "$TOKDIR"
HPID="$(cat "$SD/bot.pid" 2>/dev/null)"
[ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null || { echo "  ✗ host poller (claude-tg@$U) not running — start it first so its proxy token can be reused"; exit 1; }
umask 077
USERINFO="$(tr '\0' '\n' < "/proc/$HPID/environ" 2>/dev/null | sed -n 's#^HTTPS_PROXY=http://\([^@]*\)@.*#\1#p' | head -1)"
PXTOKEN="${USERINFO#x:}"
if [ -n "$PXTOKEN" ]; then
  printf '%s' "$PXTOKEN" > "$TOKFILE"; chmod 0600 "$TOKFILE"; unset PXTOKEN USERINFO
  echo "  wrote $TOKFILE ($(stat -c%s "$TOKFILE") bytes) — reused host bot's OneCLI token (no regenerate)"
else
  echo "  ✗ could not extract host proxy token — leave the token step to operator review"; exit 1
fi
say "PREP DONE — pod NOT started. Next: DRYRUN=1 bash migrate-cutover.sh $U  (confirm green), then the real cutover."
