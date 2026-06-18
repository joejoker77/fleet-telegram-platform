#!/usr/bin/env bash
# icloud-connect-helper.sh — host-side orchestrator for connecting a tenant's iCloud Drive.
#
# This is the one command the `icloud-connect` bot skill drives (as root, via the host-sudo
# broker for an admin pilot, or via the socket auth-helper once that's wired for non-admin
# self-service). It chains the proven pieces:
#   1. AUTH  — two paths, native-first (proven durable 2026-06-18):
#        1a. runtime/install/icloud-auth-core.py — the NATIVE rclone iclouddrive SRP+2FA flow
#            driven in a SINGLE pty process (sidesteps rclone's create→--continue session-loss
#            bug #9324). With the user's REGULAR Apple ID password + a browser-like User-Agent
#            it mints a proper ~30-day device `trust_token` into /home/<user>/rclone.conf — the
#            durable, long-lived path with NO browser dependency. PREFERRED.
#        1b. runtime/install/icloud-browser-auth.py — FALLBACK only. A real headless-browser
#            login to icloud.com that harvests Apple's web-session cookies + trust_token. Used
#            when Apple 412s the native verify for a given account/region (it sometimes does).
#      Either way the <user>_icloud remote ends up in /home/<user>/rclone.conf.
#   2. MOUNT — enable the templated rclone-icloud-mount@<user> systemd unit (FUSE on the HOST
#              at /home/<user>/icloud, --allow-other so the pod uid can read it).
#   3. POD   — optionally graceful-restart the tenant pod so claude-pod-run's conditional
#              `:rslave` bind of ~/icloud takes effect (the bind is evaluated at pod start).
#
# Credentials: the regular Apple ID password comes from ICLOUD_PASSWORD (never on argv);
# the 2FA code is relayed through a polled file (--twofa-file), so the bot can drop the code
# the user reads off their trusted device. Nothing is persisted except rclone.conf (mode 600,
# host-only — the pod sees the mounted DATA, never the config).
#
# Usage:
#   ICLOUD_PASSWORD=... icloud-connect-helper.sh <user> <apple_id> \
#       [--twofa-file /run/icloud-auth/<user>.2fa] [--no-mount] [--restart-pod] [--rclone PATH]
# Exit: 0 ok (+verified) · 2 configured but auth throttled / mount unverified · 1 failure.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NATIVE_PY="$HERE/icloud-auth-core.py"      # preferred: durable trust_token, no browser dep
BROWSER_PY="$HERE/icloud-browser-auth.py"  # fallback: cookie harvest when Apple 412s native
RCLONE="/usr/bin/rclone"
DO_MOUNT=1; RESTART_POD=0; TWOFA=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-mount) DO_MOUNT=0 ;;
    --restart-pod) RESTART_POD=1 ;;
    --twofa-file) TWOFA="$2"; shift ;;
    --rclone) RCLONE="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) POS+=("$1") ;;
  esac; shift
done
USER_NAME="${POS[0]:?usage: icloud-connect-helper.sh <user> <apple_id> [flags]}"
APPLE_ID="${POS[1]:?usage: icloud-connect-helper.sh <user> <apple_id> [flags]}"
[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }
[ -n "${ICLOUD_PASSWORD:-}" ] || { echo "ICLOUD_PASSWORD env is required" >&2; exit 1; }
id "$USER_NAME" >/dev/null 2>&1 || { echo "no such user: $USER_NAME" >&2; exit 1; }
[ -n "$TWOFA" ] || TWOFA="/run/icloud-auth/${USER_NAME}.2fa"
install -d -m 0710 /run/icloud-auth 2>/dev/null || true

echo "== icloud-connect: 1/3 authenticate =="
# Try the NATIVE rclone flow first — proven 2026-06-18 to mint a durable ~30-day trust_token
# with the regular Apple ID password. Fall back to the browser-cookie harvest only if Apple
# 412s the native verify. Each attempt may push its own 2FA code, so clear the relay between
# them (a stale code from a failed attempt would be re-consumed).
AUTH_RC=1
if [ -f "$NATIVE_PY" ]; then
  echo "-- 1a: native rclone iclouddrive flow (durable trust_token) --"
  : > "$TWOFA" 2>/dev/null || true
  set +e
  ICLOUD_PASSWORD="$ICLOUD_PASSWORD" python3 "$NATIVE_PY" "$USER_NAME" "$APPLE_ID" \
      --twofa-file "$TWOFA" --timeout 600 --rclone "$RCLONE"
  AUTH_RC=$?
  set -e
else
  echo "icloud-connect: WARN native driver $NATIVE_PY missing — going straight to browser fallback." >&2
fi

if [ "$AUTH_RC" != "0" ]; then
  echo "-- 1b: native rc=$AUTH_RC → fallback to browser-cookie harvest --"
  if [ ! -f "$BROWSER_PY" ]; then
    echo "icloud-connect: AUTH FAILED — native rc=$AUTH_RC and no browser fallback ($BROWSER_PY)." >&2
    exit 1
  fi
  : > "$TWOFA" 2>/dev/null || true
  set +e
  ICLOUD_PASSWORD="$ICLOUD_PASSWORD" python3 "$BROWSER_PY" "$USER_NAME" "$APPLE_ID" \
      --twofa-file "$TWOFA" --timeout 360 --rclone "$RCLONE"
  AUTH_RC=$?
  set -e
fi

# rc 0 = remote verified; rc 2 = config written but Apple throttled the verify (still usable).
if [ "$AUTH_RC" != "0" ] && [ "$AUTH_RC" != "2" ]; then
  echo "icloud-connect: AUTH FAILED (rc=$AUTH_RC) — not touching the mount." >&2
  exit 1
fi

if [ "$DO_MOUNT" != "1" ]; then
  echo "icloud-connect: --no-mount set; rclone.conf written, skipping mount."
  exit "$AUTH_RC"
fi

echo "== icloud-connect: 2/3 enable the host mount =="
if [ -f "/etc/systemd/system/rclone-${USER_NAME}-mount.service" ]; then
  echo "icloud-connect: legacy static unit rclone-${USER_NAME}-mount.service exists — manage that one." >&2
  exit 1
fi
mkdir -p /var/log/icloud-rclone
systemctl enable --now "rclone-icloud-mount@${USER_NAME}.service"
sleep 2
if mountpoint -q "/home/${USER_NAME}/icloud"; then
  echo "icloud-connect: mount active at /home/${USER_NAME}/icloud"
else
  echo "icloud-connect: WARN mount unit started but /home/${USER_NAME}/icloud is not a mountpoint yet." >&2
fi

echo "== icloud-connect: 3/3 pod propagation =="
if [ "$RESTART_POD" = "1" ]; then
  # graceful-restart-pod-bot waits for idle (won't interrupt mid-task), then restarts the
  # pod; claude-pod-run then adds the :rslave bind because ~/icloud is now a mountpoint.
  if command -v graceful-restart-pod-bot >/dev/null 2>&1; then
    echo "icloud-connect: graceful-restarting pod for $USER_NAME (picks up the :rslave bind) ..."
    graceful-restart-pod-bot "$USER_NAME"
  else
    echo "icloud-connect: graceful-restart-pod-bot not found — restart claude-pod@${USER_NAME} manually." >&2
  fi
else
  echo "icloud-connect: mount is live on the host. The tenant pod will see ~/icloud after its"
  echo "                next (graceful) restart — claude-pod-run binds it :rslave at start."
fi

echo "icloud-connect: DONE for $USER_NAME (auth rc=$AUTH_RC)."
exit "$AUTH_RC"
