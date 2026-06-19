#!/usr/bin/env bash
# M3.1 — SAFE pre-cutover prep for the pilot tenant. NO live impact: it never
# starts the container pod and never touches the running claude-tg@<user>. Idempotent.
#
#   sudo bash m3-prep-vitaliy.sh [<os_user>]
#
# Does three things:
#   1. Full backup of /home/<user>/.claude + ~/work  -> independent rollback point.
#   2. Install the runtime unit + wrapper (file install only; pod NOT enabled/started).
#   3. Provision the OneCLI proxy token /etc/cl-egress/<user>.token for container egress.
#
# ⚠️ Step 3 calls `onecli agents regenerate-token` for the <user>-bot agent.
# DO NOT RUN until we've confirmed the live host bot does not depend on that
# token (see SKIP_TOKEN below). Run `SKIP_TOKEN=1 sudo bash m3-prep-vitaliy.sh`
# to do only the safe steps (1+2) first.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
U="${1:-vitaliy}"   # pilot default
RT="$ROOT/runtime"
TOKDIR=/etc/cl-egress; TOKFILE="$TOKDIR/$U.token"
AGENT_IDENT="$U-bot"
STAMP_FILE=/home/$U/work/.m3-backup-path
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

say "1) backup live state (rollback point)"
# IMPORTANT: write the archive OUTSIDE the trees being archived. ~/work is one of
# the archived trees, so a backup under ~/work/ would self-include (tar 'file
# changed as we read it' -> inflated, unreliable archive). Use a sibling dir.
BK="/home/$U/m3-backups"
mkdir -p "$BK"
OUT="$BK/backup.tar.gz"
# Exclude volatile sockets so tar doesn't warn/fail on them.
tar --warning=no-file-changed \
    --exclude='.claude/tmux-*' --exclude='*/.git/objects' \
    -czf "$OUT" -C "/home/$U" .claude work
rc=$?
[ "$rc" -le 1 ] || { echo "  ✗ backup tar failed (rc=$rc)"; exit 1; }   # tar rc=1 = harmless warnings
chown -R "$U:$U" "$BK"
ls -lh "$OUT" | sed 's/^/  /'
echo "$OUT" > "$STAMP_FILE"; chown "$U:$U" "$STAMP_FILE"
echo "  backup written to $OUT (outside archived trees)"

say "2) install runtime unit + wrapper (NO start)"
install -m 0755 "$RT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
install -m 0644 "$RT/systemd/claude-pod@.service" /etc/systemd/system/claude-pod@.service
systemctl daemon-reload
echo "  installed claude-pod@.service + claude-pod-run (pod NOT enabled/started)"

if [ "${SKIP_TOKEN:-0}" = 1 ]; then
  say "3) SKIPPED OneCLI token (SKIP_TOKEN=1) — safe steps done"
  exit 0
fi

say "3) OneCLI proxy token for container egress -> $TOKFILE  (REUSE host token, NO regenerate)"
# SAFE default: the live host bot authenticates to the OneCLI proxy with a token
# embedded in its HTTPS_PROXY (http://<token>@127.0.0.1:10255). Regenerating the
# <user>-bot agent token would rotate THAT out from under the live bot and break
# its egress. So we REUSE the exact same token for the container (same agent
# identity, no rotation, rollback-safe). Token is piped straight to the file,
# never printed.
mkdir -p "$TOKDIR"; chmod 0700 "$TOKDIR"
HPID="$(cat /home/$U/.claude/channels/telegram-$U/bot.pid 2>/dev/null)"
[ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null || { echo "host poller not running — cannot read its proxy token; aborting (start claude-tg@$U first)"; exit 1; }
umask 077
# Extract the userinfo between '://' and '@' from the host poller's HTTPS_PROXY,
# strip the leading 'x:' (OneCLI convention: user 'x', password = token).
USERINFO="$(tr '\0' '\n' < "/proc/$HPID/environ" 2>/dev/null | sed -n 's#^HTTPS_PROXY=http://\([^@]*\)@.*#\1#p' | head -1)"
PXTOKEN="${USERINFO#x:}"
if [ -n "$PXTOKEN" ]; then
  printf '%s' "$PXTOKEN" > "$TOKFILE"; chmod 0600 "$TOKFILE"; unset PXTOKEN USERINFO
  echo "  wrote $TOKFILE ($(stat -c%s "$TOKFILE") bytes) — reused host bot's OneCLI token (no regenerate)"
else
  echo "  ✗ could not extract host proxy token — leave the token step to operator review"; exit 1
fi
say "PREP DONE — pod NOT started. Next: DRYRUN=1 m3-cutover.sh to confirm green, then the real cutover."
