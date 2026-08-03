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
#                   security|authoring|marketplace|callback|tenants|verify)
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
# (Mini App + web-IDE removed for the firm: Telegram-only, no public web surface,
#  so no PLATFORM_DOMAIN / MINIAPP_HOST / IDE_HOST / certbot-email here.)
# The bootstrap ADMIN this install creates (the platform's first operator). Every
# other user is added afterwards with add-user.sh (default role user; --is-admin
# for more admins). Empty => stand up the platform only, add the admin later.
# Public domain for THIS deployment's Composio OAUTH CALLBACK. Composio needs a publicly
# reachable callback URL, and composio-connect otherwise falls back to the FLEET's domain —
# which silently routes this deployment's users (and their identifiers) through someone else's
# host. Set it and the callback is served here instead, behind TLS, as the ONLY public path.
# Empty => skipped, and that fallback stays in effect.
CALLBACK_DOMAIN="${CALLBACK_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
BOOTSTRAP_ADMIN_USER="${BOOTSTRAP_ADMIN_USER:-}"
BOOTSTRAP_ADMIN_TG="${BOOTSTRAP_ADMIN_TG:-}"

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
  [ "$DRY_RUN" = "1" ] || require_root
  local c
  # Missing prerequisites are no longer fatal here — the 'deps' phase installs
  # them (this is a one-command-on-a-fresh-host installer). Just report.
  for c in podman openssl jq curl git; do
    command -v "$c" >/dev/null 2>&1 || warn "missing '$c' — the 'deps' phase will install it"
  done
  command -v corepack >/dev/null 2>&1 || warn "corepack/node not found — the 'deps' phase installs Node 22 + corepack"
  [ -d "$HERE/control-plane/node_modules" ] || warn "control-plane/node_modules missing — the 'deps' phase runs pnpm install"
  info "host: $(uname -sr)$(command -v podman >/dev/null 2>&1 && printf '; podman: %s' "$(podman --version)")"
}

# ── PHASE: dependencies bootstrap ─────────────────────────────────────────────
# Makes the install truly one-command on a FRESH host: install every prerequisite
# (podman, jq, curl, git, openssl, Node 22 + corepack) and the control-plane
# node_modules. Idempotent — skips whatever is already present. Debian/Ubuntu apt
# + NodeSource for Node; on other distros it warns and relies on preexisting tools.
pkg_for() { case "$1" in podman) echo podman;; openssl) echo openssl;; jq) echo jq;; curl) echo curl;; git) echo git;; nginx) echo nginx;; certbot) echo certbot;; esac; }
phase_deps() {
  if [ "$DRY_RUN" = "1" ]; then
    info "would install missing prerequisites: podman, jq, curl, git, openssl, nginx, certbot (+python3-certbot-nginx), Node 22 + corepack, and control-plane node_modules (pnpm) — via apt + NodeSource"
    return 0
  fi
  require_root
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found (non-Debian host) — skipping auto-install; ensure podman/jq/curl/git/openssl/nginx/certbot/node22/corepack are present"
  else
    # nginx + certbot are needed to serve the Mini App / web-IDE vhosts and issue
    # their TLS certs (the public web surface — see m5/E). Bundled here so a
    # greenfield host needs nothing pre-installed.
    local need=() c
    for c in podman openssl jq curl git nginx certbot; do
      command -v "$c" >/dev/null 2>&1 || need+=("$(pkg_for "$c")")
    done
    if [ "${#need[@]}" -gt 0 ]; then
      info "installing OS packages: ${need[*]}"
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
    else
      info "OS packages already present (podman jq curl git openssl nginx certbot)"
    fi
    # certbot's nginx plugin has no standalone binary → ensure the package directly
    # (needed for `certbot --nginx` automated issuance in the web-serving phase).
    dpkg -s python3-certbot-nginx >/dev/null 2>&1 || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-nginx || \
      warn "python3-certbot-nginx not installed — automated TLS for Mini App/IDE will need it"
    # Node 22 + corepack — services run via tsx and need node >= 20.
    local nodemajor; nodemajor="$( (command -v node >/dev/null 2>&1 && node -p 'process.versions.node.split(".")[0]') 2>/dev/null || echo 0)"
    if [ "${nodemajor:-0}" -lt 20 ]; then
      info "installing Node.js 22 (NodeSource)"
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    else
      info "Node.js present (v$(node -p process.versions.node))"
    fi
  fi
  command -v corepack >/dev/null 2>&1 || npm install -g corepack >/dev/null 2>&1 || true
  corepack enable >/dev/null 2>&1 || true
  # OneCLI client shim (replaces the vendor Go binary; talks to the local API).
  # Repo-shipped — no external download.
  if [ -f "$HERE/runtime/install/onecli" ]; then
    install -m0755 "$HERE/runtime/install/onecli" /usr/local/bin/onecli
    info "installed onecli client shim -> /usr/local/bin/onecli"
  fi
  # control-plane node_modules (services run TypeScript via tsx). Use the pnpm
  # version pinned in package.json (corepack's default may mismatch and error).
  if [ ! -d "$HERE/control-plane/node_modules" ]; then
    local pnpmver pnpm owner
    pnpmver="$(grep -oE 'pnpm@[0-9.]+' "$HERE/control-plane/package.json" 2>/dev/null | head -1 | cut -d@ -f2)"
    pnpm="corepack pnpm${pnpmver:+@$pnpmver}"
    owner="$(stat -c %U "$HERE" 2>/dev/null)"; id "$owner" >/dev/null 2>&1 || owner=root
    info "installing control-plane dependencies ($pnpm) as $owner"
    if [ "$owner" = "root" ]; then
      ( cd "$HERE/control-plane" && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 $pnpm install --silent )
    else
      sudo -u "$owner" -H bash -lc "cd '$HERE/control-plane' && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 $pnpm install --silent"
    fi
  else
    info "control-plane node_modules already present"
  fi
}

