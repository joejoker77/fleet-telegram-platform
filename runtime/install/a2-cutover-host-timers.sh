#!/usr/bin/env bash
# a2-cutover-host-timers.sh — A2 cutover: retire the per-user HOST deploy timers so
# the control-plane (cp-api) reconcile becomes the SOLE deploy path for a tenant.
#
# Disables (default) or re-enables (--rollback) BOTH:
#   skill-deploy@<user>.timer   mcp-deploy@<user>.timer
#
# PREREQUISITE before disabling: the cp-api reconcile must already be a live trigger
# for this tenant — i.e. the GitHub push webhook is activated (GITHUB_WEBHOOK_SECRET
# set on cp-api + repo webhook registered) OR you accept manual/admin-route triggers
# only. Otherwise nothing reconciles the tenant after the timers stop. Verify the
# cp-api path first:
#   podman exec cp-api node_modules/.bin/tsx \
#     /home/vitaliy/work/fleet-platform/control-plane/apps/api/src/deploy-reconcile.ts <user> --all
#   (expect changed=false == already in sync with the repo)
#
# ROLLBACK (one command): a2-cutover-host-timers.sh <user> --rollback
# Idempotent. Run as root.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

USER_ARG="${1:?usage: a2-cutover-host-timers.sh <user> [--rollback]}"
MODE="${2:-disable}"
UNITS=("skill-deploy@${USER_ARG}.timer" "mcp-deploy@${USER_ARG}.timer")

show() {
  for u in "${UNITS[@]}"; do
    printf '  %-34s active=%s enabled=%s\n' "$u" \
      "$(systemctl is-active "$u" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$u" 2>/dev/null || true)"
  done
}

echo "== A2 host-timer cutover for '$USER_ARG' (mode: $MODE) =="
echo "before:"; show

case "$MODE" in
  disable|"")
    for u in "${UNITS[@]}"; do
      systemctl disable --now "$u" 2>&1 | sed 's/^/  /' || true
    done
    echo "-> host deploy timers STOPPED + DISABLED. cp-api reconcile is now the sole path."
    echo "   rollback: $0 $USER_ARG --rollback"
    ;;
  --rollback|rollback)
    for u in "${UNITS[@]}"; do
      systemctl enable --now "$u" 2>&1 | sed 's/^/  /' || true
    done
    echo "-> host deploy timers RE-ENABLED + STARTED (reverted to pre-cutover state)."
    ;;
  *)
    echo "unknown mode '$MODE' (use nothing to disable, or --rollback)" >&2; exit 2 ;;
esac

echo "after:"; show
