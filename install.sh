#!/usr/bin/env bash
# install.sh — fleet-platform one-script installer (CANON capstone, docs/11 + 06).
#
# Stands up the whole platform on a FRESH server: control-plane stores + services,
# the tenant runtime image, egress lockdown, the security stack, authoring host
# side, integrations, the artifact marketplace, then provisions N tenants — by
# orchestrating the proven, idempotent per-milestone m*-*.sh scripts in dependency
# order. This is the GREENFIELD path; migrating existing host bots is a separate
# mode (runtime/install/migrate-*.sh), not this script.
#
# INSTALL-TIME RULES (Vitaliy 2026-06-18): every secret/param prompt prints an
# English description of what it is + why it is needed; all text is English. The
# prompt framework in install/lib/common.sh enforces rule #1 (mandatory description).
#
# Usage:
#   sudo ./install.sh [--dry-run] [--phase <name>] [--yes] [--config <file>]
#     --dry-run     preflight + print the plan + describe every secret; change NOTHING
#     --phase NAME  run only one phase (secrets|stores|services|image|egress|
#                   security|authoring|integrations|marketplace|tenants|verify)
#     --yes         non-interactive confirmations (secrets must come from env/--config)
#     --config F    source F first (sets config vars + any pre-supplied secret values)
#
# Idempotent: re-running is safe (sub-scripts detect existing state; secrets are
# created only if absent). Run as root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=install/lib/common.sh
. "$HERE/install/lib/common.sh"

CP_INSTALL="$HERE/control-plane/install"
RT_INSTALL="$HERE/runtime/install"

# ── args ─────────────────────────────────────────────────────────────────────
DRY_RUN=0; ONLY_PHASE=""; ASSUME_YES=0; CONFIG_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --phase) ONLY_PHASE="${2:?--phase needs a name}"; shift ;;
    --config) CONFIG_FILE="${2:?--config needs a file}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac; shift
done
export DRY_RUN ONLY_PHASE ASSUME_YES
[ -n "$CONFIG_FILE" ] && { [ -r "$CONFIG_FILE" ] || die "config not readable: $CONFIG_FILE"; . "$CONFIG_FILE"; }

# ── config (overridable via --config / env) ──────────────────────────────────
# Non-secret platform parameters. Secrets are collected in phase_secrets below.
PLATFORM_MINIAPP_HOST="${PLATFORM_MINIAPP_HOST:-}"
PLATFORM_IDE_HOST="${PLATFORM_IDE_HOST:-}"
PLATFORM_REGISTRY_REPO="${PLATFORM_REGISTRY_REPO:-joejoker77/claude-bot-skills}"
# Comma-separated tenant list, each "<os-username>[:role]" with role = user|admin
# (default user). Two roles only for this deployment. Empty = provision none now.
PLATFORM_TENANTS="${PLATFORM_TENANTS:-}"

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
  [ "$DRY_RUN" = "1" ] || require_root
  local c
  for c in podman openssl jq curl git; do
    if ! command -v "$c" >/dev/null 2>&1; then
      [ "$DRY_RUN" = "1" ] && warn "missing '$c' (tolerated for dry-run; required for a real run)" || die "required command '$c' not found"
    fi
  done
  command -v corepack >/dev/null 2>&1 || warn "corepack/node not found — control-plane needs pnpm-installed node_modules (run 'corepack pnpm install' in control-plane/ as the repo owner)"
  [ -d "$HERE/control-plane/node_modules" ] || warn "control-plane/node_modules missing — services run TypeScript via tsx and need deps installed"
  info "host: $(uname -sr)$(command -v podman >/dev/null 2>&1 && printf '; podman: %s' "$(podman --version)")"
}

# ── PHASE: secrets ────────────────────────────────────────────────────────────
# Collect ALL secrets ONCE (each described in English), then materialize them so
# the per-milestone scripts run non-interactively:
#   - control-plane local credentials  → podman secrets (cp_*)
#   - external service API keys         → OneCLI vault (via runtime/install vault scripts)
mk_podman_secret() { # NAME VALUE — create only if absent (dry-run: announce only)
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would create podman secret '$1' (if absent)"; return 0; fi
  podman secret inspect "$1" >/dev/null 2>&1 && { info "podman secret '$1' already exists — keeping"; return 0; }
  printf '%s' "$2" | podman secret create "$1" - >/dev/null && info "created podman secret '$1'"
}

