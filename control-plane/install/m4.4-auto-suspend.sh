#!/usr/bin/env bash
# M4.4 (WP6) — install the auto-suspend abuse monitor + notifier reuse.
# Deterministic (NOT an LLM): a 5-min timer counts repeated-malicious signals
# (settings tamper "RESTORED" + content "REGRESSION") per tenant from the
# agentshield log; on threshold it alerts the admin (existing security-alerter)
# and — when ENFORCE=1 — `podman pause`s the pod + marks status=suspended.
#
# DEFAULT ENFORCE=0 (alert-only) so install/testing can't freeze the pilot bot's
# own pod. Flip /etc/agentshield/autosuspend.conf ENFORCE=1 + daemon-reload to arm.
# Resume an enforced suspend with: tenant-resume <user>.
#
# Run as root. Idempotent. Pilot: vitaliy only. Rollback: m4.4-auto-suspend-rollback.sh
set -euo pipefail

SRC=/home/vitaliy/work/fleet-platform/control-plane/install
USERS=("vitaliy")

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

log "installing monitor + resume binaries"
install -m 0755 "$SRC/auto-suspend-monitor" /usr/local/sbin/auto-suspend-monitor
install -m 0755 "$SRC/tenant-resume"        /usr/local/sbin/tenant-resume

log "installing units + default config"
install -m 0644 "$SRC/auto-suspend-monitor@.service" /etc/systemd/system/auto-suspend-monitor@.service
install -m 0644 "$SRC/auto-suspend-monitor@.timer"   /etc/systemd/system/auto-suspend-monitor@.timer
install -d -m 0755 /etc/agentshield
if [ ! -f /etc/agentshield/autosuspend.conf ]; then
  install -m 0644 "$SRC/autosuspend.conf" /etc/agentshield/autosuspend.conf
  echo "  installed default autosuspend.conf (ENFORCE=0 alert-only)"
else
  echo "  keeping existing /etc/agentshield/autosuspend.conf"
fi

systemctl daemon-reload
for u in "${USERS[@]}"; do
  systemctl enable --now "auto-suspend-monitor@$u.timer"
  systemctl is-active "auto-suspend-monitor@$u.timer" >/dev/null && echo "  timer active for $u" || die "timer not active for $u"
done

echo
echo "✅ M4.4 auto-suspend installed for: ${USERS[*]} (ENFORCE=$(. /etc/agentshield/autosuspend.conf 2>/dev/null; echo "${ENFORCE:-0}"))"
echo "   Validate detection (alert-only, no freeze): bash $SRC/m4.4-accept.sh vitaliy"
echo "   Arm enforcement: set ENFORCE=1 in /etc/agentshield/autosuspend.conf && systemctl daemon-reload"
