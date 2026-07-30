#!/usr/bin/env bash
# render-access-block.sh <role> — print the per-role "Your access" block appended
# to a tenant's ~/.claude/CLAUDE.md. Single source of truth used by both
# provision-tenant.sh (new users) and the WAVE3 regeneration (existing users).
# Marker-delimited so it can be idempotently replaced.
#
# Each role gets: (1) a summary table of what it can use, and (2) a CONCRETE
# "How to call each system" reference — exact endpoint, the auto-injected auth
# header, and a copy-paste example — so the agent actually knows HOW to use its
# access, not just that it has it.
set -eu
ROLE="${1:?usage: render-access-block.sh <admin|manager|finance|basic>}"

# ── credential model reminder (printed once, above the per-service detail) ─────
cred_note() {
  cat <<'MD'
### How to actually call each system

**You never supply the API key or auth header yourself.** For every firm system
below, your credential lives in the encrypted vault and the egress proxy
**injects the right header automatically** on that service's host. So you just
`curl` (or fetch) the real endpoint and the request comes back authenticated —
the key never touches your process, your files, or your shell history.

**If a call returns 401/403 or "unauthorized":** that service's credential isn't
in the vault yet. Do NOT fall back to Composio. Tell the user which service needs
its key; an administrator adds it once via the onboarding step, then you retry the
exact same call. You cannot list what's in the vault — just try the call; 401 ⇒
not set yet.

MD
}

# ── per-service concrete how-to (single source of truth; called per role) ──────
detail() {
  case "$1" in
    supabase) cat <<'MD'
#### Supabase — the firm's database (PostgREST + Auth)
- **Base URL:** `https://jdjxlczkggckdnpeluuw.supabase.co/rest/v1/`
- **Auto-injected auth:** `apikey` **and** `Authorization: Bearer` (both, on this host).
- **Example (read rows):**
  `curl "https://jdjxlczkggckdnpeluuw.supabase.co/rest/v1/<table>?select=*&limit=5"`
- PostgREST — filter with `?col=eq.value`, insert/patch with `-X POST/PATCH` + JSON body.
- ⚠️ Shared with **Grapple** — only ever read/write **Monaco Solutions** data.
MD
    ;;
    pipedrive) cat <<'MD'
#### Pipedrive — CRM (client details, lawyers' work, automated emails)
- **Base URL:** `https://monacosolicitors2.pipedrive.com/api/v2/` (v1 at `/api/v1/` for
  endpoints not yet in v2).
- **Auto-injected auth:** `x-api-token` header (NOT `Authorization: Bearer` — Bearer is
  OAuth-only and returns 401 for an API token).
- **Example (list deals):**
  `curl "https://monacosolicitors2.pipedrive.com/api/v2/deals?limit=5"`
- Common: `/persons`, `/deals`, `/organizations`, `/activities`.
MD
    ;;
    n8n_cloud) cat <<'MD'
#### n8n (cloud account) — AI workflow automation
- **Base URL:** `https://msgrapple.app.n8n.cloud/api/v1/`
- **Auto-injected auth:** `X-N8N-API-KEY` header.
- **Example (list workflows):**
  `curl "https://msgrapple.app.n8n.cloud/api/v1/workflows?limit=5"`
- Common: `/workflows`, `/executions`, `/credentials`.
MD
    ;;
    n8n_self) cat <<'MD'
#### n8n (self-hosted account) — AI workflow automation
- **Base URL:** `https://n8n.monacosolicitors.co.uk/api/v1/`
- **Auto-injected auth:** `X-N8N-API-KEY` header.
- **Example:** `curl "https://n8n.monacosolicitors.co.uk/api/v1/workflows?limit=5"`
- Separate instance from the cloud one — pick the account the task refers to.
MD
    ;;
    openrouter) cat <<'MD'
#### OpenRouter — unified gateway to many LLMs (used by the chatbot)
- **Base URL:** `https://openrouter.ai/api/v1/`
- **Auto-injected auth:** `Authorization: Bearer`.
- **Check the key/quota:** `curl https://openrouter.ai/api/v1/key`
- **Chat completion:** `POST https://openrouter.ai/api/v1/chat/completions` with a
  JSON body (`model`, `messages`). Use for the chatbot's own model calls, not your own reasoning.
MD
    ;;
    rota) cat <<'MD'
#### Rota (WordPress) — lawyer notifications + Pipedrive deal actions
- **Base URL:** `https://cms.monacosolicitors.co.uk/wp-json/wp/v2/`
- **Auto-injected auth:** `Authorization: Basic` (a WP Application Password, injected).
- **Example (who am I):** `curl https://cms.monacosolicitors.co.uk/wp-json/wp/v2/users/me`
- Emails lawyers the client's info after the CDF contact form; buttons let lawyers action Pipedrive deals.
MD
    ;;
    payload) cat <<'MD'
#### Payload CMS — the chatbot's CMS (client & lawyer chatbot sessions)
- **Base URL:** `https://chatbot.monacosolicitors.co.uk/api/`
- **Auto-injected auth:** `Authorization: users API-Key <key>` (the whole scheme is injected).
- **Example (list a collection):**
  `curl "https://chatbot.monacosolicitors.co.uk/api/<collection>?limit=5"`
