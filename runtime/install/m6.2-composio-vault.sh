#!/usr/bin/env bash
# m6.2-composio-vault.sh — M6.2: stage the PLATFORM Composio API key in OneCLI
# vault so the pod's helpers (composio-connect / composio-session) and the
# composio MCP connection run key-less; the egress proxy injects `x-api-key`.
#
# TWO secrets from the SAME key value, because Composio serves us from two hosts:
#   * vitaliy-composio-api — host backend.composio.dev (REST: auth_configs,
#     connected_accounts/link, tool_router/session)
#   * vitaliy-composio-mcp — host mcp.composio.dev (tool-router MCP sessions
#     may land here; harmless if unused)
# Exact-host patterns (proven mechanism, git-PAT + m6.1 exa) — no wildcard
# experiments on the proxy.
#
# Same fail-safe pattern as m6.1-exa-vault.sh: preflight CLI flags, refuse
# double-create, additive bind with verify-after-set, pre-state for rollback.
# Rollback: m6.2-composio-vault-rollback.sh.
# Run as root on the host. Pilot: vitaliy only (M1+ rule).
set -euo pipefail

USER_NAME=vitaliy
AGENT_IDENT="${USER_NAME}-bot"
PRESTATE=/etc/cl-egress/${USER_NAME}-composio.prestate
ONECLI=/usr/local/bin/onecli
declare -A HOSTS=(
  ["${USER_NAME}-composio-api"]="backend.composio.dev"
  ["${USER_NAME}-composio-mcp"]="mcp.composio.dev"
)
HEADER_NAME="x-api-key"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v "$ONECLI" >/dev/null 2>&1 || die "onecli not found at $ONECLI"
export HOME=/root   # onecli reads its stored API key from $HOME (incident 2026-05-29)
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated (run 'onecli auth login' as root first)"

py_ids() { python3 -c '
import json,sys
d=json.load(sys.stdin); rows=d.get("data",d) if isinstance(d,dict) else d
print("\n".join(r if isinstance(r,str) else r.get("id","") for r in rows))'; }

secret_id_by_name() { "$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$1'),''))"; }

# ---- preflight: verify the CLI still has the flags we rely on --------------
log "verifying onecli secrets create flags"
HELP="$("$ONECLI" secrets create --help 2>&1 || true)"
for flag in --name --value --host-pattern --header-name --value-format; do
  echo "$HELP" | grep -q -- "$flag" \
    || die "onecli secrets create lacks '$flag' — CLI changed; adjust this script. Help was:
$HELP"
done

# ---- resolve agent uuid -----------------------------------------------------
log "resolving agent $AGENT_IDENT"
AID="$("$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='$AGENT_IDENT'),''))")"
[ -n "$AID" ] || die "agent $AGENT_IDENT not found"
echo "agent uuid=$AID"

# ---- refuse to double-create ------------------------------------------------
for name in "${!HOSTS[@]}"; do
  EXISTING="$(secret_id_by_name "$name")"
  [ -z "$EXISTING" ] || die "secret $name already exists (id=$EXISTING) — run m6.2-composio-vault-rollback.sh first to replace it"
done

# ---- read key, create both secrets ------------------------------------------
log "creating secrets"
printf 'Paste the PLATFORM Composio API key (hidden; the headers.x-api-key value from the prototype .mcp.json), then Enter: ' >&2
read -rs COMPOSIO_KEY; echo >&2
[ -n "${COMPOSIO_KEY:-}" ] || die "empty key"
# NOTE: --value on argv is briefly visible in /proc/*/cmdline; window is ~1s on
# a root-run one-shot. Same accepted trade-off as git-pat-vault.sh / m6.1.
SIDS=""
for name in "${!HOSTS[@]}"; do
  "$ONECLI" secrets create --name "$name" --type generic \
    --value "$COMPOSIO_KEY" --host-pattern "${HOSTS[$name]}" \
    --header-name "$HEADER_NAME" --value-format '{value}' >/dev/null
  SID="$(secret_id_by_name "$name")"
  [ -n "$SID" ] || die "secret $name created but not found in list"
  echo "secret $name id=$SID (host ${HOSTS[$name]})"
  SIDS="$SIDS$SID
"
done
unset COMPOSIO_KEY

# ---- bind additively with verify-after-set (verbatim git-pat-vault.sh) ------
log "binding to $AGENT_IDENT (additive, verified)"
BEFORE="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | py_ids | grep -v '^$' || true)"
mkdir -p "$(dirname "$PRESTATE")"; umask 077
printf '%s\n' "$BEFORE" > "$PRESTATE"
echo "pre-state bindings ($(printf '%s\n' "$BEFORE" | grep -c . || true) ids) saved to $PRESTATE"

WANT="$(printf '%s\n%s' "$BEFORE" "$SIDS" | grep -v '^$' | sort -u)"
# shellcheck disable=SC2086
"$ONECLI" agents set-secrets --id "$AID" --secret-ids $(echo $WANT | tr ' ' ',') >/dev/null \
  || "$ONECLI" agents set-secrets --id "$AID" --secret-ids $WANT >/dev/null

AFTER="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | py_ids | grep -v '^$' || true)"
MISSING="$(comm -23 <(printf '%s\n' "$WANT") <(printf '%s\n' "$AFTER" | sort -u) || true)"
if [ -n "$MISSING" ]; then
  echo "set-secrets dropped bindings ($MISSING) — RESTORING pre-state" >&2
  # shellcheck disable=SC2086
  "$ONECLI" agents set-secrets --id "$AID" --secret-ids $(printf '%s' "$BEFORE" | tr '\n' ',') >/dev/null || true
  die "binding failed verification; pre-state restored, composio secrets left UNBOUND (delete via m6.2-composio-vault-rollback.sh)"
fi

log "DONE"
cat <<EOF
Secrets bound to $AGENT_IDENT (header $HEADER_NAME):
$(for name in "${!HOSTS[@]}"; do echo "  $name → ${HOSTS[$name]}"; done)
Next (bot side, in the pod — no operator action):
  1. probe: curl https://backend.composio.dev/api/v3/toolkits → 200 (was 401);
  2. composio-session --user-id <chat_id> → MCP URL into ~/work/.mcp.json
     (replaces the dead stdio composio-mcp-bridge entry);
  3. new claude session sees the composio tool-router meta-tools.
Rollback: runtime/install/m6.2-composio-vault-rollback.sh
EOF
