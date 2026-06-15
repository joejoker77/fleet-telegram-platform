#!/usr/bin/env bash
# m-key-vault.sh — generic: stage ANY service API key in OneCLI vault and bind it
# to the vitaliy-bot agent, injected as an HTTP header on egress to <host>.
# Generalizes m6.1-exa-vault.sh (same fail-safe additive-bind + verify pattern)
# so new keys (elevenlabs, openrouter, …) don't each need a bespoke script.
#
#   sudo bash m-key-vault.sh <secret-suffix> <host-pattern> <header-name> [value-format]
#
# Examples:
#   sudo bash m-key-vault.sh elevenlabs-api api.elevenlabs.io xi-api-key
#   sudo bash m-key-vault.sh openrouter-api openrouter.ai Authorization 'Bearer {value}'
#
# Secret name = vitaliy-<secret-suffix>. value-format defaults to '{value}'.
# Rollback: m-key-vault-rollback.sh <secret-suffix>.
# Run as root on the host. Pilot: vitaliy only (M1+ rule).
set -euo pipefail

SUFFIX="${1:?usage: m-key-vault.sh <secret-suffix> <host-pattern> <header-name> [value-format]}"
HOST_PATTERN="${2:?host-pattern required (e.g. api.elevenlabs.io)}"
HEADER_NAME="${3:?header-name required (e.g. xi-api-key)}"
# NB: do NOT inline the default as "${4:-{value}}" — bash closes the ${...} at the
# first '}', leaving a STRAY literal '}' appended (e.g. 'Bearer {value}}'), which
# glues a '}' onto the injected token and breaks auth (caught 2026-06-15). Assign,
# then fall back, so the brace-y default never sits inside a parameter expansion.
VALUE_FORMAT="${4:-}"
[ -n "$VALUE_FORMAT" ] || VALUE_FORMAT='{value}'

USER_NAME=vitaliy
AGENT_IDENT="${USER_NAME}-bot"
SECRET_NAME="${USER_NAME}-${SUFFIX}"
PRESTATE="/etc/cl-egress/${USER_NAME}-${SUFFIX}.prestate"
ONECLI=/usr/local/bin/onecli

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
EXISTING="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$SECRET_NAME'),''))")"
[ -z "$EXISTING" ] || die "secret $SECRET_NAME already exists (id=$EXISTING) — run m-key-vault-rollback.sh $SUFFIX first to replace it"

# ---- read key, create the secret -------------------------------------------
log "creating secret $SECRET_NAME (host $HOST_PATTERN, header $HEADER_NAME, fmt '$VALUE_FORMAT')"
printf 'Paste the API key for %s (hidden), then Enter: ' "$SECRET_NAME" >&2
read -rs SVC_KEY; echo >&2
[ -n "${SVC_KEY:-}" ] || die "empty key"
# NOTE: --value on argv is briefly visible in /proc/*/cmdline; ~1s on a root-run
# one-shot. Same accepted trade-off as m6.1-exa-vault.sh.
"$ONECLI" secrets create --name "$SECRET_NAME" --type generic \
  --value "$SVC_KEY" --host-pattern "$HOST_PATTERN" \
  --header-name "$HEADER_NAME" --value-format "$VALUE_FORMAT" >/dev/null
unset SVC_KEY
SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$SECRET_NAME'),''))")"
[ -n "$SID" ] || die "secret created but not found in list"
echo "secret id=$SID"

# ---- bind additively with verify-after-set (verbatim m6.1-exa-vault.sh) -----
log "binding to $AGENT_IDENT (additive, verified)"
BEFORE="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | py_ids | grep -v '^$' || true)"
mkdir -p "$(dirname "$PRESTATE")"; umask 077
printf '%s\n' "$BEFORE" > "$PRESTATE"
echo "pre-state bindings ($(printf '%s\n' "$BEFORE" | grep -c . || true) ids) saved to $PRESTATE"

WANT="$(printf '%s\n%s\n' "$BEFORE" "$SID" | grep -v '^$' | sort -u)"
# shellcheck disable=SC2086
"$ONECLI" agents set-secrets --id "$AID" --secret-ids $(echo $WANT | tr ' ' ',') >/dev/null \
  || "$ONECLI" agents set-secrets --id "$AID" --secret-ids $WANT >/dev/null

AFTER="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | py_ids | grep -v '^$' || true)"
MISSING="$(comm -23 <(printf '%s\n' "$WANT") <(printf '%s\n' "$AFTER" | sort -u) || true)"
if [ -n "$MISSING" ]; then
  echo "set-secrets dropped bindings ($MISSING) — RESTORING pre-state" >&2
  # shellcheck disable=SC2086
  "$ONECLI" agents set-secrets --id "$AID" --secret-ids $(printf '%s' "$BEFORE" | tr '\n' ',') >/dev/null || true
  die "binding failed verification; pre-state restored, secret $SECRET_NAME left UNBOUND (delete via m-key-vault-rollback.sh $SUFFIX)"
fi

log "DONE"
cat <<EOF
Secret $SECRET_NAME bound to $AGENT_IDENT (host $HOST_PATTERN, header $HEADER_NAME).
The pod's next outbound request to $HOST_PATTERN gets the header injected by the
OneCLI proxy — no key on the pod, no restart needed for the running session.
Rollback: runtime/install/m-key-vault-rollback.sh $SUFFIX
EOF
