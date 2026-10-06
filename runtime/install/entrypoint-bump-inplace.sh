#!/usr/bin/env bash
# Bump ONLY /opt/platform/entrypoint.sh in the existing tenant image.
#
#   entrypoint-bump-inplace.sh                 build, verify, move :latest
#   entrypoint-bump-inplace.sh --canary <tenant>   build + pin ONE tenant, :latest untouched
#   entrypoint-bump-inplace.sh --dry-run       build and verify, change no tag
#
# WHY NOT A FULL REBUILD. The live :latest on this host is NOT what the
# Containerfile alone produces: the CLI has been layered on top in place
# (cc-bump-inplace.sh), so `podman history` shows an `npm install -g
# @anthropic-ai/claude-code` layer ABOVE the Containerfile's own. On 6 Oct 2026
# the Containerfile still said ARG CLAUDE_VERSION=2.1.280 while :latest carried
# 2.1.287. Rebuilding from the context would therefore have DOWNGRADED Claude
# Code on all 34 pods as a side effect of shipping one shell function. So this
# layers the new entrypoint onto :latest and changes exactly one file — the same
# argument cc-bump-inplace.sh makes for the CLI, in the other direction.
#
# Use the full build (m2.1-build-image.sh / cc-upgrade-*.sh) only when the
# Containerfile is genuinely the source of truth for this host again.
#
# The new tag is <current-cc-tag>-ep<n+1>: the host already names entrypoint
# revisions that way (cc2.1.287-ep0, -ep1), and keeping the CLI version in the
# tag is what stops an entrypoint roll from hiding a CLI change.
#
# Does NOT restart anything. Running pods keep the old entrypoint until their
# container is restarted — stagger that, one at a time, verifying each: a
# restart storm is what caused the 2026-09-11 incident in the first place.
set -euo pipefail

IMAGE=localhost/claude-user
REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
EP="$REPO/runtime/image/platform/entrypoint.sh"

CANARY=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --canary) CANARY="${2:?--canary needs a tenant}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -f "$EP" ] || { echo "no entrypoint at $EP — wrong checkout?"; exit 1; }
[ -n "$CANARY" ] && { id "$CANARY" >/dev/null || exit 1; }

# Markers: every one must be present, in the checkout AND afterwards inside the
# built image. A half-applied checkout must not be able to pass as applied, and
# an overlay that silently failed to COPY must not be able to move :latest.
# The first three are this change; the rest are earlier fixes that the layer
# must not regress.
MARKERS=(
  'claude_launch.offset'
  'launch_banner()'
  'CHAN_VERDICT_DELAY'
  'wait_for_egress'
  'tmux respawn-window -k -t "${SESSION}:0"'
)

log "the checkout carries every marker"
for m in "${MARKERS[@]}"; do
  grep -qF -- "$m" "$EP" || { echo "MISSING in repo: $m"; exit 1; }
  echo "  ok: $m"
done
bash -n "$EP" || { echo "entrypoint does not parse"; exit 1; }
echo "  ok: parses"

log "current image"
cur_cc="$(podman run --rm --entrypoint /bin/sh "$IMAGE:latest" -c 'claude --version' | awk '{print $1}')"
cur_id="$(podman image inspect -f '{{.Id}}' "$IMAGE:latest" | cut -c1-12)"
echo "  :latest is $cur_id, carrying claude $cur_cc"

# Next entrypoint revision for THIS cli version: cc<ver>-ep<n+1>.
base="cc$cur_cc"
n=-1
while read -r t; do
  case "$t" in
    "$base-ep"[0-9]*) r="${t##*-ep}"; [ "$r" -gt "$n" ] 2>/dev/null && n="$r" ;;
  esac
done < <(podman images --format '{{.Tag}}' --filter reference="$IMAGE")

