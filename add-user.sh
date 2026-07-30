#!/usr/bin/env bash
# add-user.sh — onboard ONE tenant onto a running platform, end-to-end, with ALL
# bindings. Default role is 'user' (sandboxed pod, no host access); --is-admin
# additionally grants the controlled host-root channel (host-sudo broker).
#
# install.sh stands up the platform + the first admin (by calling THIS script with
# --is-admin); every later user is added with this script. It is the single
# steady-state onboarding path — NOT a re-run of install.sh.
#
# Steps (idempotent):
#   1. provision-tenant.sh <user> <tg_id> [--admin]  (OS acct, pod, OneCLI agent, DB)
#   2. place the Telegram bot token in the tenant's channel .env (so its pod polls)
#   3. bind the platform integration keys (Exa / Composio / GitHub PAT) to THIS
#      tenant's OneCLI agent — each described, optional (blank = skip), staged per-user
#   4. --is-admin → make-admin.sh + restart pod (mount the host-admin key)
#   5. reconcile the tenant's skills/MCP via the control plane
#
# Install-time rules apply (English descriptions before each prompt; English text).
# Usage: sudo ./add-user.sh <os_user> <telegram_id> [--is-admin] [--dry-run] [--config F]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=install/lib/common.sh
. "$HERE/install/lib/common.sh"
RT_INSTALL="$HERE/runtime/install"
CP_DIR="$HERE/control-plane"

DRY_RUN=0; IS_ADMIN=0; ROLE_ARG=""; CONFIG_FILE=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE_ARG="${2:?--role needs a value}"; shift ;;
    --is-admin) IS_ADMIN=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --config) CONFIG_FILE="${2:?--config needs a file}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) POS+=("$1") ;;
  esac; shift
done
export DRY_RUN
[ -n "$CONFIG_FILE" ] && { [ -r "$CONFIG_FILE" ] || die "config not readable: $CONFIG_FILE"; . "$CONFIG_FILE"; }
USER_NAME="${POS[0]:?usage: add-user.sh <os_user> <telegram_id> [--is-admin]}"
TG_ID="${POS[1]:?telegram_id required (the tenant Telegram numeric user id)}"
[ "$DRY_RUN" = "1" ] || require_root

onecli_secret_exists() {
  command -v /usr/local/bin/onecli >/dev/null 2>&1 || return 1
  HOME=/root /usr/local/bin/onecli secrets list 2>/dev/null | grep -q "\"name\"[: ]*\"$1\""
}

# Role: --role wins; --is-admin is an alias for --role admin; default basic. Must be one of
# the firm roles so provision-tenant, role-matrix.json and the vault bindings all agree.
ROLE="${ROLE_ARG:-}"
if [ -z "$ROLE" ]; then if [ "$IS_ADMIN" = "1" ]; then ROLE="admin"; else ROLE="basic"; fi; fi
case "$ROLE" in admin|manager|finance|basic) ;; *) die "invalid --role: $ROLE (admin|manager|finance|basic)";; esac
if [ "$ROLE" = "admin" ]; then IS_ADMIN=1; else IS_ADMIN=0; fi

# role_entitled <role> <service> — true iff role-matrix.json grants <role> access to <service>.
# Firm per-user integrations below are offered ONLY to entitled roles (fail-closed).
role_entitled() {
  python3 - "$RT_INSTALL/role-matrix.json" "$1" "$2" <<'PY'
import json, sys
try: m = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)   # can't verify -> don't offer (fail-closed)
sys.exit(0 if sys.argv[2] in (m.get("services", {}).get(sys.argv[3], {}).get("roles", {})) else 1)
PY
}
log "add-user '$USER_NAME' (tg=$TG_ID, role=$ROLE)"

