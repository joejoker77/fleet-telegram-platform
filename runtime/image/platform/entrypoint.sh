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

# Clear any stale bot.pid LEFT BY A PREVIOUS POD. $TELEGRAM_STATE_DIR lives on the
# mounted ~/.claude volume, so the plugin's pidfile survives a pod restart — its
# PID is meaningless in this fresh PID namespace and could even collide with an
# unrelated live process, falsely telling the liveness-watchdog (below) that the
# channel is already up. The plugin rewrites it the moment it starts polling, so
# clearing it now (BEFORE launching claude) is safe and gives the watchdog a clean
# slate. Must happen pre-launch — never delete a pidfile the new plugin just wrote.
rm -f "$TELEGRAM_STATE_DIR/bot.pid"

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

# code-server (web IDE). M5.6: when the pod wrapper provides CP_IDE_SOCKET
# (claude-pod-run, conditional on host /run/cp-ide), bind a unix socket in the
# bind-mounted dir — zero network exposure; nginx reaches it on the host side
# behind auth_request (deploy/nginx-ide.conf). --auth none stays sound because
# the ONLY path to the socket is nginx and every request passes forward-auth.
# Without the env: legacy loopback tcp inside the pod netns (pre-M5.6 behavior).
if command -v code-server >/dev/null 2>&1; then
  if [ -n "${CP_IDE_SOCKET:-}" ]; then
    # the socket dir is host tmpfs that SURVIVES a pod restart — a stale socket
    # file would make the new code-server fail to bind. We own it; clear it.
    rm -f "$CP_IDE_SOCKET" 2>/dev/null || true
    code-server --socket "$CP_IDE_SOCKET" --socket-mode 0660 --auth none \
      "$HOME/work" >/tmp/code-server.log 2>&1 &
  else
    code-server --bind-addr 127.0.0.1:8443 --auth none "$HOME/work" >/tmp/code-server.log 2>&1 &
  fi
fi

# Ensure a workspace dir is trusted in ~/.claude.json, else Claude Code
# stops at the per-project trust prompt ("Is this a project you trust?") and hangs
# the non-interactive pane (no session -> no plugin). Per-project, keyed by path:
# a seeded .claude.json only trusts the donor's workspace, so a tenant whose path
# differs (e.g. the m3smoke test tenant) re-prompts. Idempotent: writes only on a
# real change, so it's a no-op when the path is already trusted (the live cutover).
# M5.7: factored into a function — every session dir we launch into must be
# trusted the same way (a new project dir would otherwise hang the pane).
trust_workdir() {
  CJ="$HOME/.claude.json" WORKDIR="$1" python3 - <<'PY' 2>/dev/null || true
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
}

# M4.1 — seed shellfirm per-user state. ~/.config IS a mounted volume (claude-pod-run
# mounts it precisely for this block — the rootfs is --read-only, so any $HOME path the
# entrypoint writes must be a volume; 2026-06-10 incident: missing mount → mkdir died on
# the RO overlay and the whole pod failed to start). Seed it here (idempotent).
# The PreToolUse hook (/usr/local/bin/shellfirm-bot-wrapper) is already wired in the
# tenant's mounted ~/.claude/settings.json; this just makes the binary's config sane:
#   - agent mode (auto-deny High, no interactive prompt that would hang the pane)
#   - disable the built-in `fs` group (too aggressive for an AI agent on its own files)
#   - ensure the cwd-loaded policy exists at ~/work/.shellfirm.yaml (shellfirm reads
#     .shellfirm.yaml from the working dir; bot cwd is $HOME/work)
# Degrade, don't die: if the mount is absent the seed is skipped with a loud warning —
# shellfirm falls back to defaults; a missing nicety must not take the tenant down.
if command -v shellfirm >/dev/null 2>&1 && mkdir -p "$HOME/.config/shellfirm" 2>/dev/null; then
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
elif command -v shellfirm >/dev/null 2>&1; then
  echo "WARN: ~/.config not writable (volume missing?) — shellfirm seed skipped, running with defaults" >&2
fi

