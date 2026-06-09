#!/usr/bin/env bash
# m4.2-apply-audit-wiring.sh — M4 #2: wire the migrated vitaliy pod to the
# control-plane audit-collector (socket + Stop hook).
#
# Operator-run from the HOST as root (it restarts claude-pod@vitaliy, which kills
# and respawns the bot's own container — so this MUST NOT run inside the pod). The
# script runs entirely host-side, so it survives the restart and finishes the
# verification after the new container comes up.
#
# What it does (all reversible — see m4.2-rollback-audit-wiring.sh):
#   1. preflight: image, cp-audit-run volume, collector container, socket present
#   2. PRE-TEST the exact prod reach path (uid 1005 + --group-add 0 → root:root 0660
#      socket) with a throwaway --rm container — proves the socket is reachable and
#      the collector accepts+chains an event BEFORE touching the live pod
#   3. back up the current wrapper + tenant settings.json
#   4. install the updated wrapper (adds -v cp-audit-run:/run/audit --group-add 0)
#   5. wire the baked metering Stop hook into the tenant settings.json (idempotent)
#   6. restart claude-pod@vitaliy
#   7. verify a fresh runtime.start (emitted by the entrypoint) landed in the WORM log
set -euo pipefail

U=vitaliy
REPO=/home/vitaliy/work/fleet-platform
IMAGE=localhost/claude-user:latest
VOL=cp-audit-run
SETTINGS="/home/$U/.claude/settings.json"
WRAPPER_SRC="$REPO/runtime/systemd/claude-pod-run"
WRAPPER_DST=/usr/local/bin/claude-pod-run
AUDIT_DIR=/srv/audit
TS="$(date -u +%Y%m%d-%H%M%S)"
BK="/home/$U/m4.2-backups/$TS"

log(){ printf '\n[m4.2] %s\n' "$*"; }
die(){ printf '\n[m4.2][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "this is running INSIDE a container — run on the HOST"

log "1/7 preflight"
podman image exists "$IMAGE"                  || die "image $IMAGE missing (run m2.1-build-image.sh)"
podman volume exists "$VOL"                    || die "volume $VOL missing (run control-plane m1.5-services.sh)"
podman container exists cp-audit-collector     || die "cp-audit-collector container not found"
[ "$(podman inspect -f '{{.State.Running}}' cp-audit-collector 2>/dev/null)" = true ] \
  || die "cp-audit-collector not running"
[ -f "$WRAPPER_SRC" ] || die "wrapper source missing: $WRAPPER_SRC"
# socket lives in the volume; confirm via a throwaway mount
podman run --rm --entrypoint /bin/sh -v "$VOL:/run/audit" "$IMAGE" \
  -c '[ -S /run/audit/collector.sock ]' \
  || die "collector.sock not present in volume $VOL (is the collector healthy?)"
echo "  ok: image, volume, collector, socket all present"

log "2/7 PRE-TEST reach path (uid $(id -u "$U") + --group-add 0 → root:root 0660 socket)"
PROBE="$(podman run --rm --entrypoint /bin/sh \
  --user "$(id -u "$U"):$(id -g "$U")" --group-add 0 \
  -v "$VOL:/run/audit" "$IMAGE" -c \
  'printf "%s\n" "{\"userId\":null,\"kind\":\"runtime.start\",\"actor\":\"'"$U"'\",\"payload\":{\"probe\":\"m4.2-apply\"}}" | timeout 3 socat - UNIX-CONNECT:/run/audit/collector.sock' 2>&1 || true)"
echo "  collector replied: $PROBE"
echo "$PROBE" | grep -q '"ok":true' \
  || die "pre-test FAILED — collector did not accept the event via the uid+group-add-0 path. Aborting before any change. Reply was: $PROBE"
echo "  ok: socket reachable + event accepted + hash-chained (no live-pod change yet)"

log "3/7 backup current wrapper + settings.json -> $BK"
mkdir -p "$BK"
[ -f "$WRAPPER_DST" ] && cp -a "$WRAPPER_DST" "$BK/claude-pod-run" && echo "  backed up $WRAPPER_DST"
[ -f "$SETTINGS" ]    && cp -a "$SETTINGS"    "$BK/settings.json"  && echo "  backed up $SETTINGS"

log "4/7 install updated wrapper"
install -m 0755 "$WRAPPER_SRC" "$WRAPPER_DST"
grep -q 'cp-audit-run:/run/audit' "$WRAPPER_DST" || die "installed wrapper missing the audit mount"
echo "  installed $WRAPPER_DST (with audit mount + --group-add 0)"

log "5/7 wire metering Stop hook into $SETTINGS (idempotent)"
SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]
d = json.load(open(p))
hooks = d.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
CMD = "node /opt/platform/hooks/metering-stop-hook.mjs"
present = any(
    h.get("command") == CMD
    for entry in stop for h in (entry.get("hooks") or [])
)
if present:
    print("  already wired — no change")
else:
    stop.append({"hooks": [{"type": "command", "command": CMD}]})
    with open(p, "w") as f:
        json.dump(d, f, indent=2); f.write("\n")
    print("  added Stop hook ->", CMD)
PY

log "6/7 restart claude-pod@$U (kills + respawns the bot container)"
systemctl restart "claude-pod@$U"
echo "  restart issued; waiting for the new container + entrypoint runtime.start..."

log "7/7 verify a fresh runtime.start landed in the WORM log"
DAYLOG="$AUDIT_DIR/audit-$(date -u +%F).log"
ok=""
for i in $(seq 1 30); do
  sleep 2
  if [ -f "$DAYLOG" ] && tail -n 40 "$DAYLOG" 2>/dev/null \
       | grep -q "\"kind\":\"runtime.start\".*\"actor\":\"$U\""; then
    ok=1; break
  fi
done
if [ -n "$ok" ]; then
  echo "  ✅ runtime.start from actor=$U observed in $DAYLOG"
  echo
  echo "[m4.2] DONE — audit wiring live. Last 3 WORM records:"
  tail -n 3 "$DAYLOG" | sed 's/^/    /'
else
  echo "  ⚠️  no fresh runtime.start seen within 60s."
  echo "      The pre-test PASSED, so the socket path works; this likely means the new"
  echo "      container is still starting (or socat missing). Check:"
  echo "        systemctl status claude-pod@$U"
  echo "        podman exec claude-$U sh -c '[ -S /run/audit/collector.sock ] && echo socket-ok'"
  echo "        tail -n 20 $DAYLOG"
  echo "      Rollback if needed: bash $REPO/runtime/install/m4.2-rollback-audit-wiring.sh"
  exit 1
fi
