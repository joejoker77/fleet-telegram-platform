#!/usr/bin/env bash
# render-access-block.sh <role> — print the per-role "Your access" block appended to a
# tenant's ~/.claude/CLAUDE.md. Marker-delimited so it can be idempotently replaced.
#
# DERIVED from role-matrix.json (the single source of truth). This script holds only the
# PRESENTATION prose per service; WHICH services a role gets and each service's SCOPE come
# entirely from the matrix — so the CLAUDE.md doc can never drift from the vault bindings
# (onboard-integrations.sh reads the SAME matrix). Edit entitlements in role-matrix.json,
# not here.
set -eu
ROLE="${1:?usage: render-access-block.sh <admin|manager|finance|basic>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"

if [ ! -f "$MATRIX" ]; then
  echo '<!-- BEGIN ROLE-ACCESS -->'
  echo "## Your access (role: $ROLE) — matrix file missing; ask an administrator."
  echo '<!-- END ROLE-ACCESS -->'
  exit 0
fi

# Ordered "service<TAB>scope<TAB>key_type<TAB>label" for this role, straight from the matrix.
svc_rows() {
  python3 - "$MATRIX" "$ROLE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); role = sys.argv[2]
svcs = m["services"]
for s in m["service_order"]:
    spec = svcs.get(s, {})
    r = spec.get("roles", {})
    if role in r:
        print("\t".join([s, r[role], spec.get("key_type", "ms_shared"), spec.get("label", s)]))
PY
}

# ── presentation prose (keyed by service) ─────────────────────────────────────
whatis() { case "$1" in
  supabase)   echo "the firm's database — all MS projects, incl. the chatbot's DB";;
  payload)    echo "the chatbot's CMS — client & lawyer chatbot sessions";;
  rota)       echo "emails lawyers the client's info after the CDF form; buttons to action Pipedrive deals";;
  strapi)     echo "CMS for terms pages, the letter-builder tool, internal settings";;
  pipedrive)  echo "CRM — client details, lawyers' work, automated emails";;
  n8n)        echo "AI workflow automation (cloud + self-hosted)";;
  openrouter) echo "unified API gateway to many LLMs (used by the chatbot)";;
  exa)        echo "AI web search";;
  composio)   echo "connect your own external apps (Gmail, Slack, Calendar, …)";;
  xero)       echo "billing & invoicing";;
  *)          echo "-";;
esac; }

howreach() { # $1=service $2=key_type
  case "$1" in
    exa)      echo '`mcp__exa__*` tools';;
    composio) echo "one-click connect (your own account)";;
    *) if [ "$2" = per_user ]; then echo "direct REST, your own key (auto-injected)"; else echo "direct REST, key auto-injected"; fi;;
  esac; }

# credential-model reminder (printed once, above the per-service detail)
cred_note() {
  cat <<'MD'
### How to actually call each system

**You never supply an API key or auth header yourself.** For every firm system below your
credential lives in the encrypted vault and the egress proxy **injects the right header
automatically** on that service's host. So you just `curl` (or fetch) the real endpoint and
the request comes back authenticated — the key never touches your process, files, or shell
history. (Exa and Composio are used through their own tools, not raw `curl`.)

**If a call returns 401/403 or "unauthorized":** that credential isn't in the vault yet. Do
NOT fall back to Composio for a firm system. Tell the user which service needs its key — for
firm-wide services an administrator adds it once; for your-own-key services (Pipedrive,
OpenRouter, Composio) you add yours via the onboarding step — then retry the exact same call.
You can't list the vault; just try the call, and a 401 means "not set yet".

MD
}

# per-service concrete how-to (presentation; emitted only for entitled services)
detail() { local scope="${2:-rw}"
  case "$1" in
    supabase) cat <<MD
#### Supabase — the firm's database (PostgREST + Auth)
- **Base URL:** \`https://jdjxlczkggckdnpeluuw.supabase.co/rest/v1/\` (prod).
- **Auto-injected auth:** \`apikey\` **and** \`Authorization: Bearer\` (both, on this host).
- **Example (read rows):** \`curl "https://jdjxlczkggckdnpeluuw.supabase.co/rest/v1/<table>?select=*&limit=5"\`
- PostgREST — filter with \`?col=eq.value\`; write with \`-X POST/PATCH\` + JSON body.$([ "$scope" = read ] && printf '\n- ⚠️ **Your access is READ-ONLY** — do not attempt inserts/updates/deletes.')
- ⚠️ Shared with **Grapple** — only ever read/write **Monaco Solutions** data.
MD
    ;;
    pipedrive) cat <<'MD'
#### Pipedrive — CRM (client details, lawyers' work, automated emails)
- **Base URL:** `https://monacosolicitors2.pipedrive.com/api/v2/` (v1 at `/api/v1/` where needed).
- **Auth:** your OWN Pipedrive API token (you add it once via onboarding; injected as
  `x-api-token` — NOT `Authorization: Bearer`).
- **Example (list deals):** `curl "https://monacosolicitors2.pipedrive.com/api/v2/deals?limit=5"`
- Common: `/persons`, `/deals`, `/organizations`, `/activities`.
MD
    ;;
    n8n) cat <<'MD'
