#!/usr/bin/env bash
# render-egress-nft.sh — regenerate /etc/cl-egress.nft from the template and apply it.
#
#   render-egress-nft.sh [--apply]      (default: render and diff only)
#
# WHY THIS HAS TO EXIST. Two installers (m9.1-dbread-gateway.sh, m8.2-chat-registry.sh)
# open a pod→host port with a runtime `nft insert` and then append the same line to
# runtime/nftables/cl-egress.nft.tmpl "for reboot persistence". That comment was wrong:
# nothing ever rendered the template. Boot runs `nft -f /etc/cl-egress.nft`, and that file
# — written once at install time, 2026-07-31 — starts with `delete table inet cl_egress`,
# so every runtime insert is wiped and only the ports IT lists come back.
#
# The 2026-09-07 reboot proved it. Three holes vanished silently:
#   * tcp/22    — the host-sudo broker, so every admin bot lost root access to the host
#   * tcp/10256 — the read-only DB gateway
#   * tcp/10257 — the skills marketplace listener
# and tcp/22 was never in the template either; it had only ever been inserted by hand.
#
# So: keep the template as the single source of the ruleset, render it here, and let boot
# apply the rendered copy. After running this, `nft -f /etc/cl-egress.nft` reproduces the
# full set instead of a subset.
set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMPL="$(cd "$HERE/.." && pwd)/nftables/cl-egress.nft.tmpl"
DEST=/etc/cl-egress.nft

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$TMPL" ] || die "template not found: $TMPL"
[ -f /etc/cl-egress.env ] || die "/etc/cl-egress.env missing"
# shellcheck disable=SC1091
. /etc/cl-egress.env
[ -n "${SUBNET:-}" ] && [ -n "${GW:-}" ] || die "SUBNET/GW not set"

tmp="$(mktemp)"
sed -e "s#__SUBNET__#$SUBNET#g" -e "s#__GW__#$GW#g" "$TMPL" > "$tmp"
/usr/sbin/nft -c -f "$tmp" || { rm -f "$tmp"; die "rendered ruleset does not parse — nothing changed"; }

log "ports the rendered ruleset opens from the pod subnet"
grep -o "dport [0-9]*" "$tmp" | sort -u | sed 's/^/  /'

log "diff against what boot currently applies"
if [ -f "$DEST" ]; then
  diff "$DEST" "$tmp" && echo "  (identical — nothing to do)" || true
else
  echo "  $DEST does not exist yet"
fi

if [ "$APPLY" = 0 ]; then
  echo
  echo "render-only. Re-run with --apply to install and load it."
  rm -f "$tmp"
  exit 0
fi

log "installing and loading"
[ -f "$DEST" ] && cp -a "$DEST" "$DEST.bak-$(date -u +%Y%m%d-%H%M%S)"
install -m 0644 "$tmp" "$DEST"
rm -f "$tmp"
/usr/sbin/nft -f "$DEST"
echo "  loaded"

log "live rules now"
/usr/sbin/nft list chain inet cl_egress input | sed -n '3,12p'
