#!/usr/bin/env bash
# m-memory-guard.sh — the two halves of not being OOM-killed again.
#
#   apply     install the hourly App-session reaper + a swapfile
#   rollback  m-memory-guard-rollback.sh
#
# BACKGROUND (2026-09-07). The firm host went to load 547 on 8 cores with 31.7 GB of
# 32 GB used and NO swap: 85 Claude App sessions had accumulated in tenant pods, holding
# ~15 GB, because nothing ever ends them. sshd stopped answering, so the box could not be
# steered from inside, and the OOM killer was picking off tenants' bots at random.
#
# Two independent problems, so two independent fixes:
#   1. the leak — an hourly reaper ends `claude.exe --print` older than 24h;
#   2. the cliff — with zero swap, "out of memory" is instantly fatal instead of merely
#      slow, which is what took SSH away and made remote recovery nearly impossible.
#      Swap does not fix the leak; it buys the minutes needed to act.
#
# The reaper never calls a model — it reads /proc and signals processes — so it does not
# breach the standing rule against LLM calls on a timer.
set -euo pipefail

ACTION="${1:-apply}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SWAPFILE=/swapfile
SWAP_GB="${SWAP_GB:-8}"
BIN=/usr/local/sbin/reap-stale-app-sessions
UNIT_DIR=/etc/systemd/system

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$ACTION" = apply ] || die "use m-memory-guard-rollback.sh to undo"

# ── 1. the reaper ────────────────────────────────────────────────────────────
log "installing the reaper"
install -m 0755 "$HERE/reap-stale-app-sessions.sh" "$BIN"
install -m 0644 "$ROOT/systemd/reap-stale-app-sessions.service" "$UNIT_DIR/"
install -m 0644 "$ROOT/systemd/reap-stale-app-sessions.timer" "$UNIT_DIR/"
systemctl daemon-reload

log "dry run first — it must find candidates without ending anything"
"$BIN" --max-age-hours 24 --dry-run || die "dry run failed"

log "enabling the hourly timer"
systemctl enable --now reap-stale-app-sessions.timer >/dev/null
systemctl is-enabled reap-stale-app-sessions.timer >/dev/null || die "timer not enabled"
systemctl list-timers reap-stale-app-sessions.timer --no-pager | sed -n '1,3p'

# ── 2. swap ──────────────────────────────────────────────────────────────────
log "swap"
if swapon --show=NAME --noheadings | grep -q .; then
  echo "  swap already present:"
  swapon --show
else
  avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "$avail_gb" -gt $((SWAP_GB + 10)) ] || die "only ${avail_gb}G free on / — refusing to take ${SWAP_GB}G"
  echo "  creating ${SWAP_GB}G at $SWAPFILE (${avail_gb}G free)"
  # fallocate, not dd: instant, and dd is on the broker's destructive list.
  fallocate -l "${SWAP_GB}G" "$SWAPFILE" || die "fallocate failed"
  chmod 0600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null || die "mkswap failed"
  swapon "$SWAPFILE" || die "swapon failed"
  grep -q "^$SWAPFILE" /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
  echo "  persisted in /etc/fstab"
fi

# Low swappiness: this is an emergency cushion, not a reason to page out a busy box.
log "swappiness"
sysctl -w vm.swappiness=10 >/dev/null
printf 'vm.swappiness = 10\n' > /etc/sysctl.d/99-fleet-swappiness.conf
sysctl -n vm.swappiness | sed 's/^/  vm.swappiness = /'

log "state now"
free -h | sed -n '1,3p'
uptime

cat <<EOF

== DONE ==
reaper : $BIN, hourly via reap-stale-app-sessions.timer (24h cutoff)
swap   : $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')
Rollback: bash $HERE/m-memory-guard-rollback.sh
EOF
