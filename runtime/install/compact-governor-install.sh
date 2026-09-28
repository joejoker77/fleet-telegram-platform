#!/usr/bin/env bash
# Dynamic auto-compaction (compact-governor): install, and opt tenants in or out.
#
#   compact-governor-install.sh                    install script + 5-min timer; enables nobody
#   compact-governor-install.sh --enable  <user>…  give <user> the usage status line + add to TENANTS
#   compact-governor-install.sh --disable <user>…  put <user> back to /autocompact auto, remove both
#
# Rollback of everything: compact-governor-rollback.sh (disables every tenant, removes the timer).
# No request to Anthropic anywhere: the numbers come from the tenant's own status line.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN=/usr/local/sbin/compact-governor
CONF=/etc/claudeapp/compact-governor.env
UNIT_DIR=/etc/systemd/system

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

install_base() {
  install -m 0755 "$HERE/compact-governor.py" "$BIN"
  install -m 0644 "$ROOT/systemd/compact-governor.service" "$UNIT_DIR/"
  install -m 0644 "$ROOT/systemd/compact-governor.timer" "$UNIT_DIR/"
  if [ ! -f "$CONF" ]; then
    mkdir -p /etc/claudeapp
    cat > "$CONF" <<'CFG'
# compact-governor. Tenants listed here get 1M by default and the 200k saver only while
# they are running out of their 5-hour or weekly limit. Manage with
# compact-governor-install.sh --enable/--disable rather than by hand.
TENANTS=""
# Saver on when a window is at least this full AND fuller than the share of it elapsed.
THRESHOLD_PCT=50
SAVER_WINDOW=200000
# Minimum minutes between two switches for one tenant (no flapping).
DWELL_MIN=30
CFG
    chmod 0644 "$CONF"
  fi
  systemctl daemon-reload
  systemctl enable --now compact-governor.timer >/dev/null
  echo "installed: $BIN + compact-governor.timer"
}

conf_tenants() { ( . "$CONF"; echo "${TENANTS:-}" ); }
set_tenants() { sed -i "s|^TENANTS=.*|TENANTS=\"$*\"|" "$CONF"; }

# statusLine is not a key the settings guard protects (permissions/hooks only), and Claude
# Code picks a new statusLine up without a restart.
settings_edit() {  # <user> add|remove
  local u="$1" op="$2" f="/home/$1/.claude/settings.json"
  [ -f "$f" ] || die "$f missing"
  F="$f" U="$u" OP="$op" python3 - <<'PY'
import json, os
f, u, op = os.environ["F"], os.environ["U"], os.environ["OP"]
st = os.stat(f)
d = json.load(open(f))
ours = {"type": "command", "command": f"python3 /home/{u}/.claude/usage-statusline.py"}
cur = d.get("statusLine")
if op == "add":
    if cur and cur != ours:
        raise SystemExit(f"{u}: already has a different statusLine {cur!r}; not touching it")
    d["statusLine"] = ours
elif cur == ours:
    del d["statusLine"]
tmp = f + ".cg-tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2); fh.write("\n")
os.chown(tmp, st.st_uid, st.st_gid); os.chmod(tmp, st.st_mode & 0o777)
os.replace(tmp, f)
PY
}

enable() {
  local u="$1"
  id "$u" >/dev/null 2>&1 || die "no such tenant: $u"
  install -m 0755 -o "$u" -g "$u" "$HERE/tenant-skel/usage-statusline.py" "/home/$u/.claude/usage-statusline.py"
  settings_edit "$u" add
  local t; t="$(conf_tenants)"
  case " $t " in *" $u "*) ;; *) set_tenants $t "$u" ;; esac
  echo "$u: enabled (numbers appear after the next reply in the main session)"
}

disable() {
  local u="$1" t="" x
  "$BIN" --restore "$u" || echo "$u: WARNING — could not type /autocompact auto now; do it once the pod is idle: $BIN --restore $u"
  settings_edit "$u" remove || true
  rm -f "/home/$u/.claude/usage-statusline.py" "/home/$u/.claude/usage-snapshot.json"
  for x in $(conf_tenants); do [ "$x" = "$u" ] || t="$t $x"; done
  set_tenants $t
  echo "$u: disabled"
}

case "${1:-}" in
  "") install_base ;;
  --enable)  shift; [ -x "$BIN" ] || install_base; for u in "$@"; do enable "$u"; done ;;
  --disable) shift; for u in "$@"; do disable "$u"; done ;;
  *) die "usage: $0 [--enable|--disable <user>…]" ;;
esac
echo "TENANTS now: $(conf_tenants)"
echo "Check without typing anything:  $BIN --dry-run"
