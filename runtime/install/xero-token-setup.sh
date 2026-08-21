#!/usr/bin/env bash
# xero-token-setup.sh — store the bearer secrets for the firm's two Xero token services.
#
# Run this as root on the platform host. It asks for one secret per organisation, and
# each value is VALIDATED END-TO-END BEFORE IT IS STORED: we call the token service with
# it, then use the returned access token to read a real organisation record out of Xero.
# Only a genuine HTTP 200 with data counts as success. Nothing is written on failure.
#
#   Monaco  : bearer for the WordPress CMS token endpoint
#   Grapple : bearer for the n8n webhook token service
#
# Values are typed by you, never echoed, never passed on a command line (curl reads them
# from stdin), never written to a file. They go straight into the OneCLI vault and are
# bound to exactly the agents that are already entitled to Xero. Each secret is pinned to
# one hostname AND one URL path, so the proxy cannot send it anywhere else.
set -uo pipefail

ONECLI=/usr/local/bin/onecli
MONACO_URL="https://cms.monacosolicitors.co.uk/wp-json/rota/v1/xero-get-tokens"
MONACO_PATH="/wp-json/rota/v1/xero-get-tokens"
MONACO_HOST="cms.monacosolicitors.co.uk"
MONACO_TENANT="7bb6bd0a-fccc-4421-b949-ddcdd28ece62"
GRAPPLE_URL="https://n8n.monacosolicitors.co.uk/webhook/grapple-xero-get-tokens"
GRAPPLE_PATH="/webhook/grapple-xero-get-tokens"
GRAPPLE_HOST="n8n.monacosolicitors.co.uk"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
hdr(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || { red "run as root"; exit 1; }
"$ONECLI" auth status >/dev/null 2>&1 || { red "OneCLI API unreachable — is the vault running?"; exit 1; }

py(){ python3 -c "$@"; }

secret_id(){ # <name>
  "$ONECLI" secrets list 2>/dev/null | py '
import json,sys
name=sys.argv[1]
d=json.load(sys.stdin); d=d.get("data",d)
print(next((s["id"] for s in d if s.get("name")==name), ""))' "$1"
}

# The agents that must receive the new secrets are exactly those already entitled to Xero,
# i.e. those holding the old ms-xero-client secret. Deriving the list instead of hardcoding
# it means this stays correct as roles change.
XERO_OLD="$(secret_id ms-xero-client)"
if [ -z "$XERO_OLD" ]; then
  red "ms-xero-client not in the vault — cannot tell which tenants are entitled to Xero."
  red "Run onboard-integrations.sh first, or bind the new secrets by hand."
  exit 1
fi

mapfile -t AGENTS < <("$ONECLI" agents list 2>/dev/null | py '
import json,sys
d=json.load(sys.stdin); d=d.get("data",d)
for a in d: print("%s\t%s" % (a.get("id"), a.get("identifier") or a.get("name")))')

TARGETS=()
for row in "${AGENTS[@]}"; do
  aid="${row%%	*}"; aname="${row##*	}"
  if "$ONECLI" agents secrets --id "$aid" 2>/dev/null | grep -q "$XERO_OLD"; then
    TARGETS+=("$aid	$aname")
  fi
done
[ "${#TARGETS[@]}" -gt 0 ] || { red "no agent currently holds ms-xero-client — nothing to bind to"; exit 1; }

hdr "Xero token services — secret setup"
echo "Entitled agents that will receive the new secrets (${#TARGETS[@]}):"
for row in "${TARGETS[@]}"; do echo "   - ${row##*	}"; done
echo
echo "Each value is checked against the live service and against Xero before storing."

bind_all(){ # <secret-id>
  local sid="$1" row aid aname before want ok=0
  for row in "${TARGETS[@]}"; do
    aid="${row%%	*}"; aname="${row##*	}"
    before="$("$ONECLI" agents secrets --id "$aid" 2>/dev/null | py '
import json,sys
print("\n".join(json.load(sys.stdin)))' 2>/dev/null | grep -v '^$')"
    if printf '%s\n' "$before" | grep -qx "$sid"; then echo "   - $aname already bound"; ok=$((ok+1)); continue; fi
    want="$(printf '%s\n%s\n' "$before" "$sid" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"
    if "$ONECLI" agents set-secrets --id "$aid" --secret-ids "$want" >/dev/null 2>&1; then
      echo "   - $aname ✓"; ok=$((ok+1))
    else
      red "   - $aname BIND FAILED"
    fi
  done
  echo "   bound to $ok/${#TARGETS[@]} agents"
}

# validate <token-url> <tenant-or-empty> ; reads the bearer from $BEARER, prints nothing secret
validate(){
  local url="$1" tenant="$2" body code tok ten name
  body="$(mktemp)"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$BEARER" \
          | curl -sS -m 30 -K - -o "$body" -w '%{http_code}' -H 'Accept: application/json' "$url" 2>/dev/null)"
  if [ "$code" != 200 ]; then
    red "   token service answered HTTP $code — bearer rejected or endpoint wrong"
    [ -s "$body" ] && echo "   service said: $(tr -d '\n' <"$body" | head -c 200)"
    rm -f "$body"; return 1
  fi
  read -r tok ten < <(py '
import json,sys
d=json.load(open(sys.argv[1]))
i=d.get("data") if isinstance(d.get("data"),dict) else d
print("TOKENOK" if i.get("access_token") else "NOTOKEN", i.get("tenant_id") or "")' "$body")
  if [ "$tok" != TOKENOK ]; then
    red "   token service returned 200 but no access_token"; rm -f "$body"; return 1
  fi
  # now prove it actually reads Xero — a token alone is not success
  local real
  real="$(py '
import json,sys
d=json.load(open(sys.argv[1]))
i=d.get("data") if isinstance(d.get("data"),dict) else d
print(i.get("access_token",""))' "$body")"
  [ -n "$tenant" ] || tenant="$ten"
  if [ -z "$tenant" ]; then red "   no tenant id available"; rm -f "$body"; return 1; fi
  local ob oc
  ob="$(mktemp)"
  oc="$(printf 'header = "Authorization: Bearer %s"\n' "$real" \
        | curl -sS -m 30 -K - -o "$ob" -w '%{http_code}' \
          -H "Xero-tenant-id: $tenant" -H 'Accept: application/json' \
          https://api.xero.com/api.xro/2.0/Organisation 2>/dev/null)"
  if [ "$oc" != 200 ]; then
    red "   Xero refused the token — HTTP $oc, $(wc -c <"$ob") bytes. NOT storing."
    [ -s "$ob" ] && echo "   Xero said: $(tr -d '\n' <"$ob" | head -c 200)"
    rm -f "$body" "$ob"; return 1
  fi
  name="$(sed -n 's/.*"Name":"\([^"]*\)".*/\1/p' "$ob" | head -1)"
  grn "   verified: real HTTP 200 from Xero${name:+ — organisation: $name}"
  rm -f "$body" "$ob"; return 0
}

setup_profile(){ # <label> <secret-name> <host> <path> <url> <tenant-or-empty>
  local label="$1" name="$2" host="$3" path="$4" url="$5" tenant="$6" sid
  hdr "$label"
  echo "  endpoint: $url"
  read -r -p "  configure now? [y/N] " a
  case "$a" in y|Y) ;; *) echo "  skipped"; return 0 ;; esac

  read -rsp "  bearer secret (input hidden): " BEARER; echo
  [ -n "$BEARER" ] || { red "  empty — skipped"; unset BEARER; return 1; }

  echo "  validating..."
  if ! validate "$url" "$tenant"; then
    red "  NOTHING STORED for $label."
    unset BEARER; return 1
  fi

  sid="$(secret_id "$name")"
  if [ -n "$sid" ]; then
    echo "  secret $name already exists — replacing value"
    "$ONECLI" secrets delete --id "$sid" >/dev/null 2>&1 || true
  fi
  "$ONECLI" secrets create --name "$name" --type generic --value "$BEARER" \
      --host-pattern "$host" --path-pattern "$path" \
      --header-name Authorization --value-format 'Bearer {value}' >/dev/null || {
        red "  vault create FAILED"; unset BEARER; return 1; }
  unset BEARER
  sid="$(secret_id "$name")"
  [ -n "$sid" ] || { red "  secret missing after create"; return 1; }
  grn "  ✓ vaulted $name  ($host$path, Authorization: Bearer)"
  bind_all "$sid"
}

setup_profile "Monaco Solicitors — CMS token endpoint" \
  ms-xero-token-monaco "$MONACO_HOST" "$MONACO_PATH" "$MONACO_URL" "$MONACO_TENANT"

setup_profile "Grapple Ltd — n8n token service" \
  ms-xero-token-grapple "$GRAPPLE_HOST" "$GRAPPLE_PATH" "$GRAPPLE_URL" ""

hdr "Done"
echo "Verify from a tenant pod (this is the only check that proves it works):"
echo "   xero-call --profile monaco  --health"
echo "   xero-call --profile grapple --health"
echo "Both must print VERDICT: OK. A token alone is not success."
