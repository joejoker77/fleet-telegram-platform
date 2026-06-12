#!/usr/bin/env bash
# m6.1-exa-vault.sh — M6.1: move the Exa API key from the tenant's ~/work/.mcp.json
# (inline query param — the prototype leak doc 04 tells us to fix) into OneCLI
# vault, injected as an `x-api-key` header on egress to mcp.exa.ai.
#
# Header (not query param, deviating from the doc-08 sketch) because:
#   * proven 2026-06-12 from the pod: mcp.exa.ai honors x-api-key — a wrong
#     header key → tool error 401 "Invalid API key", the real one → results;
#   * OneCLI proxy injection is header-based (same mechanism as the git PAT).
#
# What it does (same fail-safe pattern as git-pat-vault.sh):
#   1. Prompts (silently) for the Exa API key.
#   2. Creates OneCLI secret `vitaliy-exa-api`:
#        host-pattern mcp.exa.ai, header x-api-key, value-format "{value}".
#   3. Binds it to the vitaliy-bot agent ADDITIVELY (union of current ids,
#      verify-after-set, pre-state saved for exact rollback).
#
# AFTER this script: the bot strips `exaApiKey=...` from ~/work/.mcp.json
# (pod side, documented in docs/M6.1-exa-vault.md). Until the strip, the
# inline key keeps working — no downtime either way.
#
# Rollback: m6.1-exa-vault-rollback.sh.
# Run as root on the host. Pilot: vitaliy only (M1+ rule).
set -euo pipefail

USER_NAME=vitaliy
AGENT_IDENT="${USER_NAME}-bot"
SECRET_NAME="${USER_NAME}-exa-api"
HOST_PATTERN="mcp.exa.ai"
HEADER_NAME="x-api-key"
PRESTATE=/etc/cl-egress/${USER_NAME}-exa-api.prestate
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
[ -z "$EXISTING" ] || die "secret $SECRET_NAME already exists (id=$EXISTING) — run m6.1-exa-vault-rollback.sh first to replace it"

# ---- read key, create the secret -------------------------------------------
log "creating secret $SECRET_NAME"
printf 'Paste the Exa API key (hidden; it is the exaApiKey=... value in /home/%s/work/.mcp.json), then Enter: ' "$USER_NAME" >&2
read -rs EXA_KEY; echo >&2
[ -n "${EXA_KEY:-}" ] || die "empty key"
# NOTE: --value on argv is briefly visible in /proc/*/cmdline; window is ~1s on
# a root-run one-shot. Same accepted trade-off as git-pat-vault.sh.
"$ONECLI" secrets create --name "$SECRET_NAME" --type generic \
  --value "$EXA_KEY" --host-pattern "$HOST_PATTERN" \
  --header-name "$HEADER_NAME" --value-format '{value}' >/dev/null
unset EXA_KEY
SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$SECRET_NAME'),''))")"
[ -n "$SID" ] || die "secret created but not found in list"
echo "secret id=$SID"

# ---- bind additively with verify-after-set (verbatim git-pat-vault.sh) ------
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
  die "binding failed verification; pre-state restored, secret $SECRET_NAME left UNBOUND (delete via m6.1-exa-vault-rollback.sh)"
fi

log "DONE"
cat <<EOF
Secret $SECRET_NAME bound to $AGENT_IDENT (host $HOST_PATTERN, header $HEADER_NAME).
Next (bot side, no restart needed for the running session):
  the bot strips '&exaApiKey=...' from /home/$USER_NAME/work/.mcp.json;
  the next claude session connects key-less and the proxy injects the header.
Verify (from the pod): wrong-key probe in docs/M6.1-exa-vault.md.
Rollback: runtime/install/m6.1-exa-vault-rollback.sh
EOF
