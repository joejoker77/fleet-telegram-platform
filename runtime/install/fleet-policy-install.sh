#!/usr/bin/env bash
# Install / update the firm usage policy (fleet-policy.json) and everything that reads it.
# Idempotent. Run after every change to fleet-policy.json.
#
#   fleet-policy-install.sh                  install policy, tap, governor; show who needs a restart
#   fleet-policy-install.sh --restart        ...and gracefully restart the pods whose rollout changed
#
# What reads the policy, and when it takes effect:
#   context_window  fleet-governor re-reads it every poll          -> at once for tenants whose pod
#                   already has the tap; a pod gets the tap on its next start
#   subagent_model  claude-pod-run, at pod start                   -> next pod restart
#   effort_cap      claude-pod-run, at pod start                   -> next pod restart
# Rollback of everything: fleet-policy-rollback.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HERE/fleet-policy.json" || die "fleet-policy.json is not valid JSON"
python3 "$HERE/fleet-governor-test.py" | tail -1 | grep -q "FAILURES: 0" || die "fleet-governor tests fail — not installing"

install -d -m 0755 /etc/claudeapp /usr/local/lib/fleet /var/lib/fleet /var/lib/fleet/ctl
install -m 0644 "$HERE/fleet-policy.json" /etc/claudeapp/fleet-policy.json
install -m 0644 "$HERE/fleet-usage-tap.js" /usr/local/lib/fleet/fleet-usage-tap.js
install -d -m 0755 /usr/local/lib/fleet/bin
install -m 0755 "$HERE/fleet-bun-shim" /usr/local/lib/fleet/bin/bun
install -m 0755 "$HERE/fleet-governor.py" /usr/local/sbin/fleet-governor
install -m 0755 "$ROOT/systemd/claude-pod-run" /usr/local/sbin/claude-pod-run
install -m 0644 "$ROOT/systemd/fleet-governor.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable fleet-governor.service >/dev/null
systemctl restart fleet-governor.service

# The 2026-09-28 status-line governor is superseded; take it out if it is still here.
if [ -x /usr/local/sbin/compact-governor ] && [ -x "$HERE/compact-governor-rollback.sh" ]; then
  echo "removing the superseded compact-governor (status line + /autocompact typing)"
  "$HERE/compact-governor-rollback.sh" || echo "WARNING: compact-governor rollback reported a problem"
fi

echo "installed: policy, tap, bun shim, governor, claude-pod-run"
echo
echo "pods that need a restart to pick up their rollout:"
NEED=$(python3 - /etc/claudeapp/fleet-policy.json <<'PY'
import json, os, sys, subprocess
p = json.load(open(sys.argv[1]))
users = sorted(os.listdir("/etc/claude-role"))
def on(s, u):
    r = (p.get(s) or {}).get("rollout") or []
    return r == "all" or u in r
for u in users:
    want = on("context_window", u) or on("subagent_model", u) or on("effort_cap", u)
    if not want:
        continue
    env = subprocess.run(["podman", "inspect", f"claude-{u}", "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
                         capture_output=True, text=True).stdout
    has_tap = "BUN_OPTIONS=--preload" in env
    has_model = "CLAUDE_CODE_SUBAGENT_MODEL=" in env
    if (on("context_window", u) and not has_tap) or (on("subagent_model", u) and not has_model):
        print(u)
PY
)
[ -n "$NEED" ] && echo "$NEED" | sed 's/^/  /' || echo "  none"
if [ "${1:-}" = "--restart" ] && [ -n "$NEED" ]; then
  for u in $NEED; do /usr/local/sbin/graceful-restart-pod-bot "$u"; done
fi
echo
echo "governor log:  journalctl -u fleet-governor -f"