# Idempotence. Without this, every re-run mints another tag — a --dry-run
# followed by the real thing would ship ep3 having verified ep2, and a canary
# promoted later would be a tag nobody tested. So if the newest revision already
# carries exactly this entrypoint, reuse it instead of building past it.
want="$(sha256sum "$EP" | awk '{print $1}')"
NEW_TAG="$base-ep$((n + 1))"
REUSED=0
if [ "$n" -ge 0 ]; then
  have="$(podman run --rm --entrypoint /bin/sh "$IMAGE:$base-ep$n" \
            -c 'sha256sum /opt/platform/entrypoint.sh' 2>/dev/null | awk '{print $1}')"
  if [ "$have" = "$want" ]; then
    NEW_TAG="$base-ep$n"
    REUSED=1
    echo "  $NEW_TAG already carries this exact entrypoint — reusing it"
  fi
fi
STAMP="$(date -u +%Y%m%d)"
BACKUP_TAG="pre-$NEW_TAG-$STAMP"
[ "$REUSED" = 1 ] || echo "  building $NEW_TAG"

log "keep the current image for rollback → $BACKUP_TAG"
if podman image exists "$IMAGE:$BACKUP_TAG"; then
  echo "  $BACKUP_TAG already exists — keeping the original (an earlier run made it)"
else
  podman tag "$IMAGE:latest" "$IMAGE:$BACKUP_TAG"
fi
echo "  $BACKUP_TAG -> $(podman image inspect -f '{{.Id}}' "$IMAGE:$BACKUP_TAG" | cut -c1-12)"

if [ "$REUSED" = 1 ]; then
  log "nothing to build — verifying the existing $NEW_TAG before any tag moves"
else
  log "layering the entrypoint onto it"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  install -m 0755 "$EP" "$tmp/entrypoint.sh"
  cat > "$tmp/Containerfile" <<EOF
FROM $IMAGE:$BACKUP_TAG
COPY entrypoint.sh /opt/platform/entrypoint.sh
RUN chmod 0755 /opt/platform/entrypoint.sh
EOF
  podman build -t "$IMAGE:$NEW_TAG" -f "$tmp/Containerfile" "$tmp"
fi

log "verify INSIDE the built image, not in the checkout"
for m in "${MARKERS[@]}"; do
  podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" \
    -c "grep -qF -- '$m' /opt/platform/entrypoint.sh" \
    || { echo "marker missing inside the image: $m"; exit 1; }
  echo "  ok: $m"
done
podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" -c 'bash -n /opt/platform/entrypoint.sh' \
  || { echo "entrypoint inside the image does not parse"; exit 1; }
echo "  ok: parses inside the image"

# The CLI must come through the layer untouched. This is the whole reason the
# overlay exists, so it is checked, not assumed.
got_cc="$(podman run --rm --entrypoint /bin/sh "$IMAGE:$NEW_TAG" -c 'claude --version' | awk '{print $1}')"
[ "$got_cc" = "$cur_cc" ] \
  || { echo "claude moved $cur_cc -> $got_cc across the layer — not moving :latest"; exit 1; }
echo "  ok: claude still $got_cc"

if [ "$DRY_RUN" = 1 ]; then
  log "dry run — $IMAGE:$NEW_TAG is built and verified, no tag moved"
  exit 0
fi

if [ -n "$CANARY" ]; then
  log "canary: pinning $CANARY to $NEW_TAG (:latest untouched)"
  mkdir -p /etc/claudeapp/image-pin
  echo "$NEW_TAG" > "/etc/claudeapp/image-pin/$CANARY"
  echo "  /etc/claudeapp/image-pin/$CANARY -> $NEW_TAG"
  echo
  echo "Restart $CANARY's pod to use it. Rollback: rm /etc/claudeapp/image-pin/$CANARY (then restart)."
  echo "Promote to everyone later: podman tag $IMAGE:$NEW_TAG $IMAGE:latest"
  exit 0
fi

log "moving :latest"
podman tag "$IMAGE:$NEW_TAG" "$IMAGE:latest"
echo "  latest -> $(podman image inspect -f '{{.Id}}' "$IMAGE:latest" | cut -c1-12)"

cat <<NEXT

Done. Running pods keep the old entrypoint until their container is restarted.
Roll them one at a time and verify each before taking the next:

  graceful-restart-pod-bot <user>      # waits for an idle session, then restarts

Rollback:  podman tag $IMAGE:$BACKUP_TAG $IMAGE:latest   (then restart the pods)

NEXT
