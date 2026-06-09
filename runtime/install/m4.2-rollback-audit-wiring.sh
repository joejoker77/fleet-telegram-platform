#!/usr/bin/env bash
# m4.2-rollback-audit-wiring.sh — one-command revert of m4.2-apply-audit-wiring.sh.
# Restores the most recent pre-apply backup of the wrapper + settings.json and
# restarts the pod. Operator-run from the HOST as root.
set -euo pipefail

U=vitaliy
# Derive the wrapper path from the unit's ExecStart (single source of truth),
# matching the apply script; fall back to the canonical sbin path.
WRAPPER_DST="$(systemctl cat claude-pod@.service 2>/dev/null \
  | sed -n 's#^ExecStart=\(/[^ ]*claude-pod-run\).*#\1#p' | head -n1)"
[ -n "$WRAPPER_DST" ] || WRAPPER_DST=/usr/local/sbin/claude-pod-run
SETTINGS="/home/$U/.claude/settings.json"
BKROOT="/home/$U/m4.2-backups"

log(){ printf '\n[m4.2-rollback] %s\n' "$*"; }
die(){ printf '\n[m4.2-rollback][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "running INSIDE a container — run on the HOST"
[ -d "$BKROOT" ] || die "no backups under $BKROOT — nothing to roll back"

BK="${1:-$(ls -1d "$BKROOT"/*/ 2>/dev/null | sort | tail -n1)}"
BK="${BK%/}"
[ -d "$BK" ] || die "backup dir not found: $BK"
log "restoring from $BK"

if [ -f "$BK/claude-pod-run" ]; then
  install -m 0755 "$BK/claude-pod-run" "$WRAPPER_DST"
  echo "  restored $WRAPPER_DST"
else
  echo "  (no wrapper backup — leaving $WRAPPER_DST as-is)"
fi

if [ -f "$BK/settings.json" ]; then
  cp -a "$BK/settings.json" "$SETTINGS"
  echo "  restored $SETTINGS"
else
  echo "  (no settings backup — leaving $SETTINGS as-is)"
fi

log "restart claude-pod@$U"
systemctl restart "claude-pod@$U"
echo "  done — pod restarted on the pre-m4.2 wrapper + settings."
echo "  (the audit mount is conditional, so even without rollback the pod is safe;"
echo "   this restores the exact prior state.)"
