#!/usr/bin/env bash
# unmute-hijacked.sh [user ...]  — reclaim the Telegram slot from an App session.
#
# TRIAGE ONLY. The permanent fix is in entrypoint.sh: the rc listener is started with
# `env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_STATE_DIR`, so an App session cannot poll at all.
# This script exists for pods that have not restarted onto that build yet — recurrence is
# fast (a tenant with several App sessions was re-hijacked within minutes), so do not treat
# a successful run as the problem being solved.
#
# Detection: the Telegram poller IS the plugin's MCP server. Healthy means `bun server.ts`
# has `/usr/bin/claude --channels …` as its grandparent (the boot TUI). Anything else — in
# practice `claude.exe --print --sdk-url …` under `claude rc` — means an App session grabbed
# the single getUpdates slot, and since it has no --channels, inbound messages go nowhere.
#
# Repair: kill the plugin server, then respawn ONLY the bot window with --continue. The
# tenant's App sessions survive; a pod restart would destroy them.
#
# With no arguments, scans every running tenant pod and repairs the ones that are muted.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

owner_of() {   # $1=user → prints the poller's grandparent argv, empty if no poller
  local u="$1" tree pp gp
  tree="$(podman exec "claude-$u" sh -lc 'ps -eo pid,ppid,args' 2>/dev/null)" || return 1
  pp="$(printf '%s' "$tree" | grep '[b]un server.ts' | awk '{print $2}' | head -1)"
  [ -n "$pp" ] || return 1
  gp="$(printf '%s' "$tree" | awk -v p="$pp" '$1==p {print $2}')"
  printf '%s' "$tree" | awk -v g="$gp" '$1==g {for (i=3; i<=NF; i++) printf "%s ", $i}'
}

unmute() {
  local u="$1" uid start
  uid="$(id -u "$u")"
  # pane_start_command is the authoritative relaunch line; tmux lives on a per-tenant
  # socket dir, and a bare `-t claude` is ambiguous because the rc window is also named
  # "claude" — always target the session explicitly.
  start="$(podman exec -u "$uid" "claude-$u" sh -lc \
    "export TMUX_TMPDIR=/home/$u/.claude; tmux display-message -p -t claude: '#{pane_start_command}'" 2>/dev/null \
    | tr -d '"')"
  case "$start" in
    *"/usr/bin/claude --channels"*) : ;;
    *) echo "  $u: refusing — unexpected pane start command: ${start:-<empty>}" >&2; return 1 ;;
  esac
  podman exec -u "$uid" "claude-$u" sh -lc 'pkill -f "bun server\.ts"' >/dev/null 2>&1 || true
  sleep 3
  podman exec -u "$uid" "claude-$u" sh -lc \
    "export TMUX_TMPDIR=/home/$u/.claude; tmux respawn-window -k -t claude:0 \"$start --continue\"" >/dev/null 2>&1 \
    || { echo "  $u: respawn failed" >&2; return 1; }
  local i
  for i in $(seq 1 24); do
    sleep 5
    case "$(owner_of "$u")" in *"/usr/bin/claude --channels"*) echo "  $u: reclaimed after $((i*5))s"; return 0 ;; esac
  done
  echo "  $u: poller did not return to the boot session" >&2; return 1
}

users=("$@")
if [ ${#users[@]} -eq 0 ]; then
  mapfile -t users < <(podman ps --format '{{.Names}}' | sed -n 's/^claude-//p' | sort)
fi

rc=0
for u in "${users[@]}"; do
  own="$(owner_of "$u" || true)"
  if [ -z "$own" ]; then
    echo "$u: no poller running (pod down, or the channel is disabled) — skipped"
    continue
  fi
  case "$own" in
    *"/usr/bin/claude --channels"*) echo "$u: healthy" ;;
    *) echo "$u: MUTE — poller held by ${own:0:60}"; unmute "$u" || rc=1 ;;
  esac
done
exit $rc
