#!/usr/bin/env bash
# m6.4-graph-vault.sh — bind the firm's Microsoft Graph app-only credentials.
#
# Standalone on purpose (owner's call): Graph is not an API key like the other shared services,
# it is an OAuth2 client-credentials app, so it gets its own script rather than a branch inside
# onboard-integrations.sh.
#
# HOW IT WORKS AT RUNTIME. The egress proxy can only inject STATIC secrets, and Graph needs a
# short-lived bearer token, so we vault the client credentials as HTTP Basic on the Azure token
# host and let the `graph-call` helper do the two steps:
#   vault:  ms-graph-client = Basic base64(client_id:client_secret) @ login.microsoftonline.com
#   step 1: POST /<tenant>/oauth2/v2.0/token  (proxy adds the Basic header) -> access_token
#   step 2: GET graph.microsoft.com/v1.0/...  with Authorization: Bearer <token>
# The assistant therefore never holds the client secret, and a role without the binding simply
# cannot obtain a token.
#
# The secret is VERIFIED against Azure before anything is stored: a client-credentials grant is
# attempted and must return an access_token. Storing an unverified credential here would only
# surface later as an opaque failure inside a tenant.
#
# Usage:
#   sudo bash m6.4-graph-vault.sh [--tenant <id>] [--client-id <id>]
#     (the client secret is prompted for, hidden; never passed on argv)
# Rollback: m6.4-graph-vault-rollback.sh
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"
SECRET_NAME=ms-graph-client
HOST=login.microsoftonline.com

TENANT="431277f3-d970-475d-8efe-bd475d689a8f"
CLIENT_ID="6f9b8713-1285-4ba1-a8bc-f2f1f5b7a07a"
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant) TENANT="${2:?--tenant needs a value}"; shift ;;
    --client-id) CLIENT_ID="${2:?--client-id needs a value}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac; shift
done

c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_no(){ printf '\033[31m%s\033[0m\n' "$*"; }
log(){ printf '\n== %s ==\n' "$*"; }
die(){ c_no "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v "$ONECLI" >/dev/null || die "onecli not found"
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated"
[ -f "$MATRIX" ] || die "role-matrix.json not found at $MATRIX"

log "Microsoft Graph (app-only) for tenant $TENANT"
echo "  app (client) id: $CLIENT_ID"
echo "  This is the Azure app registration's CLIENT SECRET — not a user password, not an API key."
echo "  It is verified against Azure, then stored in the vault; it never reaches a tenant."

printf '  Client secret (hidden): ' >&2
read -rs SECRET; echo >&2
SECRET="$(printf '%s' "$SECRET" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$SECRET" ] || die "empty secret — nothing stored"
echo "  received ${#SECRET} chars, looks like ${SECRET:0:3}…${SECRET: -4}"

# ── verify BEFORE storing ────────────────────────────────────────────────────
# Two encodings of client_secret_basic exist in the wild: raw base64(id:secret), and the
# RFC-6749 form where each half is form-encoded first. Try raw, then encoded, and remember
# which one Azure accepted — the vault must store exactly that.
log "verifying the credentials against Azure"
b64_raw="$(printf '%s:%s' "$CLIENT_ID" "$SECRET" | base64 -w0)"
b64_enc="$(SECRET="$SECRET" CLIENT_ID="$CLIENT_ID" python3 - <<'PY'
import base64, os, urllib.parse
cid = urllib.parse.quote(os.environ["CLIENT_ID"], safe="")
sec = urllib.parse.quote(os.environ["SECRET"], safe="")
print(base64.b64encode(f"{cid}:{sec}".encode()).decode())
PY
)"

try_token(){ # $1 = basic value -> prints access_token or nothing
  curl -sS -m 30 -X POST "https://$HOST/$TENANT/oauth2/v2.0/token" \
    -H "Authorization: Basic $1" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode 'scope=https://graph.microsoft.com/.default' 2>/dev/null \
  | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d.get("access_token","") or "ERR:"+str(d.get("error_description",d.get("error",""))) [:160])
