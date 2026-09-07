#!/usr/bin/env bash
# reap-stale-app-sessions.sh — end abandoned Claude App / remote-control sessions.
#
#   reap-stale-app-sessions.sh [--max-age-hours N] [--dry-run]
#
# WHY THIS EXISTS. Every session the Claude App opens in a tenant pod is a
# `claude.exe --print --sdk-url …` process under that tenant's `claude rc` listener, and
# nothing ever ends it. On the firm host (2026-09-07) 85 of them had piled up — 30 of
# them three days old — holding ~15 GB between them on a 32 GB box with NO swap. The
# result was load 547 on 8 cores, 97% of CPU time in the kernel, the OOM killer picking
# off tenants' bots at random, and the host refusing new SSH logins.
#
# WHAT IT TOUCHES, AND WHAT IT MUST NOT. Only `claude.exe --print` processes older than
# the cutoff. Never the boot session (`/usr/bin/claude --channels …`) — that is the
# Telegram bot itself — and never the `claude rc` listener, which must stay up so the App
# can reconnect. A tenant's App conversation is resumable server-side, so ending an idle
# one costs them nothing; leaving it running costs everyone the box.
#
# NOT AN LLM CALL. This is process bookkeeping. It never invokes a model, so it is safe
# to put on a timer (see the hard rule about recurring LLM calls in the tenant guides).
set -uo pipefail

MAX_AGE_HOURS=24
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max-age-hours) MAX_AGE_HOURS="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

MINAGE=$((MAX_AGE_HOURS * 3600))
now=$(date +%s)
targets=""
freed_kb=0

for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  [ -r "/proc/$pid/cmdline" ] || continue
  args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
  case "$args" in
    *claude.exe*--print*) : ;;
    *) continue ;;
  esac
  # /proc/<pid> mtime is the process start time; cheaper and race-free enough here.
  start=$(stat -c %Y "/proc/$pid" 2>/dev/null || echo "$now")
  age=$((now - start))
  [ "$age" -ge "$MINAGE" ] || continue
  rss=$(awk '/^VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
  user=$(stat -c %U "/proc/$pid" 2>/dev/null || echo "?")
  printf '  %-8s %-20s age=%3sh rss=%5sMB\n' "$pid" "$user" "$((age/3600))" "$((rss/1024))"
  targets="$targets $pid"
  freed_kb=$((freed_kb + rss))
done

n=$(echo "$targets" | wc -w)
echo "  ---- $n session(s) older than ${MAX_AGE_HOURS}h, $((freed_kb/1024)) MB resident"
[ "$n" -gt 0 ] || { echo "nothing to do"; exit 0; }
[ "$DRY" = 1 ] && { echo "dry run — nothing ended"; exit 0; }

for p in $targets; do kill -TERM "$p" 2>/dev/null || true; done
sleep 20
left=""
for p in $targets; do [ -d "/proc/$p" ] && left="$left $p"; done
if [ -n "${left# }" ]; then
  echo "  $(echo "$left" | wc -w) ignored TERM — sending KILL"
  for p in $left; do kill -KILL "$p" 2>/dev/null || true; done
  sleep 5
fi
gone=0
for p in $targets; do [ -d "/proc/$p" ] || gone=$((gone+1)); done
echo "  ended $gone of $n"
free -m | sed -n '2p'
