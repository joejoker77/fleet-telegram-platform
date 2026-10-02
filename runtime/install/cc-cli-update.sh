#!/usr/bin/env bash
# cc-cli-update — keep Claude Code current on every pod WITHOUT baking the version into the image.
#
# Claude Code lives in /opt/claude-cli/<version>/ on the host (one npm install, ~230 MB).
# claude-pod-run mounts the chosen version read-only over the image's own copy at
# /usr/lib/node_modules/@anthropic-ai/claude-code, so the image keeps working as a fallback
# but no longer decides the version. Which version a pod gets:
#   /etc/claudeapp/cli-version/<user>   (one line, e.g. 2.1.288)   — canary / per-tenant pin
#   /opt/claude-cli/current -> <version>                          — everybody else
#
# One run (nightly timer, or by hand) does:
#   1. ask npm for the newest version; stop if `current` already has it
#   2. install it into /opt/claude-cli/<version> and check `claude --version` really says so
#   3. CANARY: pin daria-rudenko to it, restart her pod gracefully, then check within minutes —
#      same version reported, telegram plugin running, channel not refused, usage module loaded,
#      no start-failure loop
#   4a. canary FAILED: drop her pin, restart her back onto `current`, record the failure, stop
#   4b. canary OK: point `current` at the new version, drop her pin, gracefully restart every
#       other tenant with a valid login, check them, record the result
# Every outcome is appended to /var/lib/fleet/cli-update.events (JSON lines); the relay on the
# operator's host turns new lines into a Telegram message. NOT AN LLM CALL anywhere.
#
#   cc-cli-update                 normal run
#   cc-cli-update --version X     install/roll out X instead of npm's newest (also downgrades)
#   cc-cli-update --seed X        install X and make it `current` with no restarts (bootstrap)
#   cc-cli-update --dry-run       say what would happen, change nothing
#   cc-cli-update --canary-only   run the canary step, report, then put the canary back on
#                                 `current` — never touches the fleet (for testing the pipeline)
# Rollback by hand: ln -sfn /opt/claude-cli/<old> /opt/claude-cli/current, then graceful restarts
#   (or: cc-cli-update --version <old>).
set -uo pipefail

ROOT=/opt/claude-cli
PINS=/etc/claudeapp/cli-version
EVENTS=/var/lib/fleet/cli-update.events
CANARY="${CC_CANARY:-daria-rudenko}"
IMAGE=localhost/claude-user:latest
PKG=@anthropic-ai/claude-code
KEEP=3
CHECK_TIMEOUT=420          # seconds the canary gets to come up after its restart
LOCK=/run/cc-cli-update.lock

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
event() {  # event <kind> <version> <text>
  install -d -m 0755 "$(dirname "$EVENTS")"
  python3 -c 'import json,sys,time; print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "kind": sys.argv[1], "version": sys.argv[2], "text": sys.argv[3]}))' "$1" "$2" "$3" >> "$EVENTS"
}

WANT=""; SEED=""; DRY=0; CANARY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) WANT="${2:?}"; shift 2 ;;
    --seed) SEED="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --canary-only) CANARY_ONLY=1; shift ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
exec 9>"$LOCK"; flock -n 9 || { log "another run is in progress"; exit 0; }

cur_version() { basename "$(readlink -f "$ROOT/current" 2>/dev/null)" 2>/dev/null; }
npm_latest() { podman run --rm --entrypoint /bin/sh "$IMAGE" -c "npm view $PKG version 2>/dev/null" | tail -1 | tr -d '[:space:]'; }

install_version() {  # install_version <ver> -> /opt/claude-cli/<ver>
  local v="$1" stage
  if [ -x "$ROOT/$v/bin/claude.exe" ]; then log "$v already installed"; return 0; fi
  stage="$(mktemp -d "$ROOT/.stage-$v.XXXX")"
  log "installing $PKG@$v"
  podman run --rm --entrypoint /bin/sh -v "$stage:/out" "$IMAGE" -c \
    "npm install -g --prefix /out $PKG@$v >/out/npm.log 2>&1" \
    || { log "npm install failed: $(tail -3 "$stage/npm.log" 2>/dev/null)"; rm -rf "$stage"; return 1; }
  [ -x "$stage/lib/node_modules/$PKG/bin/claude.exe" ] || { log "install produced no claude.exe"; rm -rf "$stage"; return 1; }
  mv "$stage/lib/node_modules/$PKG" "$ROOT/$v" && rm -rf "$stage"
  chmod -R a+rX "$ROOT/$v"
}

