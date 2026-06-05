#!/usr/bin/env bash
# apply.sh — install the M0 stabilization artifacts. RUN AS ROOT on the live
# server. Idempotent: re-running is safe. Does NOT touch any bot's settings.json
# (AgentShield-protected) — that one step is printed at the end for the operator
# to do by hand.
#
#   sudo ./apply.sh
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

echo "== 1/5 resource + crashtail drop-ins =="
install -d -m 0755 /etc/systemd/system/claude-tg@.service.d
install -m 0644 "$HERE/systemd/claude-tg@.service.d/20-resources.conf" \
                /etc/systemd/system/claude-tg@.service.d/20-resources.conf
install -m 0644 "$HERE/systemd/claude-tg@.service.d/30-crashtail.conf" \
                /etc/systemd/system/claude-tg@.service.d/30-crashtail.conf

echo "== 2/5 watchdog + crashtail scripts =="
install -m 0755 "$HERE/bin/claude-tg-watchdog"  /usr/local/sbin/claude-tg-watchdog
install -m 0755 "$HERE/bin/claude-tg-crashtail" /usr/local/sbin/claude-tg-crashtail

echo "== 3/5 watchdog timer =="
install -m 0644 "$HERE/systemd/claude-tg-watchdog.service" /etc/systemd/system/claude-tg-watchdog.service
install -m 0644 "$HERE/systemd/claude-tg-watchdog.timer"   /etc/systemd/system/claude-tg-watchdog.timer

echo "== 4/5 nested-claude guard (shared copy; wiring is manual, see below) =="
install -d -m 0755 /usr/local/share/claude-guard
install -m 0755 "$HERE/nested-claude-guard/block-nested-claude.py" /usr/local/share/claude-guard/block-nested-claude.py
install -m 0644 "$HERE/nested-claude-guard/empty-mcp.json"         /usr/local/share/claude-guard/empty-mcp.json
install -m 0755 "$HERE/nested-claude-guard/claude-sub"            /usr/local/bin/claude-sub
# claude-sub looks for empty-mcp.json next to itself:
install -m 0644 "$HERE/nested-claude-guard/empty-mcp.json"        /usr/local/bin/empty-mcp.json

echo "== 5/5 reload + enable watchdog (does NOT restart any bot) =="
systemctl daemon-reload
systemctl enable --now claude-tg-watchdog.timer

cat <<'EOF'

DONE (no bots were restarted).

The resource/crashtail drop-ins take effect on each bot's NEXT restart. To apply
now without waiting, restart bots one at a time during idle, e.g.:
    graceful-restart-bot vitaliy

MANUAL STEP (AgentShield-protected, operator only):
Wire the nested-claude guard into each bot's ~/.claude/settings.json by merging
nested-claude-guard/settings-hook-snippet.json into .hooks.PreToolUse (matcher
"Bash"). Self-writing it from a bot gets rolled back, so do it as operator.
EOF
