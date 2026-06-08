#!/usr/bin/env bash
# M2.1 draft entrypoint for the user runtime container. Finalized at M2.2/M3
# (cutover), where the tmux+claude Telegram-plugin session and code-server are
# wired exactly like the current claude-tg launcher (no plugin patch) and the
# session is seeded/resumed from the tenant's existing logs.
#
# For M2.1 the image only needs to build and expose the toolchain; this script
# starts code-server and an idle tmux 'claude' session as a placeholder so the
# container is runnable, and logs a startup event to the audit socket if mounted.
set -euo pipefail

AUDIT_SOCK="${AUDIT_SOCKET:-/run/audit/collector.sock}"
USER_NAME="$(id -un)"

audit() {
  # best-effort: write one NDJSON line to the audit collector if the socket is mounted
  [ -S "$AUDIT_SOCK" ] || return 0
  printf '%s\n' "{\"userId\":null,\"kind\":\"runtime.start\",\"actor\":\"$USER_NAME\",\"payload\":{}}" \
    | timeout 2 socat - "UNIX-CONNECT:$AUDIT_SOCK" 2>/dev/null || true
}
audit

# code-server (web IDE) — bound to loopback; reverse-proxied by Caddy at M5.
if command -v code-server >/dev/null 2>&1; then
  code-server --bind-addr 127.0.0.1:8443 --auth none "$HOME/work" >/tmp/code-server.log 2>&1 &
fi

# Placeholder Claude session holder. M3 replaces this with the real
# tmux + claude + official Telegram plugin launch (seeded/resumed session).
tmux new-session -d -s claude "sleep infinity"
exec tail -f /dev/null
