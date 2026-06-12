#!/usr/bin/env bash
# m5.12-live-stream-v2.sh apply|rollback [user]   (default user: vitaliy — pilot)
#
# M5.12 — extends the M5.11 live tool stream to full step semantics: wires the
# SAME activity hook command on PostToolUse (step finished: ok + duration) and
# SubagentStop (subagent completed) in the tenant's ~/.claude/settings.json.
# PreToolUse wiring from m5.11-live-tool-stream.sh stays as-is; this script is
# idempotent per event and only adds what's missing.
#
# Follows the ADR-003 authorized-edit flow: pause guard → edit → commit to the
# ~/.claude git HEAD (agentshield-gate heals FROM HEAD) → rebaseline golden →
# re-arm. Hooks load when claude starts → takes effect on the next pod restart
# (the rebuilt image must carry the v2 hook script in /opt/platform/hooks/).
#
# Rollback: removes the hook from PostToolUse + SubagentStop only (M5.11's
# PreToolUse entry has its own rollback in m5.11-live-tool-stream.sh).
set -euo pipefail

MODE="${1:?usage: m5.12-live-stream-v2.sh apply|rollback [user]}"
U="${2:-vitaliy}"
S="/home/${U}/.claude/settings.json"
FLAG=/etc/agentshield/operator-override.flag
HOOK_CMD="node /opt/platform/hooks/tool-activity-hook.mjs"
EVENTS=(PostToolUse SubagentStop)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$S" ] || { echo "no settings.json for ${U}" >&2; exit 1; }
case "$MODE" in apply|rollback) ;; *) echo "unknown mode: $MODE (apply|rollback)" >&2; exit 1 ;; esac

touch "$FLAG"
trap 'rm -f "$FLAG"' EXIT

changed=0
for EV in "${EVENTS[@]}"; do
  if [ "$MODE" = apply ]; then
    if jq -e --arg c "$HOOK_CMD" ".hooks.${EV}[]?.hooks[]? | select(.command == \$c)" "$S" >/dev/null 2>&1; then
      echo "  ${EV}: already wired"
      continue
    fi
    FILTER=".hooks.${EV} += [{\"hooks\":[{\"type\":\"command\",\"command\":\$c,\"timeout\":5}]}]"
  else
    FILTER=".hooks.${EV} |= (map(select(((.hooks // []) | any(.command == \$c)) | not)) | if length == 0 then empty else . end)"
  fi
  TMP="$(mktemp)"
  jq --arg c "$HOOK_CMD" "$FILTER" "$S" > "$TMP"
  python3 -c "import json,sys; json.load(open('${TMP}'))"
  install -m 0644 -o "$U" -g "$U" "$TMP" "$S"
  rm -f "$TMP"
  echo "  ${EV}: ${MODE} done"
  changed=1
done

if [ "$changed" = 1 ]; then
  # Durable: agentshield-gate restores settings.json from the ~/.claude git HEAD.
  sudo -u "$U" git -C "/home/${U}/.claude" add settings.json
  sudo -u "$U" git -C "/home/${U}/.claude" commit -m "M5.12 ${MODE}: PostToolUse+SubagentStop activity hook (live step semantics)"
  /usr/local/sbin/agentshield-settings-rebaseline "$U"
  echo "M5.12 ${MODE} done for ${U}. Hooks load at claude start — effective after pod restart."
else
  echo "M5.12 ${MODE}: nothing to change for ${U}."
fi
