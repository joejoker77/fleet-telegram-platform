#!/usr/bin/env bash
# m9.1-dbread-gateway-rollback.sh — remove the read-only DB gateway completely.
# Reverses m9.1-dbread-gateway.sh: container, forwarder unit, the scoped nft/ufw hole,
# every tenant token, and the stored password. Tolerates anything already absent.
#
#   sudo bash m9.1-dbread-gateway-rollback.sh [--keep-password]
set -uo pipefail
KEEP_PW=0; [ "${1:-}" = "--keep-password" ] && KEEP_PW=1
POD_PORT=10256
PW_SECRET=cp_dbread_password
STATE_DIR=/etc/claudeapp/dbread
FWD_UNIT=/etc/systemd/system/cl-dbread-forwarder.service
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMPL="$(cd "$HERE/../.." && pwd)/runtime/nftables/cl-egress.nft.tmpl"

log(){ printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

log "1) container"
podman rm -f cp-dbread >/dev/null 2>&1 && echo "  removed cp-dbread" || echo "  (cp-dbread absent)"

log "2) forwarder"
systemctl disable --now cl-dbread-forwarder >/dev/null 2>&1 || true
rm -f "$FWD_UNIT"; systemctl daemon-reload 2>/dev/null || true
echo "  cl-dbread-forwarder removed"

log "3) perimeter hole (nft + ufw + template)"
# Delete every matching rule by handle, so re-running is safe.
while read -r h; do
  [ -n "$h" ] || continue
  nft delete rule inet cl_egress input handle "$h" 2>/dev/null && echo "  deleted nft rule handle $h"
done < <(nft -a list chain inet cl_egress input 2>/dev/null | awk -v p="dport $POD_PORT" '$0 ~ p {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
ufw status >/dev/null 2>&1 && { ufw delete allow from any to any port "$POD_PORT" proto tcp >/dev/null 2>&1 || true; }
[ -f "$TMPL" ] && sed -i "/tcp dport $POD_PORT counter accept/d" "$TMPL" && echo "  template line removed"

log "4) tenant tokens"
if [ -f "$STATE_DIR/tokens.json" ]; then
  python3 - "$STATE_DIR/tokens.json" <<'PY' | while read -r u; do
import json, sys
try: print("\n".join(sorted(set(json.load(open(sys.argv[1])).values()))))
except Exception: pass
PY
    [ -n "$u" ] || continue
    rm -f "/home/$u/.claude/dbread.token" && echo "  cleared token for $u"
  done
fi
rm -rf "$STATE_DIR"; echo "  removed $STATE_DIR"

log "5) stored password"
if [ "$KEEP_PW" = 1 ]; then
  echo "  keeping podman secret $PW_SECRET (--keep-password)"
else
  podman secret rm "$PW_SECRET" >/dev/null 2>&1 && echo "  removed podman secret $PW_SECRET" \
    || echo "  ($PW_SECRET absent)"
fi

echo
echo "== rollback DONE — no gateway, no tokens, perimeter back to proxy-only =="