reports() {  # reports <ver> -> 0 if the installed copy says it IS <ver>
  local got
  got="$(podman run --rm --entrypoint /bin/sh -v "$ROOT/$1:/usr/lib/node_modules/$PKG:ro" "$IMAGE" -c 'claude --version' 2>/dev/null | awk '{print $1}')"
  [ "$got" = "$1" ] || { log "version check failed: wanted $1, got '${got:-nothing}'"; return 1; }
}

wait_restart() {  # wait_restart <user> <monotonic-before> <max-seconds>
  local u="$1" t0="$2" max="$3" i=0
  while [ $i -lt "$max" ]; do
    [ "$(systemctl show -p ActiveEnterTimestampMonotonic --value "claude-pod@$u")" != "$t0" ] && return 0
    sleep 10; i=$((i + 10))
  done
  return 1
}

pod_ok() {  # pod_ok <user> <ver> -> 0 when the pod is healthy on <ver>; prints why not
  local u="$1" v="$2" C="claude-$1" P got pane
  got="$(podman exec "$C" claude --version 2>/dev/null | awk '{print $1}')"
  [ "$got" = "$v" ] || { echo "version $got"; return 1; }
  podman exec "$C" pgrep -f 'bun server\.ts' >/dev/null 2>&1 || { echo "telegram plugin not running"; return 1; }
  pane="$(podman exec -u "$u" -e TMUX_TMPDIR="/home/$u/.claude" "$C" tmux capture-pane -p -S -300 -t claude:0.0 2>/dev/null)"
  echo "$pane" | grep -q "not currently available" && { echo "channel refused (Channels are not currently available)"; return 1; }
  P="$(podman exec "$C" pgrep -f 'channels plugin:telegram' 2>/dev/null | head -1)"
  [ -n "$P" ] || { echo "main claude session not running"; return 1; }
  # The usage module only has to be there when the pod was started with it (context_window rollout).
  if podman inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -q '^BUN_OPTIONS=--preload'; then
    podman exec "$C" grep -qz '^BUN_OPTIONS=--preload' "/proc/$P/environ" 2>/dev/null || { echo "usage module not loaded"; return 1; }
  fi
  return 0
}

check_until_ok() {  # check_until_ok <user> <ver> <seconds> -> 0 once healthy twice in a row
  local u="$1" v="$2" max="$3" i=0 good=0 why=""
  while [ $i -lt "$max" ]; do
    sleep 20; i=$((i + 20))
    if why="$(pod_ok "$u" "$v")"; then good=$((good + 1)); [ $good -ge 2 ] && return 0
    else good=0; fi
  done
  echo "${why:-not healthy}"; return 1
}

valid_login() {  # tenants whose Claude login has not lapsed (others cannot come back anyway)
  python3 - <<'PY'
import json, os, time
now = time.time() * 1000
for u in sorted(os.listdir("/etc/claude-role")):
    try: o = json.load(open(f"/home/{u}/.claude/.credentials.json")).get("claudeAiOauth", {})
    except Exception: continue
    r = o.get("refreshTokenExpiresAt")
    if not r or r > now: print(u)
PY
}