# ── PHASE: secrets ────────────────────────────────────────────────────────────
# Collect ALL secrets ONCE (each described in English), then materialize them so
# the per-milestone scripts run non-interactively:
#   - control-plane local credentials  → podman secrets (cp_*)
#   - external service API keys         → OneCLI vault (via runtime/install vault scripts)
mk_podman_secret() { # NAME VALUE — create only if absent (dry-run: announce only)
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would create podman secret '$1' (if absent)"; return 0; fi
  if [ -z "${2:-}" ]; then info "podman secret '$1' has no value — skipping (optional; consumer treats absence as dormant)"; return 0; fi
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
  # OPTIONAL: empty => cp-judge starts dormant (no artifact scoring until a key is
  # set later). The platform stands up fully without it; the judge only runs when a
  # user submits an MCP/skill for review, so it is safe to defer.
  prompt_secret_optional PLATFORM_OPENROUTER_KEY \
    "OpenRouter API key for the security LLM-judge (cp-judge), which scores user-submitted MCP/skill artifacts. Event-triggered only (never on a schedule) and provider-side \$10/week capped. Format: sk-or-v1-... (no quotes). OPTIONAL — leave empty to stand up the platform with the judge dormant; add it later before enabling MCP/skill submissions."

  mk_podman_secret cp_pg_password "$PG"
  mk_podman_secret cp_jwt_secret "$JWT"
  mk_podman_secret cp_github_webhook_secret "$WH"
  mk_podman_secret cp_bot_token "${PLATFORM_BOT_TOKEN:-}"
  mk_podman_secret cp_openrouter_key "${PLATFORM_OPENROUTER_KEY:-}"
  [ "$DRY_RUN" = "1" ] || info "GitHub webhook secret (paste into the repo webhook 'Secret' field): $WH"
}

# ── PHASE: OneCLI vault (secret gateway, on podman — no Docker) ───────────────
# Must come before egress (the cl-egress forwarder bridges tenant pods to the
# OneCLI gateway on :10255) and before any per-tenant agent/secret bind.
phase_onecli()  { run_cmd bash "$CP_INSTALL/m1.1-onecli.sh"; }

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

