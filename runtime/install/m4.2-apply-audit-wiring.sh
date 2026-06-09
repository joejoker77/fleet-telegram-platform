#!/usr/bin/env bash
# m4.2-apply-audit-wiring.sh — M4 #2: wire the migrated vitaliy pod to the
# control-plane audit-collector (socket + Stop hook), via a dedicated `audit` group.
#
# Operator-run from the HOST as root. The control-plane redeploy (step 2) does NOT
# touch the bot pod; only step 6 restarts claude-pod@vitaliy (kills + respawns the
# bot's container). The script runs entirely host-side, so it survives that restart
# and finishes verification after the new container comes up.
#
# Product-correct (no snowflake): the `audit` group, the collector chgrp, the pod
# --group-add, and the Stop hook all live in the tracked sources
# (control-plane/install/m1.5-services.sh, control-plane/apps/audit-collector,
# runtime/systemd/claude-pod-run). A fresh server reproduces this by running the
# same installers — this script just APPLIES those sources to the live box.
#
# Steps (all reversible — see m4.2-rollback-audit-wiring.sh):
#   1. preflight
#   2. re-run m1.5-services.sh  -> creates system group `audit`, recreates the
#      collector with -e AUDIT_GID so it chgrp's the socket to root:audit 0660
#      (control-plane only; the bot pod is untouched)
#   3. resolve the audit gid + confirm the socket is now group=audit
#   4. PRE-TEST the real reach path (tenant uid + --group-add <audit-gid>) with a
#      throwaway --rm container — proves reach + accept + chain BEFORE the live pod
#   5. back up the current wrapper + settings.json
#   6. install the updated wrapper + wire the baked metering Stop hook (idempotent)
#   7. restart claude-pod@vitaliy and verify a fresh runtime.start lands in the WORM
set -euo pipefail

U=vitaliy
REPO=/home/vitaliy/work/fleet-platform
IMAGE=localhost/claude-user:latest
VOL=cp-audit-run
SETTINGS="/home/$U/.claude/settings.json"
WRAPPER_SRC="$REPO/runtime/systemd/claude-pod-run"
# Derive the wrapper path from the unit's ExecStart so this can never drift
# across servers (the unit is the single source of truth for what actually
# launches the pod; ours installs to /usr/local/sbin). Fall back to that canon.
WRAPPER_DST="$(systemctl cat claude-pod@.service 2>/dev/null \
  | sed -n 's#^ExecStart=\(/[^ ]*claude-pod-run\).*#\1#p' | head -n1)"
[ -n "$WRAPPER_DST" ] || WRAPPER_DST=/usr/local/sbin/claude-pod-run
M15="$REPO/control-plane/install/m1.5-services.sh"
AUDIT_DIR=/srv/audit
TS="$(date -u +%Y%m%d-%H%M%S)"
BK="/home/$U/m4.2-backups/$TS"

