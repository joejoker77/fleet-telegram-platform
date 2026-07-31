#!/usr/bin/env bash
# onboard-integrations.sh — interactively collect, VALIDATE, and vault Monaco
# external-service API credentials into OneCLI, then make each one AVAILABLE to
# tenants strictly per the ROLE_MATRIX (the platform decides availability, not
# the operator). No --user flag: run as root; each validated key is bound to
# every current tenant whose role grants that service.
#
# Endpoints are BAKED IN (production). The script does NOT ask prod/stage — MS
# runs on prod. For each service it simply says "give me the creds for <svc>",
# the operator (e.g. Tom) enters them, the script tests the LIVE connection,
# says OK, and moves on. All prompts are in English.
#
# The egress proxy injects the right header at runtime; the Claude process never
# sees the raw key. Which services appear here is decided by key_type in
# role-matrix.json: ms_shared services are asked for below; per_user ones (each
# tenant supplies their own) are skipped here and prompted by add-user.sh instead.
#
#   sudo ./onboard-integrations.sh
#
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root

c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_no(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_hd(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (ssh root@host / host-sudo)"
command -v "$ONECLI" >/dev/null || die "onecli not found"
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated (onecli auth login)"
command -v curl >/dev/null || die "curl required for validation"

# ---- ROLE_MATRIX + key_type: loaded from role-matrix.json (the SINGLE source of
# truth, shared with render-access-block.sh). Edit entitlements there, not here — so
# the vault bindings this script creates can never drift from what the tenant CLAUDE.md
# says. ROLES[svc]="space-separated roles"; KEYTYPE[svc]="ms_shared|per_user".
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"
[ -f "$MATRIX" ] || die "role-matrix.json not found at $MATRIX (set ROLE_MATRIX_JSON)"
declare -A ROLES KEYTYPE
while IFS="$(printf '\t')" read -r svc roles ktype; do
  [ -n "$svc" ] || continue
  ROLES[$svc]="$roles"; KEYTYPE[$svc]="$ktype"
done < <(python3 - "$MATRIX" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for s in m["service_order"]:
    spec = m["services"][s]
    roles = " ".join(r for r in m["role_order"] if r in spec.get("roles", {}))
    print("\t".join([s, roles, spec.get("key_type", "ms_shared")]))
PY
)

# ---- tenant enumeration ----------------------------------------------------
tenants_for_role(){ # $1 = space-separated allowed roles -> prints tenant names
  local allowed=" $1 " t r
  for f in /etc/claude-role/*; do
    [ -f "$f" ] || continue
    t="$(basename "$f")"; r="$(tr -d ' \t\r\n' < "$f")"
    case "$allowed" in *" $r "*) echo "$t";; esac
  done
}

# ---- helpers ---------------------------------------------------------------
confirm(){ local a; read -rp "$1 [y/N]: " a; [ "$a" = y ] || [ "$a" = Y ]; }
ask(){ local v; read -rp "  $1: " v; printf '%s' "$v"; }
ask_secret(){ local v; read -rsp "  $1: " v; echo >&2; printf '%s' "$v"; }

http_code(){ local m="$1" url="$2"; shift 2; local args=(-sS -o /dev/null -w '%{http_code}' -m 20 -X "$m") data=""
  while [ $# -gt 0 ]; do case "$1" in --data) data="$2"; shift 2;; *) args+=(-H "$1"); shift;; esac; done
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data "$data")
  curl "${args[@]}" "$url" 2>/dev/null || echo 000; }

secret_id(){ "$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(next((s['id'] for s in r if s.get('name')=='$1'),''))"; }
agent_id(){ "$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in r if a.get('identifier')=='$1'),''))"; }
py_ids(){ python3 -c 'import json,sys;d=json.load(sys.stdin);r=d.get("data",d) if isinstance(d,dict) else d;print("\n".join(x if isinstance(x,str) else x.get("id","") for x in r))'; }

bind_secret_to_agent(){ # $1 secret-id  $2 agent-id
  local sid="$1" aid="$2" before want after
  before="$("$ONECLI" agents secrets --id "$aid" 2>/dev/null | py_ids | grep -v '^$' || true)"
  echo "$before" | grep -q "^$sid$" && { echo "     already bound"; return 0; }
  want="$(printf '%s\n%s\n' "$before" "$sid" | grep -v '^$' | sort -u)"
  "$ONECLI" agents set-secrets --id "$aid" --secret-ids "$(echo $want | tr ' ' ',')" >/dev/null 2>&1 \
    || "$ONECLI" agents set-secrets --id "$aid" --secret-ids $want >/dev/null 2>&1
  after="$("$ONECLI" agents secrets --id "$aid" 2>/dev/null | py_ids | grep -v '^$' || true)"
  echo "$after" | grep -q "^$sid$"
}

# roles_with_scope <service> <scope> — roles whose matrix scope == <scope> (e.g. rw|read)
roles_with_scope(){
  python3 - "$MATRIX" "$1" "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); svc = sys.argv[2]; scope = sys.argv[3]
roles = m["services"].get(svc, {}).get("roles", {})
print(" ".join(r for r in m["role_order"] if roles.get(r) == scope))
PY
}

# vault_and_distribute <service> <secret-name> <host> <header> <fmt> <value> [scope]
# Without [scope]: bind to every role entitled to <service> (ms_shared, uniform scope).
# With [scope] (rw|read): bind ONLY to roles whose matrix scope == that value — so a
# read-only key reaches read-scoped roles and the rw key reaches rw roles. This is what makes
# "basic = read-only Supabase" actually enforced (the injected key is itself read-only), not a
# doc promise; a read role never gets the rw key bound.
vault_and_distribute(){
  local svc="$1" name="$2" host="$3" hdr="$4" fmt="$5" val="$6" scope="${7:-}" sid allowed
  if [ "${KEYTYPE[$svc]:-ms_shared}" = per_user ]; then
    c_no "  [$svc] is a PER-USER service — each user adds their OWN key via self-onboarding; this admin script does NOT create a shared key for it."
    return 0
  fi
  sid="$(secret_id "$name")"
  if [ -n "$sid" ]; then
    if confirm "  secret $name exists — replace value?"; then "$ONECLI" secrets delete --id "$sid" >/dev/null 2>&1 || true; sid=""; fi
  fi
  if [ -z "$sid" ]; then
    "$ONECLI" secrets create --name "$name" --type generic --value "$val" \
      --host-pattern "$host" --header-name "$hdr" --value-format "$fmt" >/dev/null \
      || { c_no "  vault create failed"; return 1; }
    sid="$(secret_id "$name")"; [ -n "$sid" ] || { c_no "  secret not found after create"; return 1; }
  fi
  c_ok "  ✓ vaulted $name ($host / $hdr)"
  if [ -n "$scope" ]; then allowed="$(roles_with_scope "$svc" "$scope")"; else allowed="${ROLES[$svc]}"; fi
  local bound=0 t aid
  echo "  binding to tenants with role in: [${allowed:-none}]${scope:+  scope=$scope}"
  for t in $(tenants_for_role "$allowed"); do
    aid="$(agent_id "${t}-bot")"
    if [ -z "$aid" ]; then echo "   - $t: agent missing, skip"; continue; fi
    if bind_secret_to_agent "$sid" "$aid"; then echo "   - $t ✓"; bound=$((bound+1)); else c_no "   - $t bind FAILED"; fi
  done
  c_ok "  distributed to $bound tenant(s) per matrix"
}

# ===========================================================================
c_hd "Monaco integration onboarding (production; availability by ROLE_MATRIX)"
echo "Tenants on this host:"; for f in /etc/claude-role/*; do [ -f "$f" ] && echo "  $(basename "$f") = $(tr -d ' \t\r\n' <"$f")"; done
echo "For each service: y to configure, Enter to skip. The credential is validated"
echo "against the live service before it is stored. Nothing is written on failure."

# --- Supabase (prod) : jdjxlczkggckdnpeluuw.supabase.co --------------------
# TWO DIFFERENT MECHANISMS, because a Supabase secret key cannot be made read-only (it
# bypasses RLS):
#   rw roles (admin/manager) -> the service_role API key, vaulted and injected as a header
#     on the REST host, exactly like every other firm service.
#   read roles (basic)       -> NOT an API key. The firm issued a real read-only PostgreSQL
#     login (claude_readonly: no write grants, default_transaction_read_only=on). A libpq
#     credential can't be proxy-injected, and a pod must never hold a database password, so
#     it is installed into the host-side read-only gateway (cp-dbread) and tenants query
#     over HTTP. See control-plane/install/m9.1-dbread-gateway.sh.
if confirm "Configure Supabase?"; then
  H=jdjxlczkggckdnpeluuw.supabase.co
  # 1) read/write (service_role) -> rw roles (admin, manager)
  Krw="$(ask_secret "Supabase READ/WRITE key (service_role — for admin/manager)")"
  code="$(http_code GET "https://$H/rest/v1/" "apikey: $Krw" "Authorization: Bearer $Krw")"
  if [ "$code" = 200 ] || [ "$code" = 404 ]; then c_ok "  rw key valid (HTTP $code)"
    vault_and_distribute supabase "ms-supabase"      "$H" apikey        '{value}'        "$Krw" rw
    vault_and_distribute supabase "ms-supabase-auth" "$H" Authorization 'Bearer {value}'  "$Krw" rw
  else c_no "  rw key INVALID (HTTP $code) — not vaulted"; fi

  # 2) read tier -> the read-only PostgreSQL role behind the gateway. Skipping is fail-safe:
  #    read roles then simply have NO database access (they never fall back to the rw key).
  if confirm "  Configure the READ-ONLY database access now (PostgreSQL role, for basic)?"; then
    GW_INSTALL="$(cd "$HERE/../.." && pwd)/control-plane/install/m9.1-dbread-gateway.sh"
    if [ ! -x "$GW_INSTALL" ] && [ ! -f "$GW_INSTALL" ]; then
      c_no "  gateway installer not found at $GW_INSTALL — skipped"
    else
      echo "  This is the PostgreSQL login (default: claude_readonly on chatbot_v3_fork_prod),"
      echo "  NOT a Supabase API key. The password goes straight into a podman secret on this"
      echo "  host; it is never written to a file and never reaches a tenant container."
      DBP="$(ask_secret "Password for the read-only PostgreSQL role")"
      if [ -z "$DBP" ]; then c_no "  empty — skipped"
      else
        if DBREAD_PASSWORD="$DBP" bash "$GW_INSTALL" >/tmp/dbread-install.log 2>&1; then
          c_ok "  read-only gateway up (details: /tmp/dbread-install.log)"
          # Grant a token to every existing tenant the matrix entitles to Supabase. The
          # gateway re-checks the role on every request, so this only hands out what the
          # matrix already allows; tenants added later are granted by add-user.sh.
          for t in $(tenants_for_role "${ROLES[supabase]}"); do
            bash "$GW_INSTALL" --grant "$t" >/dev/null 2>&1 && echo "   - $t ✓" || c_no "   - $t grant FAILED"
          done
          c_ok "  distributed DB read access per matrix [${ROLES[supabase]}]"
        else
          c_no "  gateway install FAILED — see /tmp/dbread-install.log"; tail -5 /tmp/dbread-install.log
        fi
        unset DBP
      fi
    fi
  fi
fi

# --- Pipedrive (prod) : monacosolicitors2.pipedrive.com --------------------
# Personal API token authenticates via the `x-api-token` header; an OAuth access
# token via `Authorization: Bearer`. Try x-api-token first, fall back to Bearer,
# and vault whichever the API actually accepts.
if [ "${KEYTYPE[pipedrive]:-}" = per_user ]; then echo "  Pipedrive is a per-user service (each user self-onboards their own key) — skipped in this admin script."
elif confirm "Configure Pipedrive?"; then
  H=monacosolicitors2.pipedrive.com
  K="$(ask_secret "Pipedrive personal API token (sent as the x-api-token header)")"
  hdr=""; fmt=""
  # try a couple of always-present v2 endpoints with x-api-token; Bearer only helps for OAuth
  c1="$(http_code GET "https://$H/api/v2/users/me" "x-api-token: $K")"
  c2="$(http_code GET "https://$H/api/v2/deals?limit=1" "x-api-token: $K")"
  c3="-"
  if [ "$c1" = 200 ] || [ "$c2" = 200 ]; then hdr="x-api-token"; fmt='{value}'
  else c3="$(http_code GET "https://$H/api/v2/users/me" "Authorization: Bearer $K")"; [ "$c3" = 200 ] && { hdr="Authorization"; fmt='Bearer {value}'; }
  fi
  if [ -n "$hdr" ]; then c_ok "  valid (via $hdr)"; vault_and_distribute pipedrive "ms-pipedrive" "$H" "$hdr" "$fmt" "$K"
  else c_no "  INVALID — users/me=$c1 deals=$c2 bearer=$c3. Use a personal API token (Settings → Personal preferences → API) that belongs to the $H account."; fi
fi

# --- n8n : two production accounts (cloud + self-hosted) --------------------
if confirm "Configure n8n (cloud account)?"; then
  H=msgrapple.app.n8n.cloud
  K="$(ask_secret "n8n cloud API key")"
  code="$(http_code GET "https://$H/api/v1/workflows?limit=1" "X-N8N-API-KEY: $K")"
  [ "$code" = 200 ] && { c_ok "  valid"; vault_and_distribute n8n "ms-n8n-cloud" "$H" X-N8N-API-KEY '{value}' "$K"; } || c_no "  INVALID (HTTP $code)"
fi
if confirm "Configure n8n (self-hosted account)?"; then
  H=n8n.monacosolicitors.co.uk
  K="$(ask_secret "n8n self-hosted API key")"
  code="$(http_code GET "https://$H/api/v1/workflows?limit=1" "X-N8N-API-KEY: $K")"
  [ "$code" = 200 ] && { c_ok "  valid"; vault_and_distribute n8n "ms-n8n-selfhosted" "$H" X-N8N-API-KEY '{value}' "$K"; } || c_no "  INVALID (HTTP $code)"
fi

# --- OpenRouter : openrouter.ai --------------------------------------------
if [ "${KEYTYPE[openrouter]:-}" = per_user ]; then echo "  OpenRouter is a per-user service (each user self-onboards their own key) — skipped in this admin script."
elif confirm "Configure OpenRouter?"; then
  K="$(ask_secret "OpenRouter API key")"
  code="$(http_code GET "https://openrouter.ai/api/v1/key" "Authorization: Bearer $K")"
  [ "$code" = 200 ] && { c_ok "  valid"; vault_and_distribute openrouter "ms-openrouter" openrouter.ai Authorization 'Bearer {value}' "$K"; } || c_no "  INVALID (HTTP $code)"
fi

# --- WordPress (Rota) prod : cms.monacosolicitors.co.uk --------------------
if confirm "Configure WordPress (Rota)?"; then
  H=cms.monacosolicitors.co.uk
  U="$(ask "WP username")"; P="$(ask_secret "WP Application Password (Users -> Profile -> Application Passwords; the normal login password will NOT work)")"; B="$(printf '%s:%s' "$U" "$P" | base64 -w0)"
  code="$(http_code GET "https://$H/wp-json/wp/v2/users/me" "Authorization: Basic $B")"
  [ "$code" = 200 ] && { c_ok "  valid"; vault_and_distribute rota "ms-wordpress" "$H" Authorization 'Basic {value}' "$B"; } || c_no "  INVALID (HTTP $code)"
fi

# --- Payload CMS prod : chatbot.monacosolicitors.co.uk ---------------------
if confirm "Configure Payload CMS?"; then
  H=chatbot.monacosolicitors.co.uk
  K="$(ask_secret "Payload API key")"
  code="$(http_code GET "https://$H/api/access" "Authorization: users API-Key $K")"
  [ "$code" = 200 ] && { c_ok "  valid"; vault_and_distribute payload "ms-payload" "$H" Authorization 'users API-Key {value}' "$K"; } || c_no "  INVALID (HTTP $code) — check endpoint /api/access"
fi

# --- Strapi prod : api.monacosolicitors.grapple.uk -------------------------
if confirm "Configure Strapi?"; then
  H=api.monacosolicitors.grapple.uk
  K="$(ask_secret "Strapi API token")"
  code="$(http_code GET "https://$H/api/users/me" "Authorization: Bearer $K")"
  { [ "$code" = 200 ] || [ "$code" = 403 ]; } && { c_ok "  token accepted (HTTP $code)"; vault_and_distribute strapi "ms-strapi" "$H" Authorization 'Bearer {value}' "$K"; } || c_no "  INVALID (HTTP $code)"
fi

# --- Exa : mcp.exa.ai -------------------------------------------------------
# One firm Exa key for everyone (all roles have Exa). Validated against the REST
# API (api.exa.ai) because mcp.exa.ai speaks MCP, not a probe-able REST surface;
# the vaulted secret is bound for mcp.exa.ai, which is what the Exa MCP tools hit.
if confirm "Configure Exa (web search, all roles)?"; then
  K="$(ask_secret "Exa API key")"
  code="$(http_code POST "https://api.exa.ai/search" "x-api-key: $K" --data '{"query":"connectivity check","numResults":1}')"
  [ "$code" = 200 ] && { c_ok "  valid"; vault_and_distribute exa "ms-exa-api" mcp.exa.ai x-api-key '{value}' "$K"; } || c_no "  INVALID (HTTP $code)"
fi

# --- Composio : backend.composio.dev + mcp.composio.dev ---------------------
# ONE firm platform key, bound to every role. Per-user privacy is preserved by
# Composio itself: each tenant's connected accounts (their own Gmail/Slack/…) are
# isolated by user_id = that tenant's Telegram chat_id. A shared API key is NOT a
# shared mailbox — do not describe it as a shared account anywhere.
# Two secrets because OneCLI host-matching is exact-host and both hosts are used:
# backend.composio.dev (REST/connection management) + mcp.composio.dev (MCP tools).
if confirm "Configure Composio (external app connectors, all roles)?"; then
  K="$(ask_secret "Composio platform API key")"
  code="$(http_code GET "https://backend.composio.dev/api/v3/toolkits" "x-api-key: $K")"
  if [ "$code" = 200 ]; then
    c_ok "  valid"
    vault_and_distribute composio "ms-composio-api" backend.composio.dev x-api-key '{value}' "$K"
    vault_and_distribute composio "ms-composio-mcp" mcp.composio.dev      x-api-key '{value}' "$K"
  else c_no "  INVALID (HTTP $code)"; fi
fi

# --- Xero : OAuth2 Custom Connection (identity.xero.com / api.xero.com) -----
# Custom Connection = 2-legged client_credentials. We vault the client creds as
# Basic on identity.xero.com; at runtime Claude POSTs the token endpoint (proxy
# injects Basic), gets a ~30-min access_token, then calls api.xero.com with
# Bearer + the fixed Xero-tenant-id (baked into CLAUDE.md, not a secret).
XERO_TENANT_ID=7bb6bd0a-fccc-4421-b949-ddcdd28ece62
if confirm "Configure Xero? (OAuth2 Custom Connection)"; then
  CID="$(ask "Xero client_id")"; CSEC="$(ask_secret "Xero client_secret")"; BASIC="$(printf '%s:%s' "$CID" "$CSEC" | base64 -w0)"
  # Custom Connection: request NO scope. Xero issues a token scoped to whatever the
  # connection was granted; passing explicit scopes is filtered to empty -> invalid_scope.
  R="$(curl -sS -m 20 -X POST https://identity.xero.com/connect/token -H "Authorization: Basic $BASIC" \
        -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "grant_type=client_credentials" 2>/dev/null)"
  TOK="$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)"
  if [ -n "$TOK" ]; then conn="$(http_code GET https://api.xero.com/connections "Authorization: Bearer $TOK")"
    c_ok "  OAuth token OK; /connections HTTP $conn"
    vault_and_distribute xero "ms-xero-client" identity.xero.com Authorization 'Basic {value}' "$BASIC"
    echo "  runtime: Claude POSTs identity.xero.com/connect/token (grant_type=client_credentials, NO scope;"
    echo "           proxy injects Basic) -> access_token, then calls api.xero.com with"
    echo "           'Authorization: Bearer <token>' + 'Xero-tenant-id: $XERO_TENANT_ID'."
  else c_no "  INVALID — no token. Response: $(printf '%s' "$R" | tr -d '\n' | head -c 200)"; fi
fi

c_hd "Done"
echo "MS secrets in vault:"; "$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
[print('  ',s['name'],'->',s.get('hostPattern')) for s in r if s.get('name','').startswith('ms-')] or print('  (none)')"
echo "Tenants pick up new integrations on their next NEW Claude App session."
echo "NOTE: wire provisioning (add-user) to auto-bind existing ms-* secrets to new tenants by role."
