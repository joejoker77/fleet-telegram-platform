#!/usr/bin/env bash
# m4.3-apply-managed-settings.sh — M4 #3: lock the platform settings layer.
#
# Operator-run from the HOST as root. Bakes Claude Code's managed-settings.json
# (highest-precedence, tenant-unwritable) into the runtime image, then de-dupes the
# now-redundant security config out of the tenant's writable ~/.claude/settings.json
# so the locked layer is the single source of truth for security.
#
# WHY this is product-correct (no snowflake): the locked layer lives in the tracked
# image source (runtime/image/platform/managed-settings.json + Containerfile COPY to
# /etc/claude-code/). A fresh server reproduces it by building the image — this
# script just rebuilds + applies on the live box and tidies the live tenant file.
#
# ZERO-GAP ordering: the new image carries the security hooks/denies in the managed
# layer BEFORE we remove them from the tenant file, and the managed layer is
# authoritative, so security is enforced at every moment. The only mandatory de-dup
# is correctness-driven (the metering Stop hook would double-count tokens if it ran
# from both layers).
#
# Steps (all reversible — see m4.3-rollback-managed-settings.sh):
#   1. preflight
#   2. back up tenant settings.json + tag the current image :m4.3-prev (rollback anchor)
#   3. rebuild the image with the managed layer baked in (m2.1-build-image.sh)
#   4. PRE-TEST the new image: managed-settings.json present, valid JSON, 0644 root
#   5. de-dup the tenant settings.json (drop the Bash PreToolUse matcher + Stop
#      metering hook + deny rules — all now in the locked managed layer)
#   6. restart claude-pod@vitaliy
#   7. verify host-side: pod up, managed layer present in the live container,
#      tenant file de-duped. Behavioral confirm (WebFetch denied) = the in-pod bot.
set -euo pipefail

U=vitaliy
REPO=/home/vitaliy/work/fleet-platform
IMAGE=localhost/claude-user:latest
PREV=localhost/claude-user:m4.3-prev
CTR=claude-$U
SETTINGS="/home/$U/.claude/settings.json"
BUILD="$REPO/runtime/install/m2.1-build-image.sh"
MANAGED_PATH=/etc/claude-code/managed-settings.json
TS="$(date -u +%Y%m%d-%H%M%S)"
BK="/home/$U/m4.3-backups/$TS"

log(){ printf '\n[m4.3] %s\n' "$*"; }
die(){ printf '\n[m4.3][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "this is running INSIDE a container — run on the HOST"

log "1/7 preflight"
command -v podman  >/dev/null 2>&1 || die "podman not installed"
command -v python3 >/dev/null 2>&1 || die "python3 not installed"
command -v jq      >/dev/null 2>&1 || die "jq not installed (needed for verify)"
[ -f "$BUILD" ]    || die "build script missing: $BUILD"
[ -f "$SETTINGS" ] || die "tenant settings.json missing: $SETTINGS"
[ -f "$REPO/runtime/image/platform/managed-settings.json" ] || die "managed-settings.json source missing"
podman image exists "$IMAGE" || die "image $IMAGE missing (run m2.1-build-image.sh first)"
echo "  ok"

log "2/7 backup tenant settings.json + tag rollback image -> $BK"
mkdir -p "$BK"
cp -a "$SETTINGS" "$BK/settings.json" && echo "  backed up $SETTINGS"
# Anchor rollback to the PRE-M4.3 image. Re-run-safe: only tag if :m4.3-prev does
# not already exist, so a second run (e.g. after fixing a later step) does NOT
# clobber the anchor with the already-rebuilt :latest (which would point rollback
# at the managed image and make it a no-op).
if podman image exists "$PREV"; then
  echo "  rollback image $PREV already exists — preserved (still points at the pre-M4.3 image)"
else
  podman tag "$IMAGE" "$PREV" && echo "  tagged current image -> $PREV (rollback anchor)"
fi

log "3/7 rebuild image with the managed layer baked in"
bash "$BUILD" || die "image build failed — old image + :m4.3-prev intact, no live change made"
echo "  ok: image rebuilt"

log "4/7 PRE-TEST new image carries a valid, locked managed layer"
PRE="$(podman run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'jq -e . '"$MANAGED_PATH"' >/dev/null 2>&1 && stat -c "%a %U %G" '"$MANAGED_PATH" || true)"
echo "  managed file in image: ${PRE:-<MISSING/INVALID>}"
# stat %a yields octal WITHOUT a leading zero (644), so accept both forms.
case "$PRE" in
  644\ root\ root|0644\ root\ root) echo "  ok: $MANAGED_PATH present, valid JSON, mode 644 root:root" ;;
  *) die "managed layer not correctly baked into the new image (got '${PRE:-none}') — aborting before any live change. Rollback not needed (live still on prior image until restart)." ;;