except Exception: print("")'
}

USE=""; FORM=""
R="$(try_token "$b64_raw")"
case "$R" in
  ERR:*|"") ;;
  *) USE="$b64_raw"; FORM="raw base64(client_id:secret)" ;;
esac
if [ -z "$USE" ]; then
  R2="$(try_token "$b64_enc")"
  case "$R2" in
    ERR:*|"") ;;
    *) USE="$b64_enc"; FORM="form-encoded halves, then base64" ;;
  esac
fi

if [ -z "$USE" ]; then
  c_no "  Azure did NOT accept the credentials — nothing stored."
  echo "  raw form said:          ${R:-<no response>}"
  echo "  form-encoded form said: ${R2:-<not tried>}"
  echo
  echo "  Check: is the secret current (Azure secrets expire), does it belong to app"
  echo "  $CLIENT_ID, and is the app in tenant $TENANT? A VALUE was needed, not the secret ID."
  exit 1
fi
c_ok "  Azure issued a token ($FORM)"

# ── store ────────────────────────────────────────────────────────────────────
log "vaulting $SECRET_NAME"
sid_of(){ "$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in r if s.get('name')=='$1'),''))"; }
OLD="$(sid_of "$SECRET_NAME")"
if [ -n "$OLD" ]; then
  "$ONECLI" secrets delete --id "$OLD" >/dev/null 2>&1 && echo "  replaced the previous value"
fi
"$ONECLI" secrets create --name "$SECRET_NAME" --type generic --value "$USE" \
  --host-pattern "$HOST" --header-name Authorization --value-format 'Basic {value}' >/dev/null \
  || die "vault create failed"
unset SECRET USE b64_raw b64_enc
SID="$(sid_of "$SECRET_NAME")"
[ -n "$SID" ] || die "secret not found after create"
c_ok "  stored $SECRET_NAME ($HOST / Authorization: Basic)"

# ── distribute per the matrix ────────────────────────────────────────────────
log "binding to entitled tenants"
ROLES="$(python3 - "$MATRIX" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
spec=m.get("services",{}).get("msgraph",{})
print(" ".join(r for r in m.get("role_order",[]) if r in spec.get("roles",{})))
PY
)"
echo "  entitled roles: [${ROLES:-none}]"
[ -n "$ROLES" ] || die "msgraph is not in role-matrix.json — add it before distributing"

bound=0
for f in /etc/claude-role/*; do
  [ -f "$f" ] || continue
  u="$(basename "$f")"; r="$(tr -d ' \t\r\n' <"$f")"
  case " $ROLES " in *" $r "*) ;; *) continue;; esac
  aid="$("$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in rows if a.get('identifier')=='${u}-bot'),''))")"
  [ -n "$aid" ] || { echo "   - $u: no agent, skipped"; continue; }
  have="$("$ONECLI" agents secrets --id "$aid" 2>/dev/null | python3 -c '
import json,sys
try: print(" ".join(json.load(sys.stdin)))
except Exception: pass')"
  want="$(printf '%s %s\n' "$have" "$SID" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"
  if "$ONECLI" agents set-secrets --id "$aid" --secret-ids "$want" >/dev/null 2>&1; then
    echo "   - $u ($r) ✓"; bound=$((bound+1))
  else c_no "   - $u ($r) bind FAILED"; fi
done
c_ok "  bound for $bound tenant(s)"

cat <<EOF

== DONE ==
Tenants entitled to Graph can now call it through the helper, with no secret of their own:
  graph-call GET users
  graph-call GET 'users/<upn>/messages?\$top=5'
App-only means there is no signed-in user, so /me does not work — always name the mailbox.
Rollback: bash $HERE/m6.4-graph-vault-rollback.sh
EOF