# 1) Claude subscription auth token — written host-side BEFORE the pod starts so
#    claude-pod-run injects CLAUDE_CODE_OAUTH_TOKEN on first start (else the claude
#    session can't authenticate and the pod restart-loops). Per-seat; tenant-generated.
log "1/6 Claude auth token"
prompt_secret CLAUDE_CODE_OAUTH_TOKEN \
  "Claude subscription OAuth token for THIS tenant's agent. On a machine WITH a browser, signed into THIS tenant's own Claude (Pro/Max/Team) account, run 'claude setup-token' and paste the ccat_... value. Long-lived (~1yr), per-seat — never shared across users. It lets the pod's claude authenticate headlessly."
if [ "$DRY_RUN" != "1" ]; then
  install -d -m 0700 /etc/claude-auth
  umask 077; printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > "/etc/claude-auth/$USER_NAME.token"
  chmod 600 "/etc/claude-auth/$USER_NAME.token"; info "wrote /etc/claude-auth/$USER_NAME.token"
fi

# 2) provision the tenant (OS account, pod, OneCLI agent, control-plane rows)
log "2/6 provision tenant"
run_cmd bash "$RT_INSTALL/provision-tenant.sh" "$USER_NAME" "$TG_ID" --role "$ROLE"

# 2) Telegram bot token → the tenant's channel .env (so its pod's plugin polls)
log "3/6 Telegram bot token"
prompt_secret TENANT_BOT_TOKEN \
  "Telegram bot token (@BotFather) for THIS tenant's own bot. Written to the tenant's channel .env so its pod polls Telegram as that bot. A local credential, not an outbound API key."
if [ "$DRY_RUN" != "1" ]; then
  ENVDIR="/home/$USER_NAME/.claude/channels/telegram-$USER_NAME"
  install -d -o "$USER_NAME" -g "$USER_NAME" "$ENVDIR"
  umask 077; printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TENANT_BOT_TOKEN" > "$ENVDIR/.env"
  chown "$USER_NAME:$USER_NAME" "$ENVDIR/.env"; chmod 600 "$ENVDIR/.env"
  info "wrote $ENVDIR/.env"
fi

# 3) bind platform integration keys to THIS tenant's OneCLI agent.
#    Firm per-user services (Exa/Composio/OpenRouter/Pipedrive) are offered ONLY if this role
#    is entitled per role-matrix.json — so a tenant can't stage a firm-service key its role
#    isn't allowed. GitHub PAT (skill/marketplace publishing) + ElevenLabs (voice STT) are
#    platform utilities, not firm-data services → offered to everyone. Blank = skip.
log "4/6 integrations (bind to ${USER_NAME}-bot, role=$ROLE)"
EXA_API_KEY=""; COMPOSIO_API_KEY=""; OPENROUTER_KEY=""; PIPEDRIVE_TOKEN=""
if role_entitled "$ROLE" exa; then prompt_secret_optional EXA_API_KEY \
  "Exa API key (web-search / deep-research). Staged as ${USER_NAME}-exa-api (x-api-key @ mcp.exa.ai). Blank to skip."; fi
if role_entitled "$ROLE" composio; then prompt_secret_optional COMPOSIO_API_KEY \
  "Composio platform API key (external-app connectors). Staged as ${USER_NAME}-composio-api/-mcp. Blank to skip."; fi
if role_entitled "$ROLE" openrouter; then prompt_secret_optional OPENROUTER_KEY \
  "OpenRouter API key (LLM gateway / voice fallback). Staged as ${USER_NAME}-openrouter-api (Authorization: Bearer @ openrouter.ai). Blank to skip."; fi
if role_entitled "$ROLE" pipedrive; then prompt_secret_optional PIPEDRIVE_TOKEN \
  "Pipedrive personal API token for the firm CRM (monacosolicitors2.pipedrive.com). Staged as ${USER_NAME}-pipedrive (x-api-token). Blank to skip."; fi
prompt_secret_optional GITHUB_PAT \
  "GitHub PAT for skill/MCP sharing + marketplace. Staged as ${USER_NAME}-git-fleet-platform (git @ github.com) AND ${USER_NAME}-github-github_pat (REST @ api.github.com, for marketplace publish). Blank to skip."
