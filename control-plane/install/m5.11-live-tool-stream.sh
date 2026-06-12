#!/usr/bin/env bash
# m5.11-live-tool-stream.sh apply|rollback [user]   (default user: vitaliy — pilot)
#
# Wires (or removes) the M5.11 PreToolUse activity hook in the tenant's
# ~/.claude/settings.json: every tool call emits a `tool.use` audit event →
# LiveActivity streams the bot's steps in real time.
#
# Follows the ADR-003 authorized-edit flow: pause guard → edit → commit to the
# ~/.claude git HEAD (agentshield-gate heals FROM HEAD) → rebaseline golden →
# re-arm. Hooks load when claude starts → takes effect on the next pod restart
# (rides the pending M5.8 image rebuild, which also bakes the hook script into
# /opt/platform/hooks/).
#
# Rollback: m5.11-live-tool-stream.sh rollback   (same flow, removes the entry)
set -euo pipefail

MODE="${1:?usage: m5.11-live-tool-stream.sh apply|rollback [user]}"
U="${2:-vitaliy}"
S="/home/${U}/.claude/settings.json"
FLAG=/etc/agentshield/operator-override.flag
HOOK_CMD="node /opt/platform/hooks/tool-activity-hook.mjs"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$S" ] || { echo "no settings.json for ${U}" >&2; exit 1; }

if [ "$MODE" = apply ]; then
  if jq -e --arg c "$HOOK_CMD" '[.hooks.PreToolUse[]?.hooks[]? | select(.command == $c)] | length > 0' "$S" >/dev/null; then
    echo "already wired for ${U} — nothing to do"
    exit 0
  fi
  # No matcher = matches every tool (subagent tool calls included).
  FILTER='.hooks.PreToolUse += [{"hooks":[{"type":"command","command":$c,"timeout":5}]}]'
elif [ "$MODE" = rollback ]; then
  FILTER='.hooks.PreToolUse |= map(select(((.hooks // []) | any(.command == $c)) | not))'
else
  echo "unknown mode: $MODE (apply|rollback)" >&2
  exit 1
fi

touch "$FLAG"
trap 'rm -f "$FLAG"' EXIT

TMP="$(mktemp)"
jq --arg c "$HOOK_CMD" "$FILTER" "$S" > "$TMP"
python3 -c "import json,sys; json.load(open('${TMP}'))"
install -m 0644 -o "$U" -g "$U" "$TMP" "$S"
rm -f "$TMP"

# Durable: agentshield-gate restores settings.json from the ~/.claude git HEAD.
sudo -u "$U" git -C "/home/${U}/.claude" add settings.json
sudo -u "$U" git -C "/home/${U}/.claude" commit -m "M5.11 ${MODE}: PreToolUse tool-activity hook (live step stream)"
/usr/local/sbin/agentshield-settings-rebaseline "$U"

echo "M5.11 ${MODE} done for ${U}. Hooks load at claude start — effective after pod restart."