log(){ printf '\n[m4.2] %s\n' "$*"; }
die(){ printf '\n[m4.2][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (host)"
[ -f /run/.containerenv ] && die "this is running INSIDE a container — run on the HOST"

log "1/7 preflight"
podman image exists "$IMAGE"               || die "image $IMAGE missing (run m2.1-build-image.sh)"
podman container exists cp-audit-collector || die "cp-audit-collector not found (run m1.5-services.sh first)"
[ -f "$WRAPPER_SRC" ] || die "wrapper source missing: $WRAPPER_SRC"
[ -f "$M15" ]         || die "m1.5 source missing: $M15"
echo "  ok"

log "2/7 re-run m1.5-services.sh (creates audit group + collector chgrp; bot pod untouched)"
bash "$M15" || die "m1.5-services.sh failed — control plane not redeployed; no runtime change made"
echo "  ok: control plane redeployed"

log "3/7 resolve audit gid + confirm socket group"
getent group audit >/dev/null 2>&1 || die "audit group missing after m1.5 (unexpected)"
AGID="$(getent group audit | cut -d: -f3)"
echo "  audit gid=$AGID"
# socket group as seen on the host volume (numeric gid):
SOCK_GID="$(podman run --rm --entrypoint /bin/sh -v "$VOL:/run/audit" "$IMAGE" \
  -c 'stat -c %g /run/audit/collector.sock 2>/dev/null' || true)"
echo "  socket group gid=$SOCK_GID"
[ "$SOCK_GID" = "$AGID" ] || die "socket group ($SOCK_GID) != audit gid ($AGID) — collector chgrp did not take"
echo "  ok: collector.sock is group=audit"

log "4/7 PRE-TEST reach path (uid $(id -u "$U") + --group-add $AGID -> root:audit 0660 socket)"
# Fire the probe FIRE-AND-FORGET: the collector's ok-ack is gated behind a DB
# insert that can exceed socat's reply window on a freshly-recreated collector, so
# we do NOT depend on the ack (neither do the real emitters — the entrypoint socat
# and the metering hook are both fire-and-forget). commit() appends to the WORM
# BEFORE that await, so we confirm reach+accept by checking the WORM log host-side
# (a throwaway container can't read AUDIT_DIR by design).
DAYLOG="$AUDIT_DIR/audit-$(date -u +%F).log"
P4_BYTES=0; [ -f "$DAYLOG" ] && P4_BYTES="$(stat -c%s "$DAYLOG")"
podman run --rm --entrypoint /bin/sh \
  --user "$(id -u "$U"):$(id -g "$U")" --group-add "$AGID" \
  -v "$VOL:/run/audit" "$IMAGE" -c \
  'printf "%s\n" "{\"userId\":null,\"kind\":\"runtime.start\",\"actor\":\"'"$U"'\",\"payload\":{\"probe\":\"m4.2-apply\"}}" | timeout 6 socat -t5 - UNIX-CONNECT:/run/audit/collector.sock' >/dev/null 2>&1 || true
ok=""
for i in $(seq 1 10); do
  sleep 1
  [ -f "$DAYLOG" ] || continue
  if tail -c "+$((P4_BYTES + 1))" "$DAYLOG" 2>/dev/null | grep -q '"probe":"m4.2-apply"'; then ok=1; break; fi
done
[ -n "$ok" ] || die "pre-test FAILED — probe did not persist to the WORM via the audit-group path (real reach/permission problem). Aborting before any runtime change."
echo "  ok: probe reached the collector + persisted to the WORM via the audit group (no live-pod change yet)"

log "5/7 backup current wrapper + settings.json -> $BK"
mkdir -p "$BK"
[ -f "$WRAPPER_DST" ] && cp -a "$WRAPPER_DST" "$BK/claude-pod-run" && echo "  backed up $WRAPPER_DST"
[ -f "$SETTINGS" ]    && cp -a "$SETTINGS"    "$BK/settings.json"  && echo "  backed up $SETTINGS"

log "6/7 install wrapper + wire metering Stop hook (idempotent)"
install -m 0755 "$WRAPPER_SRC" "$WRAPPER_DST"
grep -q 'cp-audit-run:/run/audit' "$WRAPPER_DST" || die "installed wrapper missing the audit mount"
echo "  installed $WRAPPER_DST"
SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]
d = json.load(open(p))
stop = d.setdefault("hooks", {}).setdefault("Stop", [])
CMD = "node /opt/platform/hooks/metering-stop-hook.mjs"
if any(h.get("command") == CMD for e in stop for h in (e.get("hooks") or [])):
    print("  Stop hook already wired — no change")
else:
    stop.append({"hooks": [{"type": "command", "command": CMD}]})
    with open(p, "w") as f:
        json.dump(d, f, indent=2); f.write("\n")
    print("  added Stop hook ->", CMD)
PY

log "7/7 restart claude-pod@$U + verify fresh runtime.start in the WORM log"
# Anchor to bytes written AFTER the restart so the step-4 probe (also a
# runtime.start actor=vitaliy) can't satisfy the check (M3-cutover false-positive
# class: never grep the whole append-only log).
DAYLOG="$AUDIT_DIR/audit-$(date -u +%F).log"
PRE_BYTES=0; [ -f "$DAYLOG" ] && PRE_BYTES="$(stat -c%s "$DAYLOG")"
systemctl restart "claude-pod@$U"
echo "  restart issued (log was ${PRE_BYTES}B); waiting for the entrypoint runtime.start..."
ok=""
for i in $(seq 1 30); do
  sleep 2
  [ -f "$DAYLOG" ] || continue
  if tail -c "+$((PRE_BYTES + 1))" "$DAYLOG" 2>/dev/null \
       | grep -q "\"kind\":\"runtime.start\".*\"actor\":\"$U\""; then
    ok=1; break
  fi
done
if [ -n "$ok" ]; then
  echo "  ✅ runtime.start from actor=$U present in $DAYLOG"
  echo
  echo "[m4.2] DONE — audit wiring live via the dedicated 'audit' group. Last 3 WORM records:"
  tail -n 3 "$DAYLOG" | sed 's/^/    /'
else
  echo "  ⚠️  no runtime.start seen within 60s — pre-test PASSED so the path works."
  echo "      Check: systemctl status claude-pod@$U ;"
  echo "             podman exec claude-$U sh -c '[ -S /run/audit/collector.sock ] && echo socket-ok' ;"
  echo "             tail -n 20 $DAYLOG"
  echo "      Rollback: bash $REPO/runtime/install/m4.2-rollback-audit-wiring.sh"
  exit 1
fi
