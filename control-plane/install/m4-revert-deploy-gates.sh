#!/usr/bin/env bash
# Revert the (mis-placed) deploy-time gates — decision (a), 2026-06-10, per
# ADR-004. deploy-skills/deploy-mcp deploy CI-vetted content; re-judging there
# was redundant and caused false positives. The judge/scanner CAPABILITY stays
# (cp-judge + @fleet/scanners); its BLOCKING trigger + inline approval moves to
# the sharing/authoring boundary (M5). Containment guards (settings-guard / WP7,
# auto-suspend / WP6, egress, shellfirm) are UNCHANGED — they are boundary-1 and
# correct.
#
# Restores the canonical deploy scripts from the backups taken at install and
# re-runs them (this re-deploys skill-author-selftest, which the gate had pulled).
# Run as root.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

log() { printf '\n== %s ==\n' "$*"; }

# 1) deploy-skills → v1
if [ -f /root/deploy-skills.v1.bak ]; then
  log "restoring deploy-skills v1"
  install -m 0755 /root/deploy-skills.v1.bak /usr/local/sbin/deploy-skills
  echo "  restored /usr/local/sbin/deploy-skills from /root/deploy-skills.v1.bak"
else
  echo "WARN: /root/deploy-skills.v1.bak not found — deploy-skills left as-is"
fi

# 2) deploy-mcp → v2.3
if [ -f /root/deploy-mcp.v2.3.bak ]; then
  log "restoring deploy-mcp v2.3"
  install -m 0755 /root/deploy-mcp.v2.3.bak /usr/local/sbin/deploy-mcp
  echo "  restored /usr/local/sbin/deploy-mcp from /root/deploy-mcp.v2.3.bak"
else
  echo "WARN: /root/deploy-mcp.v2.3.bak not found — deploy-mcp left as-is"
fi

# 3) drop the unused exempt file (its concept is abandoned)
if [ -f /etc/agentshield/skill-gate-exempt ]; then
  rm -f /etc/agentshield/skill-gate-exempt
  echo "  removed /etc/agentshield/skill-gate-exempt (no longer used)"
fi

# 4) re-run both reconcilers (re-deploys anything the gate had blocked)
log "re-running deploy-skills vitaliy"
deploy-skills vitaliy || true
tail -n 8 /var/log/skill-deploy/vitaliy.log 2>/dev/null | sed 's/^/  /'

log "re-running deploy-mcp vitaliy"
deploy-mcp vitaliy || true
tail -n 6 /var/log/mcp-deploy/vitaliy.log 2>/dev/null | sed 's/^/  /'

echo
echo "✅ deploy-time gates reverted. cp-judge + @fleet/scanners remain installed (capability)."
echo "   Containment (settings-guard, auto-suspend, egress, shellfirm) is unchanged."
echo "   skill-author-selftest should be re-deployed in the skill-deploy log above."
