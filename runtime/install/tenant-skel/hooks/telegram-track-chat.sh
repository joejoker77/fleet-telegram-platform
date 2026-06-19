#!/bin/bash
# UserPromptSubmit hook
# Captures the most recent Telegram <channel> tag's chat_id + message_thread_id
# from the user prompt and saves it to $TELEGRAM_STATE_DIR/last_chat.json so
# other hooks (e.g. AskUserQuestion blocker) know where to send messages.

set -e

[ -z "${TELEGRAM_STATE_DIR:-}" ] && exit 0
[ ! -d "$TELEGRAM_STATE_DIR" ] && exit 0

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

# Find the LAST <channel source="plugin:telegram:telegram" ...> tag in the prompt.
LAST_TAG=$(printf '%s' "$PROMPT" | grep -oE '<channel source="plugin:telegram:telegram"[^>]*>' | tail -1)
[ -z "$LAST_TAG" ] && exit 0

CHAT_ID=$(printf '%s' "$LAST_TAG" | sed -n 's/.*chat_id="\([^"]*\)".*/\1/p')
THREAD_ID=$(printf '%s' "$LAST_TAG" | sed -n 's/.*message_thread_id="\([^"]*\)".*/\1/p')

[ -z "$CHAT_ID" ] && exit 0

jq -n --arg c "$CHAT_ID" --arg t "$THREAD_ID" \
  '{chat_id:$c, message_thread_id:$t, ts:(now|tostring)}' \
  > "$TELEGRAM_STATE_DIR/last_chat.json"

exit 0
