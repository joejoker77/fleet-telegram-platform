#!/usr/bin/env bash
# Install (or remove) the admin graceful-restart-pod-bot helper on the host.
#   graceful-restart-pod-bot-install.sh apply     # install to /usr/local/sbin
#   graceful-restart-pod-bot-install.sh rollback  # remove it + its state/logs
# Run as root (via host-sudo). Idempotent.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/graceful-restart-pod-bot"
DST=/usr/local/sbin/graceful-restart-pod-bot

case "${1:-apply}" in
  apply)
    [ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }
    install -m 0755 "$SRC" "$DST"
    echo "installed $DST"
    "$DST" --help | head -1
    ;;
  rollback)
    rm -f "$DST"
    rm -rf /run/graceful-restart-pod-bot /var/log/graceful-restart-pod-bot
    echo "removed $DST + state/log dirs"
    ;;
  *)
    echo "usage: $0 apply|rollback" >&2; exit 1 ;;
esac
