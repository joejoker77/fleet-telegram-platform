#!/usr/bin/env bash
# verify.sh — check the M0 exit criteria. Safe to run as any user (read-only),
# though some `systemctl show` fields are richer as root. Exits non-zero if any
# check fails.
set -uo pipefail
fail=0
ok(){ printf '  \033[32mOK\033[0m  %s\n' "$1"; }
no(){ printf '  \033[31mXX\033[0m  %s\n' "$1"; fail=1; }

echo "== watchdog timer active =="
if systemctl is-active --quiet claude-tg-watchdog.timer; then ok "claude-tg-watchdog.timer active"; else no "watchdog timer not active"; fi
[ -x /usr/local/sbin/claude-tg-watchdog ] && ok "watchdog script installed" || no "watchdog script missing"

echo "== memory caps applied (per running bot) =="
for u in $(systemctl list-units --type=service --state=active --no-legend 'claude-tg@*' | awk '{print $1}'); do
  mx=$(systemctl show "$u" -p MemoryMax --value 2>/dev/null)
  if [ "$mx" != "infinity" ] && [ -n "$mx" ]; then ok "$u MemoryMax=$mx"; else no "$u has no MemoryMax (restart it to pick up drop-in)"; fi
done

echo "== crashtail wired =="
grep -q claude-tg-crashtail /etc/systemd/system/claude-tg@.service.d/30-crashtail.conf 2>/dev/null \
  && [ -x /usr/local/sbin/claude-tg-crashtail ] && ok "crashtail drop-in + script present" || no "crashtail not fully installed"

echo "== nested-claude guard present =="
[ -x /usr/local/share/claude-guard/block-nested-claude.py ] && ok "guard script installed" || no "guard script missing"
[ -x /usr/local/bin/claude-sub ] && ok "claude-sub on PATH" || no "claude-sub missing"
echo "  (guard WIRED only if each bot's settings.json references it — check manually)"

echo "== journald persistent =="
[ -d /var/log/journal ] && ok "/var/log/journal present" || no "journald is volatile"

[ "$fail" -eq 0 ] && echo "ALL M0 CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
