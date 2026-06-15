#!/usr/bin/env bash
# unmake-admin.sh <user> — revoke Model-B admin granted by make-admin.sh.
# Removes NOPASSWD sudo, restores nologin shell, strips the bridge key line from
# authorized_keys, deletes the pod private key, clears is_admin. Leaves the host
# broker binary in place (shared, harmless). Idempotent. Run as root.
set -uo pipefail
U="${1:?usage: unmake-admin.sh <user>}"
SSH_DIR="/home/$U/.ssh"
KEY="$SSH_DIR/host-admin"
AUTHK="$SSH_DIR/authorized_keys"
SUDOERS="/etc/sudoers.d/$U"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
log(){ printf '\n== %s ==\n' "$*"; }

log "1) remove NOPASSWD sudo + restore nologin shell"
rm -f "$SUDOERS"
usermod -s /usr/sbin/nologin "$U" 2>/dev/null || true

log "2) strip bridge key from authorized_keys + delete pod key"
if [ -f "$KEY.pub" ] && [ -f "$AUTHK" ]; then
  PUB="$(cat "$KEY.pub" 2>/dev/null | awk '{print $2}')"
  [ -n "$PUB" ] && grep -v -F "$PUB" "$AUTHK" > "$AUTHK.tmp" 2>/dev/null && mv "$AUTHK.tmp" "$AUTHK" && chown "$U:$U" "$AUTHK" && chmod 600 "$AUTHK"
fi
rm -f "$KEY" "$KEY.pub"

log "3) is_admin=false in control-plane"
podman exec -i cp-postgres psql -U cplane -d control_plane \
  -c "update users set is_admin=false where os_username='$U';" 2>&1 | sed 's/^/  /' || echo "  (cp DB update skipped)"

log "4) NOTE: the pod->host:22 nft rule is shared (left in place). Remove manually if NO admins remain:"
echo "   nft -a list chain inet cl_egress input   # find the 'dport 22 accept' handle, then:"
echo "   nft delete rule inet cl_egress input handle <H>"

echo "unmake-admin DONE for $U. Restart claude-pod@$U to drop the (now-absent) key."
