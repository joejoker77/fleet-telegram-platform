#!/usr/bin/env bash
# uninstall.sh — reverse of install.sh: tear the platform down in REVERSE phase
# order, reusing the per-milestone *-rollback.sh scripts where they exist and
# removing containers/volumes/secrets/networks directly otherwise.
#
# DESTRUCTIVE. By default it removes the control-plane database volume (cp-pgdata)
# — i.e. ALL platform data. Use --keep-data to preserve it (for a reinstall).
# Idempotent: tolerates already-absent artifacts (safe to re-run).
#
# Install-time rules apply here too (Vitaliy 2026-06-18): every prompt/destructive
# step is described in English before it runs; all text is English.
#
# Usage:
#   sudo ./uninstall.sh [--keep-data] [--yes] [--phase <name>] [--dry-run] [--config F]
#     --keep-data   keep the Postgres data volume (cp-pgdata); remove everything else
#     --yes         skip the confirmation prompt (for automation)
#     --phase NAME  run only one reverse phase (tenants|integrations|authoring|
#                   security|egress|image|services|stores|secrets|network)
#     --dry-run     print what WOULD be removed; change nothing
#     --config F    source F first (e.g. to set PLATFORM_TENANTS for deprovisioning)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=install/lib/common.sh
. "$HERE/install/lib/common.sh"
CP_INSTALL="$HERE/control-plane/install"
RT_INSTALL="$HERE/runtime/install"

DRY_RUN=0; ONLY_PHASE=""; ASSUME_YES=0; KEEP_DATA=0; CONFIG_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    --phase) ONLY_PHASE="${2:?--phase needs a name}"; shift ;;
    --config) CONFIG_FILE="${2:?--config needs a file}"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac; shift
done
export DRY_RUN ONLY_PHASE ASSUME_YES
[ -n "$CONFIG_FILE" ] && { [ -r "$CONFIG_FILE" ] || die "config not readable: $CONFIG_FILE"; . "$CONFIG_FILE"; }
PLATFORM_TENANTS="${PLATFORM_TENANTS:-}"

# ── removal helpers (idempotent, dry-run aware) ───────────────────────────────
rmscript() { # RELPATH [args...] — run a rollback script if present
  local rel="$1"; shift
  [ -f "$HERE/$rel" ] || { info "no $rel — skipping"; return 0; }
  run_cmd bash "$HERE/$rel" "$@"
}
_rm() { # KIND NAME PODMAN-ARGS... — generic idempotent remove, dry-run aware
  local kind="$1" name="$2"; shift 2
  if [ "$DRY_RUN" = "1" ]; then info "would remove $kind '$name' (if present)"; return 0; fi
  podman "$@" >/dev/null 2>&1 || true; info "removed $kind '$name' (if present)"
}
rm_container() { _rm container "$1" rm -f "$1"; }
rm_volume()    { _rm volume "$1" volume rm "$1"; }
rm_secret()    { _rm "podman secret" "$1" secret rm "$1"; }
rm_network()   { _rm network "$1" network rm "$1"; }
rm_image()     { _rm image "$1" rmi "$1"; }

# ── reverse phases ────────────────────────────────────────────────────────────
phase_tenants() {
  [ -n "$PLATFORM_TENANTS" ] || { info "no PLATFORM_TENANTS set — skipping tenant deprovision (set via --config if needed)"; return 0; }
  local entry name role
  IFS=',' read -ra _TS <<< "$PLATFORM_TENANTS"
  for entry in "${_TS[@]}"; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"; [ -n "$entry" ] || continue
    name="${entry%%:*}"; role="user"; [ "$entry" = "$name" ] || role="${entry#*:}"
    info "deprovisioning tenant '$name' (role: $role) — stops the pod, removes the OS account + control-plane rows"
    [ "$role" = "admin" ] && rmscript "runtime/install/unmake-admin.sh" "$name"
    rmscript "runtime/install/deprovision-tenant.sh" "$name"
  done
}
phase_integrations() {
  info "removing OneCLI vault secrets for Exa / Composio / GitHub PAT (the platform integration keys)"
  rmscript "runtime/install/m6.1-exa-vault-rollback.sh"
  rmscript "runtime/install/m6.2-composio-vault-rollback.sh"
  rmscript "runtime/install/git-pat-vault-rollback.sh"
}
phase_authoring() {
  info "removing the web-IDE host side and the cp-secretd secret-intake helper"
  rmscript "runtime/install/m5.6-rollback.sh"
  rmscript "runtime/install/m5.5b-secretd-rollback.sh"
}
phase_security() {
  info "removing the security stack: auto-suspend monitor, settings-integrity guard, Judge Orchestrator (cp-judge)"
  rmscript "control-plane/install/m4.4-auto-suspend-rollback.sh"
  rmscript "control-plane/install/m4.3-settings-guard-rollback.sh"
  rmscript "control-plane/install/m4.1-rollback.sh"
}
phase_egress()   { info "reverting the tenant egress lockdown (nftables) to the pre-install state"; rmscript "runtime/install/m2.3-rollback.sh"; }
phase_image()    { info "removing the tenant runtime image (claude-user:latest)"; rm_image "claude-user:latest"; }
phase_services() {
  info "removing the control-plane services (cp-api, cp-audit-collector) and the audit run volume"
  rm_container cp-api
  rm_container cp-audit-collector
  rm_volume cp-audit-run
}
phase_stores() {
  info "removing the control-plane data stores (cp-postgres, cp-redis) and network cp-net"
  rm_container cp-postgres
  rm_container cp-redis
  if [ "$KEEP_DATA" = "1" ]; then
    info "--keep-data: KEEPING the Postgres data volume 'cp-pgdata'"
  else
    warn "removing the Postgres data volume 'cp-pgdata' — ALL platform data is destroyed (use --keep-data to keep it)"
    rm_volume cp-pgdata
  fi
  rm_network cp-net
}
phase_secrets() {
  info "removing the control-plane podman secrets (local credentials)"
  local s
  for s in cp_pg_password cp_jwt_secret cp_bot_token cp_github_webhook_secret cp_openrouter_key; do rm_secret "$s"; done
}
phase_network() { info "removing the tenant network (cl-net)"; rm_network cl-net; }

# ── main ──────────────────────────────────────────────────────────────────────
log "fleet-platform UNINSTALLER"
[ "$DRY_RUN" = "1" ] || require_root
if [ "$DRY_RUN" = "1" ]; then info "DRY-RUN: nothing will be removed; printing the teardown plan."; fi

if [ "$DRY_RUN" != "1" ]; then
  printf '\n  %sThis will TEAR DOWN the fleet-platform on this host:%s\n' "$_C_B" "$_C_R"
  info "control-plane (cp-api/audit/judge/postgres/redis), the runtime image, egress rules,"
  info "the security stack, integration vault secrets, and the configured tenants' pods."
  [ "$KEEP_DATA" = "1" ] && info "Postgres data volume will be KEPT (--keep-data)." \
                         || warn "Postgres data volume cp-pgdata WILL BE DELETED (all data lost). Use --keep-data to keep it."
  confirm "Proceed with uninstall?" || die "aborted by operator."
fi

run_phase tenants       phase_tenants
run_phase integrations  phase_integrations
run_phase authoring     phase_authoring
run_phase security      phase_security
run_phase egress        phase_egress
run_phase image         phase_image
run_phase services      phase_services
run_phase stores        phase_stores
run_phase secrets       phase_secrets
run_phase network       phase_network
log "uninstall complete."
