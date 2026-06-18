#!/usr/bin/env bash
# M5.5b — install the cp-secretd privileged helper (Mini App secret intake →
# OneCLI vault; docs/M5.5b-secret-intake-design.md). Run as root. Idempotent.
#
# What it installs (all reverted by m5.5b-secretd-rollback.sh — ONE command):
#   /usr/local/sbin/cp-secretd            the helper (python3, single-shot)
#   /etc/systemd/system/cp-secretd.socket socket activation (Accept=yes)
#   /etc/systemd/system/cp-secretd@.service
#   /etc/tmpfiles.d/cp-secretd.conf       /run/cp-secretd across reboots
#   group cp-secret                       socket group (root-owned 0660)
#
# No timers, no recurring anything, ZERO LLM calls. The helper runs only when
# cp-api connects (user-triggered MCP connect with a secret).
# The helper itself is platform-wide; the per-tenant agent check + smoke test
# are scoped to the bootstrap tenant (if any). DEV artifact → project_fleet_dev_teardown.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
RT="$ROOT/runtime"
ONECLI=/usr/local/bin/onecli
SOCK_DIR=/run/cp-secretd
# Per-tenant scope: bootstrap admin tenant (if any). Empty on greenfield install.
TENANT="${BOOTSTRAP_ADMIN_USER:-}"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# ---- preflight ---------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 missing"
command -v "$ONECLI" >/dev/null 2>&1 || die "onecli not found at $ONECLI"
export HOME=/root  # onecli reads its API key from $HOME (incident 2026-05-29)
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated (run 'onecli auth login' as root)"

log "verifying onecli CLI surface (flags this helper relies on)"
HELP="$("$ONECLI" secrets create --help 2>&1 || true)"
for flag in --name --value --host-pattern --header-name --value-format; do
  echo "$HELP" | grep -q -- "$flag" || die "onecli secrets create lacks '$flag' — CLI changed; adjust cp-secretd.py"
done
"$ONECLI" agents list >/dev/null 2>&1 || die "onecli agents list failed"
if [ -n "$TENANT" ]; then
  AID="$("$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
ident=sys.argv[1]
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')==ident),''))" "$TENANT-bot")"
  [ -n "$AID" ] || die "agent $TENANT-bot not provisioned (m2.4)"
  echo "agent $TENANT-bot uuid=$AID"
else
  echo "no tenant set (BOOTSTRAP_ADMIN_USER empty) — skipping per-tenant agent check"
fi

# ---- group + runtime dir -----------------------------------------------------
log "group + socket dir"
getent group cp-secret >/dev/null 2>&1 || groupadd --system cp-secret
printf 'd %s 0750 root cp-secret -\n' "$SOCK_DIR" > /etc/tmpfiles.d/cp-secretd.conf
systemd-tmpfiles --create /etc/tmpfiles.d/cp-secretd.conf
[ -d "$SOCK_DIR" ] || die "$SOCK_DIR not created"

# ---- audit socket path (defense-in-depth duplicate of cp-api's own audit) ----
AUDIT_SOCK=""
if podman volume exists cp-audit-run >/dev/null 2>&1; then
  AUDIT_SOCK="$(podman volume inspect cp-audit-run --format '{{.Mountpoint}}')/collector.sock"
  echo "audit sock: $AUDIT_SOCK"
else
  echo "note: cp-audit-run volume missing — helper audit duplicate disabled"
fi

# ---- helper + units ----------------------------------------------------------
log "installing helper + units"
install -m 0755 "$RT/secretd/cp-secretd.py" /usr/local/sbin/cp-secretd
install -m 0644 "$RT/systemd/cp-secretd.socket" /etc/systemd/system/cp-secretd.socket
install -m 0644 "$RT/systemd/cp-secretd@.service" /etc/systemd/system/cp-secretd@.service
if [ -n "$AUDIT_SOCK" ]; then
  mkdir -p /etc/systemd/system/cp-secretd@.service.d
  printf '[Service]\nEnvironment=AUDIT_SOCK=%s\n' "$AUDIT_SOCK" \
    > /etc/systemd/system/cp-secretd@.service.d/audit.conf
fi
systemctl daemon-reload
systemctl enable --now cp-secretd.socket
systemctl is-active cp-secretd.socket >/dev/null || die "socket not active"

# ---- smoke: a malformed-name request must be refused --------------------------
log "smoke test (bad name → refusal; good exists-check → ok)"
smoke() { python3 - "$SOCK_DIR/secretd.sock" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode()); s.shutdown(socket.SHUT_WR)
buf = b""
while True:
    c = s.recv(4096)
    if not c: break
    buf += c
print(buf.decode().strip())
PY
}
SMOKE1="$(smoke '{"verb":"secret_exists","name":"evil-name"}' || true)"
echo "  bad name  -> $SMOKE1"
echo "$SMOKE1" | grep -q '"ok": false' || die "helper accepted a non-convention name"
if [ -n "$TENANT" ]; then
  SMOKE2="$(smoke "{\"verb\":\"secret_exists\",\"name\":\"$TENANT-mcp-smoketest\"}" || true)"
  echo "  good name -> $SMOKE2"
  echo "$SMOKE2" | grep -q '"ok": true' || die "helper failed a valid secret_exists (onecli reachable?)"
else
  echo "  good name -> skipped (no tenant set; per-tenant convention check runs at add-user time)"
fi

log "DONE"
echo "socket: $SOCK_DIR/secretd.sock (root:cp-secret 0660)"
echo "next: re-run control-plane/install/m1.5-services.sh so cp-api mounts $SOCK_DIR"
echo "rollback: bash $RT/install/m5.5b-secretd-rollback.sh"