# ── PHASE: authoring host side (cp-secretd) ───────────────────────────────────
# (web-IDE removed for the firm — Telegram-only, no public web surface.)
phase_authoring() {
  run_cmd bash "$RT_INSTALL/m5.5b-secretd.sh"
}

# (Integrations are NOT a platform-level phase: each tenant's keys are bound to
#  THAT tenant's OneCLI agent at onboarding by add-user.sh — including the
#  bootstrap admin created in phase_bootstrap_admin below.)

# ── PHASE: artifact marketplace ───────────────────────────────────────────────
phase_marketplace() { run_cmd bash "$RT_INSTALL/m8.1-registry.sh"; }

# ── PHASE: public Composio callback (own domain + TLS) ────────────────────────
phase_callback() {
  if [ -z "${CALLBACK_DOMAIN:-}" ]; then
    info "no CALLBACK_DOMAIN set — skipping. Composio callbacks then use the helper's default"
    info "  (the FLEET domain), so this deployment's users would traverse a host you don't own."
    return 0
  fi
  run_cmd bash "$CP_INSTALL/m6.3-composio-web.sh" --domain "$CALLBACK_DOMAIN" ${CERTBOT_EMAIL:+--email "$CERTBOT_EMAIL"}
}

# ── PHASE: bootstrap admin ────────────────────────────────────────────────────
# install.sh creates exactly ONE user — the bootstrap ADMIN — by handing off to
# add-user.sh --is-admin (the single onboarding path: provision + token +
# integrations bound to the agent + host-sudo broker + skills/MCP reconcile).
# Every other user is added later with add-user.sh (default role user). The bot
# token collected in phase_secrets is reused as the admin's own bot token (no
# double prompt).
phase_bootstrap_admin() {
  prompt_param BOOTSTRAP_ADMIN_USER \
    "OS username for the bootstrap ADMIN — the platform's first operator (gets the host-sudo admin channel). Leave empty to stand up the platform only and add the admin later with add-user.sh --is-admin." ""
  [ -n "${BOOTSTRAP_ADMIN_USER:-}" ] || { info "no bootstrap admin set — add one later: ./add-user.sh <user> <tg_id> --is-admin"; return 0; }
  prompt_param BOOTSTRAP_ADMIN_TG \
    "Telegram numeric user id of the bootstrap admin (their Telegram account id; used to bind the bot + Mini App auth)." ""
  [ -n "${BOOTSTRAP_ADMIN_TG:-}" ] || die "bootstrap admin needs a Telegram user id (BOOTSTRAP_ADMIN_TG)"
  # Claude subscription token for the admin's agent — without it the admin pod's
  # claude session can't authenticate (no working bot out of the box).
  prompt_secret PLATFORM_ADMIN_CLAUDE_TOKEN \
    "Claude subscription OAuth token for the bootstrap admin's agent. On a machine WITH a browser, signed into the admin's own Claude (Pro/Max/Team) account, run 'claude setup-token' and paste the ccat_... value. Long-lived (~1yr), per-seat."
  info "onboarding bootstrap admin '$BOOTSTRAP_ADMIN_USER' via add-user.sh --is-admin"
  # reuse the bot token from phase_secrets as the admin's tenant token; pass the
  # admin Claude token through as CLAUDE_CODE_OAUTH_TOKEN (add-user writes it host-side).
  run_cmd env TENANT_BOT_TOKEN="${PLATFORM_BOT_TOKEN:-}" CLAUDE_CODE_OAUTH_TOKEN="${PLATFORM_ADMIN_CLAUDE_TOKEN:-}" bash "$HERE/add-user.sh" "$BOOTSTRAP_ADMIN_USER" "$BOOTSTRAP_ADMIN_TG" --is-admin
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
run_phase deps          phase_deps
run_phase secrets       phase_secrets
run_phase stores        phase_stores
run_phase services      phase_services
run_phase image         phase_image
run_phase onecli        phase_onecli
run_phase egress        phase_egress
run_phase security      phase_security
run_phase authoring     phase_authoring
run_phase marketplace   phase_marketplace
run_phase callback      phase_callback
run_phase bootstrap_admin phase_bootstrap_admin
run_phase verify        phase_verify
log "done."