prompt_secret_optional ELEVENLABS_KEY \
  "ElevenLabs API key (voice STT; note: geo-restricted in some regions). Staged as ${USER_NAME}-elevenlabs-api (xi-api-key @ api.elevenlabs.io). Blank to skip."
_bind() { # SCRIPT  VALUE  EXISTING_SECRET_NAME  [extra args forwarded to SCRIPT]
  local script="$1" val="$2" sname="$3" base="${1##*/}"; shift 3
  if [ -z "$val" ]; then info "skip $base ($sname) — no key"; return 0; fi
  if [ "$DRY_RUN" != "1" ] && onecli_secret_exists "$sname"; then info "$sname already staged — keeping"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then info "would stage+bind $sname for $USER_NAME via $base"; return 0; fi
  KV_USER="$USER_NAME" KV_VALUE="$val" bash "$RT_INSTALL/$script" "$@"
}
_bind m6.1-exa-vault.sh      "${EXA_API_KEY:-}"      "${USER_NAME}-exa-api"
_bind m6.2-composio-vault.sh "${COMPOSIO_API_KEY:-}" "${USER_NAME}-composio-api"
_bind git-pat-vault.sh       "${GITHUB_PAT:-}"       "${USER_NAME}-git-fleet-platform"
# api.github.com (marketplace REST publish) needs the PAT with Authorization: Bearer
# + RAW token — NOT the Basic/x-access-token form git-pat-vault binds @ github.com.
# OneCLI host-match is exact-host (it binds backend.composio.dev + mcp.composio.dev
# separately), so github.com does NOT cover api.github.com → bind it explicitly.
_bind m-key-vault.sh "${GITHUB_PAT:-}"     "${USER_NAME}-github-github_pat" github-github_pat api.github.com Authorization "Bearer {value}"
_bind m-key-vault.sh "${OPENROUTER_KEY:-}" "${USER_NAME}-openrouter-api"     openrouter-api    openrouter.ai    Authorization "Bearer {value}"
_bind m-key-vault.sh "${PIPEDRIVE_TOKEN:-}" "${USER_NAME}-pipedrive"         pipedrive         monacosolicitors2.pipedrive.com x-api-token "{value}"
_bind m-key-vault.sh "${ELEVENLABS_KEY:-}" "${USER_NAME}-elevenlabs-api"     elevenlabs-api    api.elevenlabs.io xi-api-key   "{value}"

# 5) admin tier (host-sudo broker) if requested
if [ "$IS_ADMIN" = "1" ]; then
  log "5/6 admin tier (host-sudo broker)"
  run_cmd bash "$RT_INSTALL/make-admin.sh" "$USER_NAME"
else
  info "5/6 role=user — no host access (skipping make-admin)"
fi

# 6) reconcile skills/MCP for this tenant via the control plane
log "6/6 reconcile skills + MCP"
if [ "$DRY_RUN" = "1" ]; then info "would run: cp-api deploy-reconcile.ts $USER_NAME --all --apply"
else
  podman exec -w "$CP_DIR" cp-api node_modules/.bin/tsx apps/api/src/deploy-reconcile.ts "$USER_NAME" --all --apply >/dev/null 2>&1 \
    && info "reconciled skills/MCP for $USER_NAME" \
    || warn "reconcile step did not run (cp-api up? deps installed?) — will also happen on the next deploy webhook"
fi

# finalize: restart the pod so it picks up EVERYTHING placed above (Claude OAuth
# token, Telegram bot-token .env, admin host key, reconciled skills/MCP). provision
# started the pod with the Claude token (so it authenticates) but before the bot
# .env existed; one clean restart = a fully-credentialed, polling, working agent.
if [ "$DRY_RUN" != "1" ]; then
  log "finalize: restart pod with full credentials"
  run_cmd systemctl restart "claude-pod@$USER_NAME"
fi

log "add-user '$USER_NAME' done (role=$ROLE)"
