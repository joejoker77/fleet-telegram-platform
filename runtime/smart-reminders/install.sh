#!/usr/bin/env bash
# Install (or remove) the smart-reminders service on this host.
#
#   install.sh             put the files in /opt, install the unit, start it
#   install.sh --rollback  stop and remove the unit (files, config and state stay)
#
# Deployed by hand on 2026-10-05 and therefore absent from a fresh host until now.
# Per-tenant files (`remind` + the skill) are NOT placed here: add-user.sh runs
# `rollout.py <user>` for each tenant, which is idempotent and the only path.
#
# The creation-time safety check calls OpenRouter, so the unit loads a credential from
# /etc/credstore/smart-reminders-openrouter.key. systemd refuses to start a unit whose
# LoadCredential source is missing, so when that file is absent this installs everything
# and leaves the service stopped, saying exactly what is missing — rather than enabling a
# unit that would crash-loop. (Firm rule: that key is used when a person creates a
# reminder, never on a timer.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/smart-reminders
UNIT=/etc/systemd/system/smart-reminders.service
KEY=/etc/credstore/smart-reminders-openrouter.key
CONF=/etc/smart-reminders.json

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }

if [ "${1:-}" = "--rollback" ]; then
  systemctl disable --now smart-reminders.service 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  echo "smart-reminders unit removed ($DEST, $CONF and the stores are kept)"
  exit 0
fi

install -d -m 0755 "$DEST"
for f in smart_reminders.py rollout.py patch_daily_report.py; do
  install -m 0755 "$HERE/$f" "$DEST/$f"
done
for f in config.example.json HANDOVER.md ANNOUNCEMENT.md smart-reminders.service; do
  [ -f "$HERE/$f" ] && install -m 0644 "$HERE/$f" "$DEST/$f"
done
# tenant/ holds the canonical `remind` client and the skill the rollout copies out.
install -d -m 0755 "$DEST/tenant"
find "$HERE/tenant" -maxdepth 1 -type f ! -name '*.pyc' -print0 |
  while IFS= read -r -d '' f; do
    case "$(basename "$f")" in
      remind) install -m 0755 "$f" "$DEST/tenant/$(basename "$f")" ;;
      *)      install -m 0644 "$f" "$DEST/tenant/$(basename "$f")" ;;
    esac
  done
install -m 0644 "$HERE/smart-reminders.service" "$UNIT"
systemctl daemon-reload

if [ ! -f "$CONF" ]; then
  install -m 0600 "$HERE/config.example.json" "$CONF"
  echo "wrote $CONF from the example — fill in the chat ids and approvers before relying on it"
fi

if [ -s "$KEY" ]; then
  systemctl enable --now smart-reminders.service
  echo "smart-reminders running: $(systemctl is-active smart-reminders.service)"
else
  systemctl enable smart-reminders.service >/dev/null
  echo "installed, NOT started: $KEY is missing."
  echo "  It is the OpenRouter key for the creation-time safety check (keep a low spend cap)."
  echo "  Write it root-only, then: systemctl start smart-reminders"
fi