# Claude + official Telegram plugin channel (no patch), or remote-only if opted out.
REMOTE_CONTROL_NAME="${REMOTE_CONTROL_NAME:-$USER_NAME-main}"
if [ "${DISABLE_TELEGRAM_CHANNEL:-0}" = "1" ]; then
  CLAUDE_CMD="/usr/bin/claude --remote-control $REMOTE_CONTROL_NAME"
else
  CLAUDE_CMD="/usr/bin/claude --channels plugin:telegram@claude-plugins-official --remote-control $REMOTE_CONTROL_NAME"
fi

# ── M5.7 named sessions/projects (docs/M5.7-sessions-design.md) ──────────────
# A session = a project dir (~/work = "default", else ~/work/projects/<name>) +
# its per-cwd claude conversation. Exactly ONE claude runs (telegram singleton);
# switching respawns the pane in the new dir. Control files live on the mounted
# ~/.claude volume; cp-api / session-ctl write the request, WE (the supervisor)
# execute it and write the result — single writer per file, no races.
RUN_DIR="$HOME/.claude/run"
mkdir -p "$RUN_DIR"
SWITCH_REQ="$RUN_DIR/session-switch.json"
SWITCH_RES="$RUN_DIR/session-switch.result.json"
ACTIVE_FILE="$RUN_DIR/active-session"
# a request that survived a pod restart is stale — never execute it blind
rm -f "$SWITCH_REQ" "$SWITCH_RES"

session_dir() { # name → absolute dir on stdout; empty = invalid name
  case "$1" in
    default) echo "$HOME/work" ;;
    *) printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,31}$' \
         && echo "$HOME/work/projects/$1" ;;
  esac
}