- `/api/access` shows what the key can do.
MD
    ;;
    strapi) cat <<'MD'
#### Strapi — CMS for terms pages, the letter-builder tool, internal settings
- **Base URL:** `https://api.monacosolicitors.grapple.uk/api/`
- **Auto-injected auth:** `Authorization: Bearer`.
- **Example:** `curl "https://api.monacosolicitors.grapple.uk/api/<content-type>?pagination[pageSize]=5"`
- Strapi content API — collections under `/api/<plural-name>`.
MD
    ;;
    xero) cat <<'MD'
#### Xero — billing & invoicing (OAuth2 Custom Connection, two steps)
See the **"Xero — the two-step call"** section above. In short:
1. `POST https://identity.xero.com/connect/token` body `grant_type=client_credentials`
   (send **NO** `scope`) — client creds auto-injected → returns an `access_token` (~30 min).
2. `GET https://api.xero.com/api.xro/2.0/<Resource>` with `Authorization: Bearer <token>`,
   `Xero-tenant-id: 7bb6bd0a-fccc-4421-b949-ddcdd28ece62`, `Accept: application/json`.
MD
    ;;
    exa) cat <<'MD'
#### Exa — web search & page fetch
Use the ready **`mcp__exa__*` tools** (e.g. `mcp__exa__web_search_exa`,
`mcp__exa__crawling_exa`). If they're not visible, load them with ToolSearch. No URL/key
handling needed — the vault injects the Exa key on `mcp.exa.ai`.
MD
    ;;
  esac
  echo
}

echo '<!-- BEGIN ROLE-ACCESS (managed by render-access-block.sh) -->'
case "$ROLE" in
  admin)
    cat <<'MD'
## Your access (role: admin) — full

You can use ALL the firm's systems:

| System | What it holds | How you reach it |
|---|---|---|
| **Supabase** | the firm's database — all MS projects, incl. the chatbot's DB (read AND edit) | direct REST, key auto-injected |
| **Payload CMS** | the chatbot's CMS — client & lawyer chatbot sessions | direct REST, key auto-injected |
| **Rota (WordPress)** | emails lawyers the client's info after the CDF contact form; buttons for lawyers to action Pipedrive deals | direct REST, key auto-injected |
| **Strapi** | CMS for terms pages, the letter-builder tool, internal settings | direct REST, key auto-injected |
| **Pipedrive** | CRM — all client details, lawyers' day-to-day work, automated emails | direct REST, key auto-injected |
| **n8n** (cloud + self-hosted) | AI workflow automation platform | direct REST, key auto-injected |
| **OpenRouter** | unified API gateway to various LLMs (used by the chatbot etc.) | direct REST, key auto-injected |
| **Xero** | billing & invoicing | direct REST (2-step OAuth), creds auto-injected |
| **Exa** | AI web search | `mcp__exa__*` tools |

You are also an administrator (host-root via `host-sudo`, and you can connect the user's
iCloud) — see the **Host admin capability** section below.
MD
    echo
    cred_note
    detail supabase; detail pipedrive; detail n8n_cloud; detail n8n_self
    detail openrouter; detail rota; detail payload; detail strapi; detail xero; detail exa
    ;;
  manager)
    cat <<'MD'
## Your access (role: manager)

| System | What it holds | How you reach it |
|---|---|---|
| **Supabase** | the firm's database, all MS projects (read & edit) | direct REST, key auto-injected |
| **Rota (WordPress)** | lawyer email notifications + Pipedrive deal actions | direct REST, key auto-injected |
| **Pipedrive** | CRM — client details, lawyers' work | direct REST, key auto-injected |
| **n8n** (cloud + self-hosted) | AI workflow automation | direct REST, key auto-injected |
| **OpenRouter** | unified LLM API gateway | direct REST, key auto-injected |
| **Exa** | AI web search | `mcp__exa__*` tools |

You do not have Payload, Strapi, Xero, or host-admin.
MD
    echo
    cred_note
    detail supabase; detail pipedrive; detail n8n_cloud; detail n8n_self; detail openrouter; detail rota; detail exa
    ;;
  finance)
    cat <<'MD'
## Your access (role: finance)

| System | What it holds | How you reach it |
|---|---|---|
| **Xero** | billing & invoicing | direct REST (2-step OAuth), creds auto-injected |
| **Exa** | AI web search | `mcp__exa__*` tools |

For anything else, ask an administrator.
MD
    echo
    cred_note
    detail xero; detail exa
    ;;
  basic)
    cat <<'MD'
## Your access (role: basic)

| System | What it holds | How you reach it |
|---|---|---|
| **Supabase** | the firm's database — **read only** | direct REST, key auto-injected |
| **Pipedrive** | CRM — client details | direct REST, key auto-injected |
| **Exa** | AI web search | `mcp__exa__*` tools |
MD
    echo
    cred_note
    detail supabase; detail pipedrive; detail exa
    ;;
  *)
    echo "## Your access (role: $ROLE) — not configured; ask an administrator."
    ;;
esac
echo '<!-- END ROLE-ACCESS (managed by render-access-block.sh) -->'
