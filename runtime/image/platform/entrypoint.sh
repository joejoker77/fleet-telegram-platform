#!/usr/bin/env bash
# M3.0 — user runtime entrypoint. Faithful port of /usr/local/bin/claude-tg-launcher
# adapted for the container: launches `claude` with the official Telegram plugin
# channel (no plugin patch) in a supervised tmux session, seeds prior-session
# context, and runs code-server. Differences from the host launcher:
#   - model/secret egress env (HTTPS_PROXY + onecli CA) is provided by the pod
#     wrapper (claude-pod-run) for the cl-net path; we PRESERVE it so the bot's
#     .env can't clobber it with the host-loopback proxy.
#   - HOME/uid come from the container (--user + -e HOME).
set -u

USER_NAME="$(basename "$HOME")"
export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-$HOME/.claude/channels/telegram-$USER_NAME}"
export TMUX_TMPDIR="$HOME/.claude"
mkdir -p "$TMUX_TMPDIR"
SESSION="claude"

# best-effort audit: runtime started
AUDIT_SOCK="${AUDIT_SOCKET:-/run/audit/collector.sock}"
[ -S "$AUDIT_SOCK" ] && printf '%s\n' \
  "{\"userId\":null,\"kind\":\"runtime.start\",\"actor\":\"$USER_NAME\",\"payload\":{}}" \
  | timeout 2 socat - "UNIX-CONNECT:$AUDIT_SOCK" 2>/dev/null || true

# Source the tenant's bot env (TELEGRAM_BOT_TOKEN, etc.) WITHOUT letting it
# override the egress proxy/CA the wrapper set for the cl-net path.
_HP="${HTTPS_PROXY:-}"; _NP="${NO_PROXY:-}"; _CA="${NODE_EXTRA_CA_CERTS:-}"
if [ -f "$TELEGRAM_STATE_DIR/.env" ]; then
  set -a; . "$TELEGRAM_STATE_DIR/.env"; set +a
fi
if [ -n "$_HP" ]; then
  export HTTPS_PROXY="$_HP" HTTP_PROXY="$_HP" NO_PROXY="$_NP"
  export NODE_EXTRA_CA_CERTS="$_CA" SSL_CERT_FILE="$_CA" REQUESTS_CA_BUNDLE="$_CA" CURL_CA_BUNDLE="$_CA"
fi

# code-server (web IDE; reverse-proxied by Caddy at M5)
command -v code-server >/dev/null 2>&1 && \
  code-server --bind-addr 127.0.0.1:8443 --auth none "$HOME/work" >/tmp/code-server.log 2>&1 &

# Ensure THIS container's workspace is trusted in ~/.claude.json, else Claude Code
# stops at the per-project trust prompt ("Is this a project you trust?") and hangs
# the non-interactive pane (no session -> no plugin). Per-project, keyed by path:
# a seeded .claude.json only trusts the donor's workspace, so a tenant whose path
# differs (e.g. the m3smoke test tenant) re-prompts. Idempotent: writes only on a
# real change, so it's a no-op when the path is already trusted (the live cutover).
CJ="$HOME/.claude.json" WORKDIR="$HOME/work" python3 - <<'PY' 2>/dev/null || true
import json, os
p, work = os.environ["CJ"], os.environ["WORKDIR"]
try:
    d = json.load(open(p))
except Exception:
    d = {}
before = json.dumps(d, sort_keys=True)
d.setdefault("hasCompletedOnboarding", True)
d.setdefault("trustDialogAccepted", True)
proj = d.setdefault("projects", {}).setdefault(work, {})
proj["hasTrustDialogAccepted"] = True
proj["hasCompletedProjectOnboarding"] = True
if json.dumps(d, sort_keys=True) != before:
    # Write IN-PLACE. ~/.claude.json is a bind-mounted file; os.replace()/rename()
    # ONTO a mount point fails with EBUSY (the write then silently no-ops, leaving
    # the donor's trusted paths only -> Claude re-prompts -> crash loop). Truncating
    # and writing the mounted inode itself is allowed even under --read-only.
    with open(p, "w") as f:
        json.dump(d, f, indent=2)
PY

