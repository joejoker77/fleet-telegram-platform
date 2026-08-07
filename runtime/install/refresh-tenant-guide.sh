#!/usr/bin/env bash
# Regenerate the managed part of a tenant's CLAUDE.md, and nothing else.
#
# Why this exists as its own script: until now the guide could only be rebuilt by re-running
# provision-tenant.sh, which also touches the control-plane rows, the OneCLI agent and its token.
# That is a heavy, risky way to fix a paragraph — so when the text was wrong, the choice was
# between leaving it wrong and disturbing a working tenant. Neither is a good option, and the
# absence of this script is the reason a misleading line about Xero stayed in eight guides.
#
# What it touches: only the block between the MANAGED markers. Anything a tenant wrote outside
# them is preserved exactly — that is their file too.
#
#   refresh-tenant-guide.sh <tenant>     one tenant
#   refresh-tenant-guide.sh --all        everyone with a role on this host
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKEL="$HERE/tenant-skel"
[ -f "$SKEL/CLAUDE.md.baseline" ] || { echo "no baseline at $SKEL" >&2; exit 2; }

refresh_one() {
  local t="$1" role out tmp before after
  role="$(tr -d ' \t\r\n' < "/etc/claude-role/$t" 2>/dev/null)"
  [ -n "$role" ] || { printf '  %-18s no role on file, skipped\n' "$t"; return 0; }
  out="/home/$t/.claude/CLAUDE.md"
  [ -d "/home/$t/.claude" ] || { printf '  %-18s no home, skipped\n' "$t"; return 0; }
  before=$( [ -f "$out" ] && wc -l < "$out" || echo 0 )

  tmp="$(mktemp)"
  {
    echo "<!-- BEGIN MANAGED (provision-tenant) — regenerated each run; do NOT edit between these markers. Put your own notes OUTSIDE them. -->"
    sed "s#__TENANT_USER__#$t#g; s#__TENANT_HOME__#/home/$t#g" "$SKEL/CLAUDE.md.baseline"
    echo; bash "$HERE/render-access-block.sh" "$role"
    if [ "$role" = admin ]; then echo; cat "$SKEL/host-admin.md.snippet"; fi
    echo "<!-- END MANAGED (provision-tenant) -->"
  } > "$tmp"

  if [ -f "$out" ] && grep -q 'BEGIN MANAGED (provision-tenant)' "$out"; then
    # Replace only between the markers. A tenant's own notes live outside them and are not ours.
    MANAGED_TMP="$tmp" python3 - "$out" <<'PY'
import os, re, sys
target = sys.argv[1]
new = open(os.environ["MANAGED_TMP"]).read().strip()
cur = open(target).read()
pat = re.compile(r"<!-- BEGIN MANAGED \(provision-tenant\).*?<!-- END MANAGED \(provision-tenant\) -->", re.S)
out = pat.sub(lambda _m: new, cur, count=1)
open(target, "w").write(out)
PY
  else
    cp "$tmp" "$out"
  fi
  rm -f "$tmp"
  chown "$t:$t" "$out"; chmod 0644 "$out"
  after=$(wc -l < "$out")
  printf '  %-18s %-8s %s -> %s lines\n' "$t" "$role" "$before" "$after"
}

if [ "${1:-}" = "--all" ]; then
  for f in /etc/claude-role/*; do [ -f "$f" ] && refresh_one "$(basename "$f")"; done
else
  refresh_one "${1:?usage: refresh-tenant-guide.sh <tenant> | --all}"
fi
