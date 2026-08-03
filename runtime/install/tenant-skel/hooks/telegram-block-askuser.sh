#!/bin/bash
# PreToolUse hook for AskUserQuestion.
# Telegram-bot sessions have no human watching the terminal — a popup hangs
# the session silently. This hook mirrors the question to Telegram and blocks
# the tool so Claude is forced to use the reply tool instead.

set -e

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
[ "$TOOL_NAME" != "AskUserQuestion" ] && exit 0

# Build a human-readable rendering of the questions array.
QUESTIONS_TEXT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.questions // []
  | map(
      "❓ " + .question + "\n" +
      ((.options // [])
        | map("  • " + (.label // "") + (if .description and .description != "" then " — " + .description else "" end))
        | join("\n"))
    )
  | join("\n\n")
' 2>/dev/null || echo "AskUserQuestion intercepted (failed to render details).")

# Locate destination chat from the last-seen Telegram message.
CHAT_ID=""
THREAD_ID=""
if [ -n "${TELEGRAM_STATE_DIR:-}" ] && [ -f "$TELEGRAM_STATE_DIR/last_chat.json" ]; then
  CHAT_ID=$(jq -r '.chat_id // ""' "$TELEGRAM_STATE_DIR/last_chat.json")
  THREAD_ID=$(jq -r '.message_thread_id // ""' "$TELEGRAM_STATE_DIR/last_chat.json")
fi

# Bot token from per-session .env.
TOKEN=""
if [ -n "${TELEGRAM_STATE_DIR:-}" ] && [ -f "$TELEGRAM_STATE_DIR/.env" ]; then
  TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$TELEGRAM_STATE_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
fi

# Best-effort send. Failures don't change the block decision below.
if [ -n "$TOKEN" ] && [ -n "$CHAT_ID" ]; then
  # English only: this text goes to the firm's users, who do not read Russian. (The Russian
  # original came straight from the fleet, where the operator does.)
  TEXT="⚠️ I need to ask you something, but the assistant tried to use an on-screen prompt that
nobody can answer from Telegram. Here is the question:

$QUESTIONS_TEXT

Just reply to this message normally and I will carry on."
  if [ -n "$THREAD_ID" ]; then
    PAYLOAD=$(jq -n --arg c "$CHAT_ID" --argjson t "$THREAD_ID" --arg x "$TEXT" \
      '{chat_id:$c, message_thread_id:$t, text:$x}')
  else
    PAYLOAD=$(jq -n --arg c "$CHAT_ID" --arg x "$TEXT" \
      '{chat_id:$c, text:$x}')
  fi
  curl -s -m 10 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" > /dev/null 2>&1 || true
fi

# Block the tool. Stderr on exit 2 is fed back to Claude as a tool error.
cat >&2 <<'MSG'
AskUserQuestion is disabled in Telegram-bot sessions because the popup hangs the session silently — nobody is watching the terminal. The question and options have already been forwarded to the user via Telegram. End your turn and wait for the next inbound Telegram message; do not retry AskUserQuestion. If you still need to ask, send the question through the Telegram reply tool instead.
MSG
exit 2
