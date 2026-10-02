#!/usr/bin/env bash
# Install (or remove) the firm's Sonnet subagent types for one tenant.
#
#   install-sonnet-agents.sh <user>              copy sonnet-agents/*.md -> /home/<user>/.claude/agents/
#   install-sonnet-agents.sh <user> --rollback   remove exactly those files again
#
# Why agent TYPES and not CLAUDE_CODE_SUBAGENT_MODEL: that env var moves every subagent of a
# pod at once (letters to clients included), and forks keep the main model anyway. A typed
# agent moves only the mechanical work it is described for (transcription, sourced research,
# data work); everything else stays on the session's model. Requires a Claude Code that knows
# claude-sonnet-5-5 (2.1.284+). A new session picks the agents up; running ones do not.
set -euo pipefail
U="${1:?usage: install-sonnet-agents.sh <user> [--rollback]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="/home/$U/.claude/agents"
id "$U" >/dev/null
if [ "${2:-}" = "--rollback" ]; then
  for f in "$HERE"/sonnet-agents/*.md; do rm -f "$D/$(basename "$f")"; done
  echo "$U: sonnet agents removed"; exit 0
fi
install -d -o "$U" -g "$U" -m 0755 "$D"
for f in "$HERE"/sonnet-agents/*.md; do install -o "$U" -g "$U" -m 0644 "$f" "$D/$(basename "$f")"; done
echo "$U: installed $(ls "$HERE"/sonnet-agents/*.md | wc -l) sonnet agents into $D"