phase_secrets() {
  # --- auto-generated control-plane credentials (explained, not prompted) ---
  describe_generated "cp_pg_password" \
    "PostgreSQL password for the control-plane database (cp-postgres). Used only inside the control-plane network to compose DATABASE_URL; never leaves the host. Auto-generated so it is strong and unique per install."
  local PG; PG="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 48)"

  describe_generated "cp_jwt_secret" \
    "HMAC signing secret for Mini App session tokens (JWT) issued by cp-api after Telegram initData verification. Auto-generated; rotating it invalidates live Mini App sessions only."
  local JWT; JWT="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)"

  describe_generated "cp_github_webhook_secret" \
    "Shared secret to verify inbound GitHub push webhooks (X-Hub-Signature-256) for the skill/MCP deploy reconcile. Auto-generated here; you paste the SAME value into the repo's webhook settings. Empty/absent => the webhook route stays dormant (503)."
  local WH; WH="$(openssl rand -hex 32)"

  # --- prompted secrets (described, then read silently) ---
  prompt_secret PLATFORM_BOT_TOKEN \
    "Telegram bot token from @BotFather for THIS deployment's bot. cp-api uses it to verify Mini App initData (HMAC) and to send approval/notification messages. A local credential (stays in a podman secret), NOT an outbound API key."
  prompt_secret PLATFORM_OPENROUTER_KEY \
    "OpenRouter API key for the security LLM-judge (cp-judge), which scores user-submitted MCP/skill artifacts. Event-triggered only (never on a schedule) and provider-side \$10/week capped. Format: sk-or-v1-... (no quotes)."

  mk_podman_secret cp_pg_password "$PG"
  mk_podman_secret cp_jwt_secret "$JWT"
  mk_podman_secret cp_github_webhook_secret "$WH"
  mk_podman_secret cp_bot_token "${PLATFORM_BOT_TOKEN:-}"
  mk_podman_secret cp_openrouter_key "${PLATFORM_OPENROUTER_KEY:-}"
  [ "$DRY_RUN" = "1" ] || info "GitHub webhook secret (paste into the repo webhook 'Secret' field): $WH"
}

# ── PHASE: control-plane stores (Postgres + Redis) ────────────────────────────
phase_stores()  { run_cmd bash "$CP_INSTALL/m1.2-stores.sh"; }

# ── PHASE: control-plane services (cp-api + audit-collector) + DB migrations ──
phase_services() {
  run_cmd bash "$CP_INSTALL/m1.5-services.sh"
  # DB migrations (drizzle) — apply pending schema (usage 0002, marketplace 0003, …)
  if [ -d "$HERE/control-plane/packages/db/drizzle" ]; then
    info "apply DB migrations (drizzle) — usage/marketplace schema"
    [ "$DRY_RUN" = "1" ] || ( cd "$HERE/control-plane" && node_modules/.bin/tsx packages/db/src/migrate.ts 2>/dev/null ) \
      || warn "drizzle migrate not auto-run — apply packages/db/drizzle/*.sql manually if needed"
  fi
}

# ── PHASE: tenant runtime image ───────────────────────────────────────────────
phase_image()   { run_cmd bash "$RT_INSTALL/m2.1-build-image.sh"; }

# ── PHASE: egress lockdown ────────────────────────────────────────────────────
phase_egress()  { run_cmd bash "$RT_INSTALL/m2.3-egress.sh"; }

# ── PHASE: security stack (judge, scanners, settings-guard, auto-suspend) ─────
phase_security() {
  run_cmd bash "$CP_INSTALL/m4.1-judge-orchestrator.sh"
  run_cmd bash "$CP_INSTALL/m4.2-scanners.sh"
  run_cmd bash "$CP_INSTALL/m4.3-settings-guard.sh"
  run_cmd bash "$CP_INSTALL/m4.4-auto-suspend.sh"
}

