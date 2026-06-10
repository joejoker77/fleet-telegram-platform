#!/usr/bin/env bash
# DEPRECATED 2026-06-10 (ADR-004, decision a): deploy-time skill gating removed.
# Use m4-revert-deploy-gates.sh. fleet-skill-gate's scan logic is reused at M5.
# M4.5 (WP4 L5) — install the skill install gate: the fleet-skill-gate helper +
# the deploy-skills v2 that calls it before rsyncing each allowed skill.
# Pilot-scoped (gate only runs for vitaliy; other bots unchanged). Run as root.
# Rollback: restore /root/deploy-skills.v1.bak → /usr/local/sbin/deploy-skills
# and rm /usr/local/sbin/fleet-skill-gate.
set -euo pipefail
SRC=/home/vitaliy/work/fleet-platform/control-plane/install
log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
curl -sf http://127.0.0.1:8090/healthz >/dev/null 2>&1 || echo "WARN: cp-judge not up — gate will return UNAVAIL (skills kept as-is) until it is"

log "installing fleet-skill-gate helper"
install -m 0755 "$SRC/fleet-skill-gate" /usr/local/sbin/fleet-skill-gate

log "backing up + installing deploy-skills v2"
if [ -f /usr/local/sbin/deploy-skills ] && [ ! -f /root/deploy-skills.v1.bak ]; then
  cp /usr/local/sbin/deploy-skills /root/deploy-skills.v1.bak
  echo "  backed up current deploy-skills → /root/deploy-skills.v1.bak"
fi
install -m 0755 "$SRC/deploy-skills.v2" /usr/local/sbin/deploy-skills

log "running deploy-skills vitaliy (gate active)"
deploy-skills vitaliy || true
echo
echo "tail of /var/log/skill-deploy/vitaliy.log:"
tail -n 20 /var/log/skill-deploy/vitaliy.log 2>/dev/null | sed 's/^/  /'
echo
echo "✅ M4.5 skill gate installed. Look for 'GATE PASS skill <name>' lines above."
echo "   Rollback: cp /root/deploy-skills.v1.bak /usr/local/sbin/deploy-skills"
