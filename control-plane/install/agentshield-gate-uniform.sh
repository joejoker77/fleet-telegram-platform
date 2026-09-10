#!/usr/bin/env bash
# Make every tenant run the CANONICAL agentshield-gate.
#
# Why this exists (2026-09-10): vitaliy had a per-instance drop-in from
# 2026-05-29 — /etc/systemd/system/agentshield-gate@vitaliy.service.d/override.conf —
# routing ExecStart to /usr/local/bin/agentshield-gate-experimental, a snapshot of
# the canonical script taken that day. Its only purpose was an auto-revert fix
# (`git checkout HEAD -- settings.json` instead of `git revert HEAD`), and that
# whole auto-rollback branch was REMOVED from canonical on 2026-08-25 by operator
# decision. So the drop-in outlived its reason and quietly froze one tenant on
# 3.5-month-old gate logic: it lacked the docs-example filter, the *.md filter and
# the marketplace-catalogue filter, and therefore alerted 8 findings every 15 min
# where canonical alerts 2. Fixes shipped to the canonical script had no effect on
# that tenant, which is exactly the failure mode that wasted an afternoon.
#
# Lesson encoded here: a per-tenant unit override is invisible from the script you
# are editing. If we ever need one again, it belongs in git with an expiry, and
# this script is where the drift gets swept.
#
# Idempotent. Safe to re-run. Does NOT rebaseline (that is a deliberate step —
# see /usr/local/sbin/agentshield-rebaseline).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/agentshield-gate"
DEST=/usr/local/bin/agentshield-gate

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

if ! cmp -s "$SRC" "$DEST"; then
  cp -a "$DEST" "$DEST.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  install -m 0755 "$SRC" "$DEST"
  echo "installed canonical gate -> $DEST"
else
  echo "canonical gate already current"
fi

swept=0
for d in /etc/systemd/system/agentshield-gate@*.service.d; do
  [ -d "$d" ] || continue
  if grep -rqs "^ExecStart=" "$d" && ! grep -rqs "^ExecStart=$DEST" "$d"; then
    mkdir -p /var/lib/agentshield/removed-dropins
    cp -a "$d" "/var/lib/agentshield/removed-dropins/$(basename "$d").bak-$(date +%Y%m%d)" 2>/dev/null || true
    rm -rf "$d"
    echo "removed off-canonical ExecStart drop-in: $d (backed up)"
    swept=1
  fi
done
[ "$swept" -eq 1 ] && systemctl daemon-reload

echo
echo "resolved ExecStart per tenant:"
for u in $(ls /var/lib/agentshield/baselines/*.json 2>/dev/null | xargs -r -n1 basename | sed 's/\.json$//'); do
  case "$u" in *.bak*) continue;; esac
  printf '  %-12s %s\n' "$u" \
    "$(systemctl show -p ExecStart "agentshield-gate@$u.service" 2>/dev/null | sed -n 's/.*path=\([^ ]*\).*/\1/p' | head -1)"
done
