#!/usr/bin/env bash
# git-pat-vault.sh — store the fleet-platform git PAT in OneCLI vault and bind
# it to the vitaliy-bot agent, per the secrets invariant (docs 04/06: secrets
# live ONLY in OneCLI; sandbox files hold placeholders/nothing).
#
# What it does:
#   1. Prompts (silently) for a fine-grained GitHub PAT
#      (repo: joejoker77/fleet-platform, Contents: Read&Write — nothing else).
#   2. Creates OneCLI secret `vitaliy-git-fleet-platform`:
#        host-pattern github.com, header Authorization,
#        value-format "Basic {value}", value = base64("x-access-token:<PAT>").
#      Git with URL-embedded creds sends exactly this Basic header, so GitHub
#      can't tell the difference; the pod itself never sees the token — the
#      egress proxy injects the header on the MITM'd CONNECT to github.com.
#   3. Binds the secret to the vitaliy-bot agent ADDITIVELY: reads the agent's
#      current secret ids first, sets the union, then VERIFIES no previous
#      binding was lost (unknown replace-vs-append semantics of `set-secrets`
#      → fail-safe wrapper). Pre-state saved for exact rollback.
#
# Rollback: git-pat-vault-rollback.sh (restores pre-state bindings, deletes
# the secret). Pod-side origin switch is reverted by the bot (documented there).
#
# Run as root on the host. Pilot: vitaliy only (M1+ rule).
set -euo pipefail

USER_NAME=vitaliy
AGENT_IDENT="${USER_NAME}-bot"
SECRET_NAME="${USER_NAME}-git-fleet-platform"
HOST_PATTERN="github.com"
PRESTATE=/etc/cl-egress/${USER_NAME}-git-pat.prestate
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
[ -z "$EXISTING" ] || die "secret $SECRET_NAME already exists (id=$EXISTING) — run the rollback script first to replace it"

# ---- read PAT, create the secret -------------------------------------------
log "creating secret $SECRET_NAME"
printf 'Paste the fine-grained GitHub PAT (hidden), then Enter: ' >&2
read -rs PAT; echo >&2
[ -n "${PAT:-}" ] || die "empty PAT"
B64="$(printf 'x-access-token:%s' "$PAT" | base64 -w0)"
unset PAT
# NOTE: --value on argv is briefly visible in /proc/*/cmdline; window is ~1s on
# a root-run one-shot. mcp-set-secret has the same property. Accepted.
"$ONECLI" secrets create --name "$SECRET_NAME" --type generic \
  --value "$B64" --host-pattern "$HOST_PATTERN" \
  --header-name Authorization --value-format "Basic {value}" >/dev/null
unset B64
SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in rows if s.get('name')=='$SECRET_NAME'),''))")"
[ -n "$SID" ] || die "secret created but not found in secrets list"
echo "secret id=$SID"

# ---- bind additively with verify-after-set ----------------------------------
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
  die "binding failed verification; pre-state restored, secret $SECRET_NAME left UNBOUND (delete via rollback script)"
fi

log "DONE"
echo "secret $SECRET_NAME ($SID) bound to $AGENT_IDENT alongside $(printf '%s\n' "$BEFORE" | grep -c . || true) existing"
echo "next (bot side, in the pod): switch origin to https and test ls-remote/push"
echo "rollback: bash $(dirname "$0")/git-pat-vault-rollback.sh"