prune() {
  local keep_list
  keep_list="$(ls -1t "$ROOT" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n $KEEP)"
  for d in $(ls -1 "$ROOT" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$'); do
    echo "$keep_list" | grep -qx "$d" && continue
    [ "$d" = "$(cur_version)" ] && continue
    grep -rqx "$d" "$PINS" 2>/dev/null && continue
    log "pruning old version $d"; rm -rf "${ROOT:?}/$d"
  done
}

install -d -m 0755 "$ROOT" "$PINS"

# --- bootstrap: install a version and make it current, no restarts ------------------------
if [ -n "$SEED" ]; then
  install_version "$SEED" && reports "$SEED" || exit 1
  ln -sfn "$ROOT/$SEED" "$ROOT/current"
  log "current -> $SEED (no pods restarted; they pick it up on their next start)"
  event seeded "$SEED" "Claude Code $SEED installed as the fleet version (no restarts)"
  exit 0
fi

CUR="$(cur_version)"
NEW="${WANT:-$(npm_latest)}"
[ -n "$NEW" ] || { log "could not read the newest version from npm"; event error "-" "npm view failed"; exit 1; }
if [ "$NEW" = "$CUR" ] && [ $CANARY_ONLY = 0 ]; then log "already on $CUR — nothing to do"; exit 0; fi
log "current=${CUR:-none} target=$NEW canary=$CANARY"
[ $DRY = 1 ] && { log "dry run: would install $NEW, canary $CANARY, then roll out"; exit 0; }

install_version "$NEW" && reports "$NEW" || { event failed "$NEW" "install of $NEW failed — nothing changed"; exit 1; }

# --- canary --------------------------------------------------------------------------------
echo "$NEW" > "$PINS/$CANARY"
t0="$(systemctl show -p ActiveEnterTimestampMonotonic --value "claude-pod@$CANARY")"
/usr/local/sbin/graceful-restart-pod-bot "$CANARY" >/dev/null 2>&1
log "canary $CANARY scheduled onto $NEW; waiting for her restart"
if ! wait_restart "$CANARY" "$t0" 3900; then
  rm -f "$PINS/$CANARY"
  event failed "$NEW" "canary $CANARY was never idle long enough to restart — nothing rolled out"
  exit 1
fi
if why="$(check_until_ok "$CANARY" "$NEW" "$CHECK_TIMEOUT")"; then
  log "canary OK on $NEW"
else
  log "canary FAILED on $NEW: $why — rolling her back to ${CUR:-the image}"
  rm -f "$PINS/$CANARY"
  systemctl restart "claude-pod@$CANARY"
  sleep 120
  back="$(pod_ok "$CANARY" "${CUR:-x}" && echo "she is back on ${CUR} and healthy" || echo "CHECK HER POD: rollback state unclear")"
  event failed "$NEW" "Claude Code $NEW failed on the canary ($CANARY): $why. Rolled back, the fleet stays on ${CUR}. $back"
  exit 1
fi

if [ $CANARY_ONLY = 1 ]; then
  rm -f "$PINS/$CANARY"
  [ "$NEW" != "$CUR" ] && /usr/local/sbin/graceful-restart-pod-bot "$CANARY" >/dev/null 2>&1
  event canary-ok "$NEW" "canary-only test: $CANARY came up healthy on $NEW; fleet untouched (stays on ${CUR})"
  exit 0
fi

# --- fleet ---------------------------------------------------------------------------------
ln -sfn "$ROOT/$NEW" "$ROOT/current"
rm -f "$PINS/$CANARY"
ROLL=""
for u in $(valid_login); do
  [ "$u" = "$CANARY" ] && continue
  [ -f "$PINS/$u" ] && continue                 # a deliberate per-tenant pin stays
  systemctl is-enabled -q "claude-pod@$u" 2>/dev/null || continue
  /usr/local/sbin/graceful-restart-pod-bot "$u" >/dev/null 2>&1 && ROLL="$ROLL $u"
done
log "rollout of $NEW scheduled for:$ROLL"
event rolling "$NEW" "Canary OK. Claude Code $NEW is now the fleet version; graceful restarts scheduled for $(echo $ROLL | wc -w) tenants"

# Collect results for up to 70 min (graceful restarts wait for idle, hard cap 60 min).
deadline=$(( $(date +%s) + 4200 )); ok=""; bad=""
for u in $ROLL; do
  t="$(systemctl show -p ActiveEnterTimestampMonotonic --value "claude-pod@$u")"; echo "$u $t"
done > /run/cc-cli-update.t0
while [ "$(date +%s)" -lt $deadline ]; do
  pending=0
  while read -r u t; do
    case " $ok $bad " in *" $u "*) continue ;; esac
    if [ "$(systemctl show -p ActiveEnterTimestampMonotonic --value "claude-pod@$u")" = "$t" ]; then pending=1; continue; fi
    if why="$(check_until_ok "$u" "$NEW" 300)"; then ok="$ok $u"; else bad="$bad $u($why)"; fi
  done < /run/cc-cli-update.t0
  [ $pending = 0 ] && break
  sleep 30
done
left=""
while read -r u t; do case " $ok $bad " in *" $u "*) ;; *) left="$left $u" ;; esac; done < /run/cc-cli-update.t0
rm -f /run/cc-cli-update.t0
event done "$NEW" "Claude Code $NEW: OK $(echo $ok | wc -w); problems: ${bad:-none}; not restarted yet (busy):${left:- none}"
prune
log "finished"