#### n8n — AI workflow automation (two instances)
- **Cloud:** `https://msgrapple.app.n8n.cloud/api/v1/` · **Self-hosted:** `https://n8n.monacosolicitors.co.uk/api/v1/`
- **Auto-injected auth:** `X-N8N-API-KEY` header (on each host).
- **Example:** `curl "https://n8n.monacosolicitors.co.uk/api/v1/workflows?limit=5"`
- Common: `/workflows`, `/executions`, `/credentials`. Pick the instance the task refers to.
MD
    ;;
    openrouter) cat <<'MD'
#### OpenRouter — unified gateway to many LLMs (used by the chatbot)
- **Base URL:** `https://openrouter.ai/api/v1/`
- **Auth:** your OWN OpenRouter key (add via onboarding; injected as `Authorization: Bearer`).
- **Check key/quota:** `curl https://openrouter.ai/api/v1/key`
- **Chat:** `POST /api/v1/chat/completions` (JSON `model`,`messages`). For the chatbot's model
  calls, not your own reasoning.
MD
    ;;
    rota) cat <<'MD'
#### Rota (WordPress) — lawyer notifications + Pipedrive deal actions
- **Base URL:** `https://cms.monacosolicitors.co.uk/wp-json/wp/v2/`
- **Auto-injected auth:** `Authorization: Basic` (a WP Application Password, injected).
- **Example (who am I):** `curl https://cms.monacosolicitors.co.uk/wp-json/wp/v2/users/me`
- Emails lawyers the client's info after the CDF contact form; buttons let lawyers action deals.
MD
    ;;
    payload) cat <<'MD'
#### Payload CMS — the chatbot's CMS (client & lawyer chatbot sessions)
- **Base URL:** `https://chatbot.monacosolicitors.co.uk/api/`
- **Auto-injected auth:** `Authorization: users API-Key <key>` (whole scheme injected).
- **Example:** `curl "https://chatbot.monacosolicitors.co.uk/api/<collection>?limit=5"`
- `/api/access` shows what the key can do.
MD
    ;;
    strapi) cat <<'MD'
#### Strapi — CMS for terms pages, the letter-builder tool, internal settings
- **Base URL:** `https://api.monacosolicitors.grapple.uk/api/`
- **Auto-injected auth:** `Authorization: Bearer`.
- **Example:** `curl "https://api.monacosolicitors.grapple.uk/api/<content-type>?pagination[pageSize]=5"`
- Collections under `/api/<plural-name>`.
MD
    ;;
    xero) cat <<'MD'
#### Xero — billing & invoicing (OAuth2 Custom Connection)
Use the **`xero-call`** helper — it does the two-step token exchange for you (fetches a
short-lived token via the firm's client creds, then calls the Accounting API with the bearer
token + the firm's `Xero-tenant-id`):
- `xero-call GET Invoices` · `xero-call GET Contacts` · `xero-call GET Accounts`
- filter: `xero-call GET 'Invoices?where=Type=="ACCREC"&page=1'`
- write: `xero-call POST Invoices --data @/tmp/invoice.json`
A "no access_token / invalid_client" error means Xero isn't set up for your role yet — tell
the user. (Under the hood: `POST identity.xero.com/connect/token` grant_type=client_credentials,
NO scope, Basic client-creds proxy-injected → token → `api.xero.com/api.xro/2.0/<Resource>`.)
MD
    ;;
    exa) cat <<'MD'
#### Exa — web search & page fetch
Use the ready **`mcp__exa__*` tools** (`mcp__exa__web_search_exa`, `mcp__exa__crawling_exa`,
`mcp__exa__deep_researcher_start`/`_check`). Load them with ToolSearch if not visible. The
vault injects the Exa key on `mcp.exa.ai` — no URL/key handling needed.
MD
    ;;
    composio) cat <<'MD'
#### Composio — connect the user's OWN external apps
For a service that is NOT a firm system (a user's personal Gmail, Slack, Calendar, Notion):
`composio-connect --toolkit <slug>` prints a one-click sign-in link — send it to the user.
After they connect, act via the `mcp__composio__*` tools. Two accounts of one service:
`--alias work`/`--alias personal`, then `composio-exec --account <alias>`. Never say
"Composio"/"OAuth" to the user; say "I can connect your Gmail, one click, I never see your
password".
MD
    ;;
  esac
  echo
}

# ── render ─────────────────────────────────────────────────────────────────
ROWS="$(svc_rows)"
echo '<!-- BEGIN ROLE-ACCESS (managed; derived from role-matrix.json) -->'
if [ -z "$ROWS" ]; then
  echo "## Your access (role: $ROLE) — no services configured; ask an administrator."
  echo '<!-- END ROLE-ACCESS -->'
  exit 0
fi

echo "## Your access (role: $ROLE)"
echo
echo "| System | What it holds | How you reach it |"
echo "|---|---|---|"
while IFS="$(printf '\t')" read -r svc scope ktype label; do
  [ -n "${svc:-}" ] || continue
  note=""; [ "$scope" = read ] && note=" — **read only**"
  echo "| **${label}**${note} | $(whatis "$svc") | $(howreach "$svc" "$ktype") |"
done <<EOF
$ROWS
EOF

if [ "$ROLE" = admin ]; then
  echo
  echo "You are also an administrator (host-root via \`host-sudo\`) — see the **Host admin capability** section below."
fi
echo
cred_note
while IFS="$(printf '\t')" read -r svc scope ktype label; do
  [ -n "${svc:-}" ] || continue
  detail "$svc" "$scope"
done <<EOF
$ROWS
EOF
echo '<!-- END ROLE-ACCESS (managed; derived from role-matrix.json) -->'