# ── PHASE: authoring host side (cp-secretd, web-IDE) ──────────────────────────
phase_authoring() {
  run_cmd bash "$RT_INSTALL/m5.5b-secretd.sh"
  run_cmd bash "$RT_INSTALL/m5.6-ide.sh"
}

# ── PHASE: integrations (external service keys → OneCLI vault) ────────────────
# These are OPTIONAL per deployment. Each prompts (described) inside its own
# script today; here we describe + feed the value so the run is non-interactive.
phase_integrations() {
  info "integrations are optional; skipping any whose key is not provided"
  # GitHub PAT (skill/MCP sharing + marketplace), Exa, Composio — wire per deployment.
  # (Left as explicit operator steps for now: run git-pat-vault.sh / m6.1 / m6.2,
  #  each prints its own English description before reading the key.)
  info "run when ready: git-pat-vault.sh ; m6.1-exa-vault.sh ; m6.2-composio-vault.sh"
}

# ── PHASE: artifact marketplace ───────────────────────────────────────────────
phase_marketplace() { run_cmd bash "$RT_INSTALL/m8.1-registry.sh"; }

# ── PHASE: provision tenants (2-role RBAC: user | admin) ──────────────────────
# Roles for this deployment (Vitaliy 2026-06-18 — exactly two; the 4-role model is
# the separate law-firm fork):
#   user  — sandboxed pod tenant, NO host access, standard skill/MCP allow-list.
#   admin — additionally gains a controlled host-root channel via the host-sudo
#           broker (make-admin.sh; NOPASSWD sudo behind a forced-command gate,
#           destructive ops blocked/HITL), like the fleet operators.
phase_tenants() {
  prompt_param PLATFORM_TENANTS \
    "Comma-separated list of tenants to provision, each as <os-username>[:role] where role is 'user' (default: sandboxed pod, no host access) or 'admin' (also granted the controlled host-root channel via the host-sudo broker). Example: alice,bob:admin,carol. Leave empty to provision none now (you can run provision-tenant.sh / make-admin.sh later)." \
    ""
  [ -n "${PLATFORM_TENANTS:-}" ] || { info "no tenants configured — provision later with provision-tenant.sh (+ make-admin.sh for admins)"; return 0; }
  local entry name role
  IFS=',' read -ra _TS <<< "$PLATFORM_TENANTS"
  for entry in "${_TS[@]}"; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"; [ -n "$entry" ] || continue
    name="${entry%%:*}"; role="user"; [ "$entry" = "$name" ] || role="${entry#*:}"
    case "$role" in user|admin) ;; *) die "tenant '$name': unknown role '$role' (use 'user' or 'admin')";; esac
    info "provisioning tenant '$name' (role: $role)"
    run_cmd bash "$RT_INSTALL/provision-tenant.sh" "$name"
    if [ "$role" = "admin" ]; then
      info "granting admin host-root channel to '$name' (host-sudo broker)"
      run_cmd bash "$RT_INSTALL/make-admin.sh" "$name"
      run_cmd systemctl restart "claude-pod@$name"   # restart so the mounted host-admin key is picked up
    fi
  done
}

# ── PHASE: verify ─────────────────────────────────────────────────────────────
phase_verify() {
  if [ "$DRY_RUN" = "1" ]; then info "would verify: cp-api /healthz + 'podman ps' of cp-* containers"; return 0; fi
  curl -sf "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 && info "cp-api /healthz OK" || warn "cp-api /healthz not responding"
  podman ps --filter name=cp- --format '{{.Names}}  {{.Status}}' 2>/dev/null | sed 's/^/    /'
}

# ── main ──────────────────────────────────────────────────────────────────────
log "fleet-platform installer"
[ "$DRY_RUN" = "1" ] && info "DRY-RUN: no changes will be made; describing the plan + every secret."
preflight
run_phase secrets       phase_secrets
run_phase stores        phase_stores
run_phase services      phase_services
run_phase image         phase_image
run_phase egress        phase_egress
run_phase security      phase_security
run_phase authoring     phase_authoring
run_phase integrations  phase_integrations
run_phase marketplace   phase_marketplace
run_phase tenants       phase_tenants
run_phase verify        phase_verify
log "done."
