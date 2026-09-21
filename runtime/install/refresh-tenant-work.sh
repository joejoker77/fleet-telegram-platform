#!/usr/bin/env bash
# Ship the skeleton's ~/work tooling to tenants who already exist.
#
# WHY THIS EXISTS. provision-tenant.sh copies tenant-skel/work only when the target is
# ABSENT — correct, because ~/work is the tenant's own space — which means a helper added
# or fixed after someone was onboarded never reaches them. Every fleet-wide change to
# those files has therefore been a hand-written loop over /home/*: share-skill on
# 2026-09-18, pd-upload and the Pipedrive paragraph on 2026-09-21, both on the same day.
# Each loop invents its own idea of "is this copy safe to overwrite", and a wrong answer
# silently destroys something a lawyer wrote.
#
# HOW IT DECIDES, per file per tenant:
#   missing                    -> install it
#   same bytes as the skeleton -> nothing to do
#   same bytes as what we last shipped -> the tenant never touched it: update
#   anything else              -> they changed it: LEAVE IT, and say so
#
# The third rule is the one that needs the state file: without a record of what was last
# shipped, "differs from the skeleton" cannot tell a tenant's edit from our own update,
# and the only safe reading is to skip everyone — which is why this has been done by hand.
#
#   refresh-tenant-work.sh --all [--dry-run]
#   refresh-tenant-work.sh <tenant> [--dry-run]
#   refresh-tenant-work.sh --all --force     # overwrite even local edits (say why in the log)
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKEL="$HERE/tenant-skel/work"
STATE=/var/lib/fleet/tenant-work-shipped.json
[ -d "$SKEL" ] || { echo "no tenant-skel/work at $SKEL" >&2; exit 2; }

DRY=0; FORCE=0; TARGET=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --all)     TARGET="--all" ;;
    -*)        echo "unknown option: $a" >&2; exit 64 ;;
    *)         TARGET="$a" ;;
  esac
done
[ -n "$TARGET" ] || { echo "usage: refresh-tenant-work.sh <tenant>|--all [--dry-run] [--force]" >&2; exit 64; }

# The managed set. CLAUDE.md is in here deliberately: it is the file the Pipedrive fix had
# to reach, and the same provenance rule protects a tenant who has added their own notes.
# Regular files only, one level deep, and no build droppings: `ls bin/*` expands a
# directory into its contents with a header line, which on the first dry run turned a
# stray __pycache__ in the skeleton into 64 bogus "would install" entries.
mapfile -t FILES < <(cd "$SKEL" && {
  find bin -maxdepth 1 -type f ! -name '*.pyc' -printf '%p\n' 2>/dev/null | sort
  [ -f CLAUDE.md ] && echo CLAUDE.md
})
[ "${#FILES[@]}" -gt 0 ] || { echo "skeleton has nothing to ship" >&2; exit 2; }

md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

mkdir -p "$(dirname "$STATE")"
[ -f "$STATE" ] || echo '{}' > "$STATE"

tenants() {
  if [ "$TARGET" = "--all" ]; then
    if [ -d /etc/claude-role ]; then ls /etc/claude-role; else
      for d in /home/*/; do [ -d "$d/.claude" ] && basename "$d"; done
    fi
  else
    echo "$TARGET"
  fi
}

installed=0; updated=0; kept=0; skipped=0
for t in $(tenants); do
  home="/home/$t"
  [ -d "$home/work" ] || { printf '  %-19s no ~/work, skipped\n' "$t"; continue; }
  for rel in "${FILES[@]}"; do
    src="$SKEL/$rel"; dst="$home/work/$rel"
    want="$(md5 "$src")"
    prev="$(python3 -c "import json,sys;print(json.load(open('$STATE')).get('$rel',''))" 2>/dev/null)"
    mode=0644; [ -x "$src" ] && mode=0755

    if [ ! -e "$dst" ]; then
      action=install
    elif [ "$(md5 "$dst")" = "$want" ]; then
      action=current
    elif [ -n "$prev" ] && [ "$(md5 "$dst")" = "$prev" ]; then
      action=update
    elif [ "$FORCE" = 1 ]; then
      action=force
    else
      action=local
    fi

    case "$action" in
      current) kept=$((kept+1)); continue ;;
      local)   printf '  %-19s %-28s changed locally, left alone\n' "$t" "$rel"; skipped=$((skipped+1)); continue ;;
    esac

    if [ "$DRY" = 1 ]; then
      printf '  %-19s %-28s would %s\n' "$t" "$rel" "$action"
    else
      mkdir -p "$(dirname "$dst")"
      install -m "$mode" -o "$t" -g "$t" "$src" "$dst" || { printf '  %-19s %-28s FAILED\n' "$t" "$rel"; continue; }
      printf '  %-19s %-28s %sd\n' "$t" "$rel" "$action"
    fi
    [ "$action" = install ] && installed=$((installed+1)) || updated=$((updated+1))
  done
done

# Record what this run shipped, so the next one can tell our update from a tenant's edit.
# Only after a real run: a dry run must not move the goalposts it just measured against.
if [ "$DRY" = 0 ]; then
  python3 - "$SKEL" "$STATE" "${FILES[@]}" <<'PY'
import hashlib, json, os, sys
skel, state = sys.argv[1], sys.argv[2]
data = json.load(open(state)) if os.path.exists(state) else {}
for rel in sys.argv[3:]:
    p = os.path.join(skel, rel)
    if os.path.isfile(p):
        data[rel] = hashlib.md5(open(p, "rb").read()).hexdigest()
json.dump(data, open(state, "w"), indent=1, sort_keys=True)
PY
fi

echo
printf 'installed %d, updated %d, already current %d, left alone (local edits) %d\n' \
  "$installed" "$updated" "$kept" "$skipped"
[ "$skipped" -gt 0 ] && echo "Local edits are never overwritten without --force. Look at one before you use it."
exit 0