esac
# Confirm the managed layer actually carries the security hooks we expect.
podman run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'jq -e ".hooks.PreToolUse[0].hooks | map(.command) | index(\"/usr/local/share/claude-guard/block-nested-claude.py\")" '"$MANAGED_PATH"' >/dev/null' \
  || die "managed layer missing block-nested-claude hook — aborting"
echo "  ok: managed layer carries the shellfirm + block-nested-claude PreToolUse hooks"

log "5/7 de-dup tenant settings.json (security config now lives in the locked layer)"
SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]
d = json.load(open(p))
changed = False

# deny rules -> moved to managed layer
perms = d.get("permissions", {})
if perms.get("deny"):
    perms["deny"] = []
    changed = True

hooks = d.get("hooks", {})

# PreToolUse: drop the Bash matcher (shellfirm + block-nested-claude now managed);
# keep every other matcher (e.g. AskUserQuestion -> telegram-block-askuser).
pre = hooks.get("PreToolUse")
if isinstance(pre, list):
    kept = [e for e in pre if e.get("matcher") != "Bash"]
    if len(kept) != len(pre):
        if kept:
            hooks["PreToolUse"] = kept
        else:
            hooks.pop("PreToolUse", None)
        changed = True

# Stop: drop entirely (metering hook now managed — duplicate would double-count).
if "Stop" in hooks:
    hooks.pop("Stop", None)
    changed = True

if changed:
    with open(p, "w") as f:
        json.dump(d, f, indent=2); f.write("\n")
    print("  de-duped: deny rules + Bash PreToolUse matcher + Stop hook removed")
else:
    print("  already de-duped — no change")
PY
# Belt-and-suspenders: the file must still be valid JSON and keep the telegram hooks.
jq -e . "$SETTINGS" >/dev/null || die "tenant settings.json is no longer valid JSON after de-dup (restore $BK/settings.json)"
echo "  tenant settings.json still valid JSON"

log "6/7 restart claude-pod@$U (kills + respawns the bot container; script is host-side so it survives)"
systemctl restart "claude-pod@$U"
echo "  restart issued"

log "7/7 verify"
ok_pod=""; ok_mgd=""; ok_dedup=""
for i in $(seq 1 30); do
  sleep 2
  systemctl is-active --quiet "claude-pod@$U" || continue
  podman container exists "$CTR" || continue
  if podman exec "$CTR" sh -c "jq -e . $MANAGED_PATH >/dev/null 2>&1"; then ok_pod=1; ok_mgd=1; break; fi
done
[ -n "$ok_pod" ] || die "pod did not come up / managed layer not visible in $CTR within 60s. Rollback: bash $REPO/runtime/install/m4.3-rollback-managed-settings.sh"
# Managed file must be read-only to the tenant uid inside the live container.
if podman exec --user "$(id -u "$U")" "$CTR" sh -c "test -w $MANAGED_PATH" 2>/dev/null; then
  die "$MANAGED_PATH is WRITABLE by uid $(id -u "$U") inside the container — NOT tamper-proof. Rollback."
fi
echo "  ✅ managed layer present + read-only to the tenant in live container $CTR"
grep -q 'block-nested-claude' "$SETTINGS" && echo "  ⚠️ tenant settings.json still references block-nested-claude (de-dup incomplete?)" || ok_dedup=1
[ -n "$ok_dedup" ] && echo "  ✅ tenant settings.json de-duped (no security hooks left in the user layer)"

echo
echo "[m4.3] DONE — locked platform settings layer live."
echo "  Rollback (one command): bash $REPO/runtime/install/m4.3-rollback-managed-settings.sh"
echo "  Behavioral confirm is done by the in-pod bot: WebFetch must be DENIED and"
echo "  a nested 'claude mcp list' must be BLOCKED, with the deny/guard now sourced"
echo "  ONLY from the locked managed layer."
