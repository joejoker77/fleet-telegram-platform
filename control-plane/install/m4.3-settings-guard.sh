#!/usr/bin/env bash
# M4.3 (WP7) — install the real-time settings.json integrity guard (ADR-003).
# Closes M4 criterion #2 ("the tenant cannot disable the platform hooks/deny-list")
# with a fast, root-owned mechanism the existing 15-min agentshield-gate did NOT
# provide (that one only auto-reverts on NEW high/critical SCANNER findings — a
# removed deny rule / disabled hook is not a finding, so it was never restored).
#
# What it installs (PILOT: vitaliy only — only that .path unit is enabled):
#   /usr/local/sbin/agentshield-settings-guard        (root, the enforcer)
#   /usr/local/sbin/agentshield-settings-rebaseline   (root, adopt a new baseline)
#   /etc/systemd/system/agentshield-settings-guard@.{path,service}
#   /var/lib/agentshield/golden/<user>.settings.json  (root-owned baseline)
#
# Enforces only the SECURITY subset (permissions + hooks) from the golden; passes
# mcpServers / enabledMcpjsonServers / model / etc. through, so deploy-mcp and
# Claude Code's own legit writes are untouched.
#
# Run as root. Idempotent. Rollback: m4.3-settings-guard-rollback.sh.
set -euo pipefail

SRC=/home/vitaliy/work/fleet-platform/control-plane/install
USERS=("vitaliy")   # pilot scope

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

log "installing guard + rebaseline binaries"
install -m 0755 "$SRC/agentshield-settings-guard"      /usr/local/sbin/agentshield-settings-guard
install -m 0755 "$SRC/agentshield-settings-rebaseline" /usr/local/sbin/agentshield-settings-rebaseline

log "installing systemd units"
install -m 0644 "$SRC/agentshield-settings-guard@.path"    /etc/systemd/system/agentshield-settings-guard@.path
install -m 0644 "$SRC/agentshield-settings-guard@.service" /etc/systemd/system/agentshield-settings-guard@.service

install -d -m 0700 /var/lib/agentshield/golden
install -d -m 0755 /var/log/agentshield
install -d -m 0755 /etc/agentshield

systemctl daemon-reload

for u in "${USERS[@]}"; do
  [ -f "/home/$u/.claude/settings.json" ] || { echo "skip $u: no settings.json"; continue; }
  log "baselining + enabling guard for $u"
  /usr/local/sbin/agentshield-settings-rebaseline "$u"
  systemctl enable --now "agentshield-settings-guard@$u.path"
  systemctl is-active "agentshield-settings-guard@$u.path" >/dev/null && echo "  guard .path active for $u" || die "guard .path not active for $u"
done

echo
echo "✅ M4.3 settings-guard installed for: ${USERS[*]}"
echo "   Verify with: bash $SRC/m4.3-tamper-test.sh vitaliy   (expect ✅ PASS now)"
echo "   Authorized edits: touch /etc/agentshield/operator-override.flag; edit; agentshield-settings-rebaseline <user>; rm flag"
