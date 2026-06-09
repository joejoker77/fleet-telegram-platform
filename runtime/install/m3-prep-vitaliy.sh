#!/usr/bin/env bash
# M3.1 — SAFE pre-cutover prep for vitaliy. NO live impact: it never starts the
# container pod and never touches the running claude-tg@vitaliy. Idempotent.
#
#   sudo bash m3-prep-vitaliy.sh
#
# Does three things:
#   1. Full backup of /home/vitaliy/.claude + ~/work  -> independent rollback point.
#   2. Install the runtime unit + wrapper (file install only; pod NOT enabled/started).
#   3. Provision the OneCLI proxy token /etc/cl-egress/vitaliy.token for container egress.
#
# ⚠️ Step 3 calls `onecli agents regenerate-token` for the vitaliy-bot agent.
# DO NOT RUN until we've confirmed the live host bot does not depend on that
# token (see SKIP_TOKEN below). Run `SKIP_TOKEN=1 sudo bash m3-prep-vitaliy.sh`
# to do only the safe steps (1+2) first.
set -uo pipefail
U=vitaliy
RT=/home/vitaliy/work/fleet-platform/runtime
TOKDIR=/etc/cl-egress; TOKFILE="$TOKDIR/$U.token"
AGENT_IDENT="$U-bot"
STAMP_FILE=/home/$U/work/.m3-backup-path
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

say "1) backup live state (rollback point)"
BK="/home/$U/work/backups/m3-pre-cutover"   # operator may pass an existing timestamp dir
mkdir -p "$BK"
# tar both trees; exclude nothing — this is the integrity anchor.
OUT="$BK/backup.tar.zst"
tar --zstd -cf "$OUT" -C "/home/$U" .claude work 2>/dev/null \
  || tar -czf "${OUT%.zst}.gz" -C "/home/$U" .claude work
ls -lh "$BK"/backup.* | sed 's/^/  /'
echo "$BK" > "$STAMP_FILE"; chown "$U:$U" "$STAMP_FILE"
echo "  backup written under $BK"

say "2) install runtime unit + wrapper (NO start)"
install -m 0755 "$RT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
install -m 0644 "$RT/systemd/claude-pod@.service" /etc/systemd/system/claude-pod@.service
systemctl daemon-reload
echo "  installed claude-pod@.service + claude-pod-run (pod NOT enabled/started)"

if [ "${SKIP_TOKEN:-0}" = 1 ]; then
  say "3) SKIPPED OneCLI token (SKIP_TOKEN=1) — safe steps done"
  exit 0
fi

say "3) OneCLI proxy token for container egress -> $TOKFILE"
export HOME=/root
command -v onecli >/dev/null 2>&1 && onecli auth status >/dev/null 2>&1 || { echo "onecli not authenticated — aborting token step"; exit 1; }
mkdir -p "$TOKDIR"; chmod 0700 "$TOKDIR"
AID="$(onecli agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='${AGENT_IDENT}'),''))" 2>/dev/null || true)"
[ -n "$AID" ] || { echo "agent $AGENT_IDENT not found — operator must create it"; exit 1; }
onecli agents set-secret-mode --id "$AID" --mode selective >/dev/null
TOKEN="$(onecli agents regenerate-token --id "$AID" | python3 -c "import json,sys;d=json.load(sys.stdin);a=d.get('data',d) if isinstance(d,dict) else d;print(a.get('accessToken',''))")"
[ -n "$TOKEN" ] || { echo "no token returned"; exit 1; }
umask 077; printf '%s' "$TOKEN" > "$TOKFILE"; chmod 0600 "$TOKFILE"; unset TOKEN
echo "  wrote $TOKFILE ($(stat -c%s "$TOKFILE") bytes), agent=$AGENT_IDENT ($AID)"
say "PREP DONE — pod NOT started. Next: DRYRUN=1 m3-cutover.sh to confirm green, then the real cutover."