# M4.1 — seed shellfirm per-user state. ~/.config is NOT a mounted volume, so the
# host's per-user config doesn't carry into the container; seed it here (idempotent).
# The PreToolUse hook (/usr/local/bin/shellfirm-bot-wrapper) is already wired in the
# tenant's mounted ~/.claude/settings.json; this just makes the binary's config sane:
#   - agent mode (auto-deny High, no interactive prompt that would hang the pane)
#   - disable the built-in `fs` group (too aggressive for an AI agent on its own files)
#   - ensure the cwd-loaded policy exists at ~/work/.shellfirm.yaml (shellfirm reads
#     .shellfirm.yaml from the working dir; bot cwd is $HOME/work)
if command -v shellfirm >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/shellfirm"
  if [ ! -f "$HOME/.config/shellfirm/settings.yaml" ]; then
    cat > "$HOME/.config/shellfirm/settings.yaml" <<'SFEOF'
# shellfirm settings — bot agent mode (seeded by runtime entrypoint)
agent:
  auto_deny_severity: High
audit_enabled: true
blast_radius: true
SFEOF
  fi
  shellfirm config groups --disable fs >/dev/null 2>&1 || true
  if [ -d "$HOME/work" ] && [ ! -f "$HOME/work/.shellfirm.yaml" ] && [ -f /etc/shellfirm/policy.yaml ]; then
    cp /etc/shellfirm/policy.yaml "$HOME/work/.shellfirm.yaml" 2>/dev/null || true
  fi
fi

# Claude + official Telegram plugin channel (no patch), or remote-only if opted out.
REMOTE_CONTROL_NAME="${REMOTE_CONTROL_NAME:-$USER_NAME-main}"
if [ "${DISABLE_TELEGRAM_CHANNEL:-0}" = "1" ]; then
  CLAUDE_CMD="/usr/bin/claude --remote-control $REMOTE_CONTROL_NAME"
else
  CLAUDE_CMD="/usr/bin/claude --channels plugin:telegram@claude-plugins-official --remote-control $REMOTE_CONTROL_NAME"
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true
TMUX_CFG="$(mktemp)"; trap 'rm -f "$TMUX_CFG"' EXIT
echo "set-option -g history-limit 100000" > "$TMUX_CFG"
tmux -f "$TMUX_CFG" new-session -d -s "$SESSION" -x 200 -y 60 "exec $CLAUDE_CMD"
# Non-destructively capture the pane (claude's TUI/errors) to a log so launch
# failures are diagnosable from the host (the pty itself is preserved).
mkdir -p "$TELEGRAM_STATE_DIR/logs"
tmux pipe-pane -t "$SESSION" -o "cat >> '$TELEGRAM_STATE_DIR/logs/claude-pane.log'" 2>/dev/null || true

# Seed prior-session context (same logic as the host launcher; silent restore).
(
  sleep 15
  LOG_FILE="$TELEGRAM_STATE_DIR/logs/session_current.txt"
  ROT_DIR=$(dirname "$LOG_FILE")
  ROT_LATEST=$(ls -t "$ROT_DIR"/session_*.txt 2>/dev/null | grep -v "/$(basename "$LOG_FILE")$" | head -1)
  if ! [ -s "$LOG_FILE" ] && [ -z "$ROT_LATEST" ]; then exit 0; fi
  if [ -s "$LOG_FILE" ] && [ -n "$ROT_LATEST" ]; then
    TAIL=$({ tail -n 400 "$ROT_LATEST"; tail -n 400 "$LOG_FILE"; } | tail -n 400)
  elif [ -s "$LOG_FILE" ]; then
    TAIL=$(tail -n 400 "$LOG_FILE")
  else
    TAIL=$(tail -n 400 "$ROT_LATEST")
  fi
  [ -n "$TAIL" ] || exit 0
  HEADER='⟪SESSION-RESTORE — context only, do NOT reply in Telegram unless followed by an actual user message⟫'
  MSG_FILE=$(mktemp -t session_restore.XXXXXX)
  {
    echo "$HEADER"; echo
    echo "Below is the tail of the previous Claude session in this bot. Read it silently to recover continuity. If the previous session was mid-task, be ready to resume from where it left off when the user next writes."
    echo; echo '----- BEGIN PREVIOUS SESSION TAIL -----'; echo "$TAIL"; echo '----- END PREVIOUS SESSION TAIL -----'
  } > "$MSG_FILE"
  tmux load-buffer -b session_restore "$MSG_FILE"
  tmux paste-buffer -t "$SESSION" -b session_restore -d -p
  rm -f "$MSG_FILE"
  sleep 0.4
  tmux send-keys -t "$SESSION" Enter
) &

# Supervise: exit (→ unit Restart) when the claude session ends.
while tmux has-session -t "$SESSION" 2>/dev/null; do sleep 5; done
exit 1
