#!/bin/bash
# Live in-chat PROGRESS for the Telegram bot — a NO-PLUGIN-PATCH reimplementation
# of the fleet's patched-plugin progress (armPostReplyWatchdog/status_update).
# The clean official plugin has no status_update tool, so we post directly to the
# Telegram Bot API (bot token from the per-session .env, chat from last_chat.json
# written by telegram-track-chat.sh) — exactly the pattern telegram-block-askuser.sh
# already uses. ONE evolving status message per turn (edited in place, no spam,
# edits don't push-notify); deleted when the bot sends its real reply.
#
# Wired on TWO events (branches on hook_event_name):
#   PreToolUse  → upsert "⚙️ <tool>: <summary>"  (skips the telegram tools themselves)
#   PostToolUse → if the tool was the telegram reply, DELETE the status (answer is in chat)
#
# Hard rules: never blocks/influences the tool (no stdout; always exit 0), never
# throws, fire-and-forget with short curl timeouts.
set +e
[ -z "${TELEGRAM_STATE_DIR:-}" ] && exit 0
[ -d "$TELEGRAM_STATE_DIR" ] || exit 0

INPUT=$(cat 2>/dev/null)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
TOOL=$(printf '%s'  "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
PF="$TELEGRAM_STATE_DIR/progress.json"

# bot token (per-session .env) + destination chat (last seen inbound message)
TOKEN=""
[ -f "$TELEGRAM_STATE_DIR/.env" ] && \
  TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$TELEGRAM_STATE_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"'"'"'')
[ -z "$TOKEN" ] && exit 0
API="https://api.telegram.org/bot${TOKEN}"

# ---- PostToolUse: clear the status when the bot actually replied --------------
if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL" in
    mcp__plugin_telegram_telegram__reply)
      [ -f "$PF" ] || exit 0
      C=$(jq -r '.chat_id // ""' "$PF" 2>/dev/null); M=$(jq -r '.message_id // ""' "$PF" 2>/dev/null)
      [ -n "$C" ] && [ -n "$M" ] && curl -s -m 8 -X POST "$API/deleteMessage" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg c "$C" --argjson m "$M" '{chat_id:$c,message_id:$m}')" >/dev/null 2>&1
      rm -f "$PF"
      ;;
  esac
  exit 0
fi

# ---- PreToolUse: upsert the activity status -----------------------------------
[ "$EVENT" = "PreToolUse" ] || exit 0
[ -n "$TOOL" ] || exit 0
# don't narrate the telegram channel tools themselves (reply/react/status/edit/...) — noise
case "$TOOL" in mcp__plugin_telegram_telegram__*) exit 0;; esac

CHAT_ID=""; THREAD=""
if [ -f "$TELEGRAM_STATE_DIR/last_chat.json" ]; then
  CHAT_ID=$(jq -r '.chat_id // ""' "$TELEGRAM_STATE_DIR/last_chat.json" 2>/dev/null)
  THREAD=$(jq -r '.message_thread_id // ""' "$TELEGRAM_STATE_DIR/last_chat.json" 2>/dev/null)
fi
[ -z "$CHAT_ID" ] && exit 0

# one-line, glanceable summary of what the tool is about to do
SUM=$(printf '%s' "$INPUT" | jq -r '
  .tool_input as $i
  | if .tool_name=="Bash" then ($i.command // "")
    elif (.tool_name|test("^(Read|Write|Edit)$")) then ($i.file_path // "")
    elif .tool_name=="NotebookEdit" then ($i.notebook_path // "")
    elif (.tool_name|test("^(Grep|Glob)$")) then ($i.pattern // "")
    elif (.tool_name|test("^(Task|Agent)$")) then (($i.subagent_type // "agent") + " — " + ($i.description // $i.prompt // ""))
    elif .tool_name=="Skill" then (($i.skill // "") + " " + ($i.args // ""))
    elif .tool_name=="WebFetch" then ($i.url // "")
    elif .tool_name=="WebSearch" then ($i.query // "")
    else ([ $i[]? | select(type=="string") ][0] // "")
    end' 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
SUM=$(printf '%s' "$SUM" | cut -c1-160)
TEXT="⚙️ ${TOOL}${SUM:+: }${SUM}"

upsert_send() {
  local payload resp newid
  payload=$(jq -n --arg c "$CHAT_ID" --arg t "$TEXT" --arg th "$THREAD" \
    'if $th!="" and $th!="null" then {chat_id:$c,message_thread_id:($th|tonumber),text:$t} else {chat_id:$c,text:$t} end' 2>/dev/null)
  resp=$(curl -s -m 8 -X POST "$API/sendMessage" -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
  newid=$(printf '%s' "$resp" | jq -r '.result.message_id // ""' 2>/dev/null)
  [ -n "$newid" ] && jq -n --arg m "$newid" --arg c "$CHAT_ID" '{message_id:($m|tonumber),chat_id:$c}' > "$PF" 2>/dev/null
}

MID=""
[ -f "$PF" ] && MID=$(jq -r '.message_id // ""' "$PF" 2>/dev/null)
if [ -n "$MID" ] && [ "$MID" != "null" ]; then
  resp=$(curl -s -m 8 -X POST "$API/editMessageText" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$CHAT_ID" --argjson m "$MID" --arg t "$TEXT" '{chat_id:$c,message_id:$m,text:$t}')" 2>/dev/null)
  ok=$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)
  # "message is not modified" → ok=false but harmless; only resend if the message is gone
  if [ "$ok" != "true" ]; then
    desc=$(printf '%s' "$resp" | jq -r '.description // ""' 2>/dev/null)
    case "$desc" in *"not modified"*) : ;; *) upsert_send ;; esac
  fi
else
  upsert_send
fi
exit 0
