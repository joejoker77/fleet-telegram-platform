#!/usr/bin/env bash
# remove-user.sh — offboard ONE tenant cleanly (the pair of add-user.sh).
#   1. back up the tenant's ~/.claude + ~/work (unless --no-backup)
#   2. revoke the admin host-sudo channel (unmake-admin; idempotent if not admin)
#   3. delete the tenant's OneCLI vault secrets (<user>-*) — they outlive the agent
#   4. deprovision-tenant.sh (stop pod, delete agent + token + control-plane rows;
#      --purge also userdel's the OS account + home)
#
# DESTRUCTIVE. English-described steps + confirmation. Idempotent (tolerates absent).
# Usage: sudo ./remove-user.sh <os_user> [--purge] [--no-backup] [--yes] [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=install/lib/common.sh
. "$HERE/install/lib/common.sh"
RT_INSTALL="$HERE/runtime/install"

DRY_RUN=0; PURGE=0; NO_BACKUP=0; ASSUME_YES=0; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) POS+=("$1") ;;
  esac; shift
done
export DRY_RUN ASSUME_YES
USER_NAME="${POS[0]:?usage: remove-user.sh <os_user> [--purge] [--no-backup]}"
[ "$DRY_RUN" = "1" ] || require_root

log "remove-user '$USER_NAME'$([ "$PURGE" = 1 ] && printf ' (with --purge: deletes the OS account + home)')"
if [ "$DRY_RUN" != "1" ]; then
  warn "this offboards '$USER_NAME': pod, OneCLI agent + secrets, control-plane rows$([ "$PURGE" = 1 ] && printf ', AND the OS account + home')."
  confirm "Proceed?" || die "aborted by operator."
fi

# 1) backup
if [ "$NO_BACKUP" = "1" ]; then
  info "1/4 backup SKIPPED (--no-backup)"
else
  log "1/4 backup ~/.claude + ~/work"
  if [ "$DRY_RUN" = "1" ]; then info "would tar /home/$USER_NAME/{.claude,work} → /home/$USER_NAME/removed-backup-<stamp>.tar.gz"
  elif id "$USER_NAME" >/dev/null 2>&1; then
    STAMP="$(date -u +%Y%m%d-%H%M%S)"; BK="/home/$USER_NAME/removed-backup-$STAMP.tar.gz"
    tar -czf "$BK" -C "/home/$USER_NAME" .claude work 2>/dev/null && info "backup → $BK" || warn "backup partial/failed (continuing)"
  else info "no home for $USER_NAME — nothing to back up"; fi
fi

# 2) revoke admin channel (idempotent — no-op if the user was not an admin)
log "2/4 revoke admin host-sudo channel (if any)"
[ -f "$HERE/runtime/install/unmake-admin.sh" ] && run_cmd bash "$RT_INSTALL/unmake-admin.sh" "$USER_NAME" || info "no unmake-admin.sh — skipping"

# 3) delete the tenant's OneCLI vault secrets (<user>-*), which the agent deletion leaves behind
log "3/4 delete OneCLI vault secrets '$USER_NAME-*'"
if [ "$DRY_RUN" = "1" ]; then info "would delete every OneCLI secret named '$USER_NAME-*' (exa/composio/git/etc.)"
elif command -v /usr/local/bin/onecli >/dev/null 2>&1; then
  HOME=/root /usr/local/bin/onecli secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('data',d) if isinstance(d,dict) else d
pre='${USER_NAME}-'
print('\n'.join(s['id'] for s in rows if isinstance(s,dict) and str(s.get('name','')).startswith(pre)))" 2>/dev/null | while read -r sid; do
    [ -n "$sid" ] || continue
    HOME=/root /usr/local/bin/onecli secrets delete --id "$sid" >/dev/null 2>&1 && info "deleted secret $sid" || true
  done
else info "onecli not present — skipping secret cleanup"; fi

# 4) deprovision (pod, agent, token, control-plane rows; --purge also userdels home)
log "4/4 deprovision tenant"
if [ "$PURGE" = "1" ]; then run_cmd bash "$RT_INSTALL/deprovision-tenant.sh" "$USER_NAME" --purge-user
else run_cmd bash "$RT_INSTALL/deprovision-tenant.sh" "$USER_NAME"; fi

log "remove-user '$USER_NAME' done"
