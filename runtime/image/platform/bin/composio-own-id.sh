# shellcheck shell=bash
# composio-own-id.sh — the cross-tenant isolation guard for the composio helpers.
# Sourced by composio-connect / composio-session / composio-exec.
#
# WHY THIS EXISTS (2026-11-13): a Composio `user_id` IS the privacy boundary.
# Every connected account created under an id is readable by anyone who can pass
# that id, and each pod can pass any id it likes. One tenant's assistant used a
# COLLEAGUE's chat_id when connecting its own owner's Outlook, Google Drive,
# Calendar and Slack — so those accounts sat in the colleague's pot and that
# colleague's assistant could read the CEO's mail. Nothing malicious happened;
# a stale note in that assistant's memory held the wrong number and the helpers
# accepted it without a word.
#
# So: a workspace may only ever use ITS OWN owner's Telegram chat_id. The id is
# read from the channel's access.json (the DM allow-list, under ~/.claude, which
# AgentShield protects), the same source pd-attachments uses.
#
# This is a guard on the normal path, not a wall: the helpers are how the
# assistant reaches Composio, but a hand-written call to backend.composio.dev
# still carries the platform key. The wall belongs in the egress proxy, which
# would have to check user_id in the body against the calling tenant.

composio_own_ids() {
  local state="${TELEGRAM_STATE_DIR:-$HOME/.claude/channels/telegram-${USER_NAME:-$(id -un)}}"
  python3 - "$state" <<'PY' 2>/dev/null
import json, os, sys
state = sys.argv[1]
ids = []
try:
    with open(os.path.join(state, "access.json")) as fh:
        data = json.load(fh)
    for raw in (data.get("allowFrom") or []):
        s = str(raw).strip()
        if s.isdigit():
            ids.append(s)
except Exception:
    pass
print(" ".join(ids))
PY
}

# composio_assert_own_user <user_id> — exit 3 unless it is this workspace's own.
composio_assert_own_user() {
  local want="$1" own
  own="$(composio_own_ids)"
  if [ -z "$own" ]; then
    echo "ERROR: cannot tell whose workspace this is (no usable access.json), so --user-id is refused." >&2
    echo "       A Composio user_id decides whose accounts these are; it is not safe to guess." >&2
    return 3
  fi
  case " $own " in
    *" $want "*) return 0 ;;
  esac
  echo "ERROR: --user-id $want is not this workspace's own Telegram id ($own)." >&2
  echo "       A Composio user_id is the privacy boundary: every account connected under it" >&2
  echo "       can be read by that person's assistant. Connect your own accounts under your" >&2
  echo "       own id; a colleague's accounts are connected by their own assistant." >&2
  return 3
}