resume_flag() { # dir → "--continue" iff a prior conversation exists for this cwd
  # Claude Code keeps per-project state under ~/.claude/projects/<path-slug>
  # (slug = path with / and . mapped to -). `claude --continue` with NO prior
  # conversation exits immediately → dead pane → supervisor restart loop, so
  # the flag is added only when there is something to continue.
  local slug
  slug=$(printf '%s' "$1" | tr '/.' '--')
  if ls "$HOME/.claude/projects/$slug"/*.jsonl >/dev/null 2>&1; then
    echo "--continue"
  fi
}

# Seed per-project MCP approvals for a session dir. Claude discovers
# ~/work/.mcp.json from subdirs too, but the approval (enabledMcpjsonServers)
# is per-project in <dir>/.claude/settings.local.json — without it a FRESH
# session blocks forever on the interactive "New MCP server found" dialog:
# the telegram plugin never starts, the bot is mute, and the liveness watchdog
# restarts the whole pod (2026-06-11 incident; the restore-seed's Enter then
# answered the dialog by accident). The servers in ~/work/.mcp.json are
# platform-vetted (M5.5 gate), so a new session dir inherits the same approval.
seed_mcp_approvals() { # $1 = session dir
  local dir="$1" src="$HOME/work/.claude/settings.local.json"
  [ "$dir" = "$HOME/work" ] && return 0
  [ -f "$src" ] || return 0
  [ -f "$dir/.claude/settings.local.json" ] && return 0
  mkdir -p "$dir/.claude" 2>/dev/null || return 0
  SRC="$src" DST="$dir/.claude/settings.local.json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: s = json.load(open(os.environ["SRC"]))
except Exception: s = {}
out = {k: s[k] for k in ("enableAllProjectMcpServers", "enabledMcpjsonServers") if k in s}
if out:
    with open(os.environ["DST"], "w") as f:
        json.dump(out, f, indent=2)
PY
}

# M5.7 readiness: "switched" (pane respawned) != "ready" (bot actually answers).
# Ready = the telegram plugin of the NEW claude is polling. The supervisor is
# the only place that can see pod processes, so it owns the state file; cp-api
# exposes it and the Mini App shows "запускается…" until ready — no timeouts.
SESSION_STATE="$RUN_DIR/session-state.json"
set_session_state() { # $1 = name, $2 = starting|ready
  printf '{"name":"%s","status":"%s"}\n' "$1" "$2" > "$SESSION_STATE.tmp" \
    && mv "$SESSION_STATE.tmp" "$SESSION_STATE"
}
arm_readiness_watch() { # $1 = name — flips starting→ready when the plugin is up
  local name="$1"
  if [ "${DISABLE_TELEGRAM_CHANNEL:-0}" = "1" ]; then
    set_session_state "$name" ready; return 0
  fi
  (
    # respawn-window -k killed the old plugin synchronously; wait for the NEW one.
    sleep 2
    i=0
    while [ $i -lt 90 ]; do
      if pgrep -f 'bun server\.ts' >/dev/null 2>&1; then
        # only publish if this watch is still for the current session
        [ "$(cat "$ACTIVE_FILE" 2>/dev/null)" = "$name" ] && set_session_state "$name" ready
        exit 0
      fi
      sleep 2; i=$((i + 1))
    done
    # never came up — leave "starting"; the liveness watchdog handles recovery
  ) &
}

launch_claude() { # $1 = dir, $2 = boot|switch
  local dir="$1" mode="$2" cmd="$CLAUDE_CMD"
  trust_workdir "$dir"
  seed_mcp_approvals "$dir"
  # boot keeps the historical behavior (fresh instance + session-restore seed
  # below); a switch resumes the target project's own conversation instead.
  [ "$mode" = "switch" ] && cmd="$cmd $(resume_flag "$dir")"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux respawn-window -k -t "$SESSION" "cd '$dir' && exec $cmd"
  else
    tmux -f "$TMUX_CFG" new-session -d -s "$SESSION" -x 200 -y 60 -c "$dir" "exec $cmd"
  fi
  # Non-destructively capture the pane (claude's TUI/errors) to a log so launch
  # failures are diagnosable from the host; re-armed after every respawn.
  tmux pipe-pane -t "$SESSION" -o "cat >> '$TELEGRAM_STATE_DIR/logs/claude-pane.log'" 2>/dev/null || true
}

# The supervisor executes a pending switch request (validated, atomic result).
process_switch_request() {
  [ -f "$SWITCH_REQ" ] || return 0
  local req id name dir res
  req=$(cat "$SWITCH_REQ" 2>/dev/null); rm -f "$SWITCH_REQ"
  read -r id name <<EOF2
$(printf '%s' "$req" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(str(d.get("id","")).replace(" ",""), str(d.get("name","")).replace(" ",""))' 2>/dev/null)
EOF2
  fail() {
    res="{\"id\":\"$id\",\"ok\":false,\"error\":\"$1\"}"
    printf '%s\n' "$res" > "$SWITCH_RES.tmp" && mv "$SWITCH_RES.tmp" "$SWITCH_RES"
  }
  [ -n "$id" ] || { fail "malformed request"; return 0; }
  dir=$(session_dir "$name")
  [ -n "$dir" ] || { fail "invalid session name"; return 0; }
  [ -d "$dir" ] || { fail "no such session dir"; return 0; }
  echo "[sessions] switch → $name ($dir)"
  launch_claude "$dir" switch
  echo "$name" > "$ACTIVE_FILE"
  set_session_state "$name" starting
  arm_readiness_watch "$name"
  printf '%s\n' "{\"id\":\"$id\",\"ok\":true,\"name\":\"$name\"}" > "$SWITCH_RES.tmp" \
    && mv "$SWITCH_RES.tmp" "$SWITCH_RES"
}

# Boot into the active session (pod restart returns to the project the bot was
# in), falling back to default if the marker is missing/invalid.
ACTIVE_NAME=$(cat "$ACTIVE_FILE" 2>/dev/null || true)
ACTIVE_DIR=$(session_dir "${ACTIVE_NAME:-default}")
if [ -z "$ACTIVE_DIR" ] || [ ! -d "$ACTIVE_DIR" ]; then
  ACTIVE_NAME="default"; ACTIVE_DIR="$HOME/work"
fi
echo "${ACTIVE_NAME:-default}" > "$ACTIVE_FILE"

tmux kill-session -t "$SESSION" 2>/dev/null || true
TMUX_CFG="$(mktemp)"; trap 'rm -f "$TMUX_CFG"' EXIT
echo "set-option -g history-limit 100000" > "$TMUX_CFG"
mkdir -p "$TELEGRAM_STATE_DIR/logs"
launch_claude "$ACTIVE_DIR" boot
set_session_state "${ACTIVE_NAME:-default}" starting
arm_readiness_watch "${ACTIVE_NAME:-default}"

# Seed prior-session context (same logic as the host launcher; silent restore).
# DEFAULT session only: the tail below is ~/work's conversation — pasting it
# into a project session bleeds context across sessions, and its trailing
# Enter blindly answers whatever TUI dialog is on screen (2026-06-11: it
# "confirmed" the MCP-approval dialog in a fresh project session).
[ "${ACTIVE_NAME:-default}" = "default" ] && (
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

# Supervise: exit (→ unit Restart=always) when EITHER the claude tmux session
# ends, OR the Telegram channel fails to come up / silently dies. The official
# plugin has NO self-respawn, and the OLD supervisor watched only the tmux
# session — so `claude` could be alive while the channel was dead (e.g. a lost
# bot-token handoff race on pod restart), and recovery needed a MANUAL
# `systemctl restart`. The plugin writes $TELEGRAM_STATE_DIR/bot.pid when it
# starts polling and removes it on shutdown → that file is our liveness signal.
# (vitaliy pilot; closes the M0 tg-plugin liveness-watchdog task. No new
# service/timer, no LLM — just a richer condition on the existing supervise loop;
# systemd StartLimit on the unit caps the restart rate so a permanently-broken
# channel — e.g. a bad token — can't hot-loop.)
BOT_PID_FILE="$TELEGRAM_STATE_DIR/bot.pid"
# Grace after launch for the channel to acquire the Telegram getUpdates session
# (and for a prior pod's server-side long-poll to clear — the 409 handoff window).
CHAN_START_GRACE="${CHANNEL_START_GRACE:-150}"
# Tolerate brief in-session plugin flaps (we see sub-second shutdown→polling
# pairs in the wild) before declaring the channel dead.
CHAN_FLAP_GRACE="${CHANNEL_FLAP_GRACE:-60}"

channel_alive() {
  # Healthy iff the plugin PROCESS is alive in THIS pid namespace. The naive
  # check (bot.pid exists + kill -0) false-positives: bot.pid lives on the
  # shared ~/.claude volume, so a plugin running OUTSIDE this container (the
  # 2026-06-11 incident: the old claude-tg@ host unit ran in parallel with the
  # pod for 16h) writes a pid that is dead/foreign in our namespace → the
  # watchdog restart-loops a healthy pod. pgrep for the plugin process is the
  # in-namespace ground truth; bot.pid stays as a secondary signal only (the
  # plugin writes it at process start, so its semantics are identical).
  pgrep -f 'bun server\.ts' >/dev/null 2>&1 && return 0
  local p
  [ -f "$BOT_PID_FILE" ] || return 1
  p="$(cat "$BOT_PID_FILE" 2>/dev/null)" || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# Phase 1 — wait for the channel to come up the first time (skip if disabled).
if [ "${DISABLE_TELEGRAM_CHANNEL:-0}" != "1" ]; then
  waited=0
  until channel_alive; do
    # If claude itself died while we waited, restart now.
    tmux has-session -t "$SESSION" 2>/dev/null || { echo "[supervise] claude session gone during startup → exit for restart"; exit 1; }
    if [ "$waited" -ge "$CHAN_START_GRACE" ]; then
      echo "[supervise] telegram channel did not come up within ${CHAN_START_GRACE}s → exit for restart"
      exit 1
    fi
    waited=$((waited + 5)); sleep 5
  done
fi

# Phase 2 — steady state. Exit (→ Restart) if claude OR the channel drops, the
# latter only after CHAN_FLAP_GRACE of continuous absence to ride out flaps.
# M5.7: each tick also executes a pending session-switch request. The respawn
# briefly kills the plugin — resetting `down` gives the new channel the full
# flap grace instead of whatever was left of it.
down=0
while tmux has-session -t "$SESSION" 2>/dev/null; do
  if [ -f "$SWITCH_REQ" ]; then
    process_switch_request
    down=0
  fi
  if [ "${DISABLE_TELEGRAM_CHANNEL:-0}" != "1" ] && ! channel_alive; then
    down=$((down + 5))
    if [ "$down" -ge "$CHAN_FLAP_GRACE" ]; then
      echo "[supervise] telegram channel down for ${down}s → exit for restart"
      exit 1
    fi
  else
    down=0
  fi
  sleep 5
done
exit 1
