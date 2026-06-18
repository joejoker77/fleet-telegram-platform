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

DRY_RUN=0; IS_ADMIN=0; CONFIG_FILE=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
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

ROLE="user"; [ "$IS_ADMIN" = "1" ] && ROLE="admin"
log "add-user '$USER_NAME' (tg=$TG_ID, role=$ROLE)"

# 1) provision the tenant (OS account, pod, OneCLI agent, control-plane rows)
log "1/5 provision tenant"
if [ "$IS_ADMIN" = "1" ]; then run_cmd bash "$RT_INSTALL/provision-tenant.sh" "$USER_NAME" "$TG_ID" --admin
else run_cmd bash "$RT_INSTALL/provision-tenant.sh" "$USER_NAME" "$TG_ID"; fi

# 2) Telegram bot token → the tenant's channel .env (so its pod's plugin polls)
log "2/5 Telegram bot token"
prompt_secret TENANT_BOT_TOKEN \
  "Telegram bot token (@BotFather) for THIS tenant's own bot. Written to the tenant's channel .env so its pod polls Telegram as that bot. A local credential, not an outbound API key."
if [ "$DRY_RUN" != "1" ]; then
  ENVDIR="/home/$USER_NAME/.claude/channels/telegram-$USER_NAME"
  install -d -o "$USER_NAME" -g "$USER_NAME" "$ENVDIR"
  umask 077; printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TENANT_BOT_TOKEN" > "$ENVDIR/.env"
  chown "$USER_NAME:$USER_NAME" "$ENVDIR/.env"; chmod 600 "$ENVDIR/.env"
  info "wrote $ENVDIR/.env"
fi

# 3) bind platform integration keys to THIS tenant's OneCLI agent (each optional)
log "3/5 integrations (bind to ${USER_NAME}-bot)"
prompt_secret_optional EXA_API_KEY \
  "Exa API key (web-search / deep-research MCP). Staged for this tenant as ${USER_NAME}-exa-api (x-api-key @ mcp.exa.ai) and proxy-injected. Blank to skip."
prompt_secret_optional COMPOSIO_API_KEY \
  "Composio platform API key (external-app connectors). Staged as ${USER_NAME}-composio-api/-mcp. Blank to skip."
prompt_secret_optional GITHUB_PAT \
  "GitHub PAT for skill/MCP sharing + marketplace. Staged as ${USER_NAME}-git-fleet-platform. Blank to skip."
_bind() { # SCRIPT  VALUE  EXISTING_SECRET_NAME
  local script="$1" val="$2" sname="$3" base="${1##*/}"
  if [ -z "$val" ]; then info "skip $base — no key"; return 0; fi
  if [ "$DRY_RUN" != "1" ] && onecli_secret_exists "$sname"; then info "$sname already staged — keeping"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then info "would stage+bind $sname for $USER_NAME via $base"; return 0; fi
  KV_USER="$USER_NAME" KV_VALUE="$val" bash "$RT_INSTALL/$script"
}
_bind m6.1-exa-vault.sh      "${EXA_API_KEY:-}"      "${USER_NAME}-exa-api"
_bind m6.2-composio-vault.sh "${COMPOSIO_API_KEY:-}" "${USER_NAME}-composio-api"
_bind git-pat-vault.sh       "${GITHUB_PAT:-}"       "${USER_NAME}-git-fleet-platform"

# 4) admin tier (host-sudo broker) if requested
if [ "$IS_ADMIN" = "1" ]; then
  log "4/5 admin tier (host-sudo broker)"
  run_cmd bash "$RT_INSTALL/make-admin.sh" "$USER_NAME"
  run_cmd systemctl restart "claude-pod@$USER_NAME"
else
  info "4/5 role=user — no host access (skipping make-admin)"
fi

# 5) reconcile skills/MCP for this tenant via the control plane
log "5/5 reconcile skills + MCP"
if [ "$DRY_RUN" = "1" ]; then info "would run: cp-api deploy-reconcile.ts $USER_NAME --all --apply"
else
  podman exec -w "$CP_DIR" cp-api node_modules/.bin/tsx apps/api/src/deploy-reconcile.ts "$USER_NAME" --all --apply >/dev/null 2>&1 \
    && info "reconciled skills/MCP for $USER_NAME" \
    || warn "reconcile step did not run (cp-api up? deps installed?) — will also happen on the next deploy webhook"
fi

log "add-user '$USER_NAME' done (role=$ROLE)"
