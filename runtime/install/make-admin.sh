#!/usr/bin/env bash
# make-admin.sh <user> — grant a tenant Model-B admin (M7.5). The assistant keeps
# running in its pod but gains a controlled host-root channel via `host-sudo`:
#   host user gets NOPASSWD sudo + a real shell; an ed25519 key is generated whose
#   PRIVATE half lives in the pod (~/.ssh/host-admin, mounted) and whose PUBLIC half
#   is added to the host user's authorized_keys PINNED (forced-command) to
#   host-sudo-broker. The broker classifies: normal -> sudo+audit; destructive ->
#   (phase 1) blocked / (phase 2) Telegram HITL.
# Idempotent. Run as root on the host.   Rollback: unmake-admin.sh <user>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
U="${1:?usage: make-admin.sh <user>}"
RT="$ROOT/runtime"
BROKER=/usr/local/sbin/host-sudo-broker
SSH_DIR="/home/$U/.ssh"
KEY="$SSH_DIR/host-admin"
AUTHK="$SSH_DIR/authorized_keys"
SUDOERS="/etc/sudoers.d/$U"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "no such user: $U"; exit 1; }
log(){ printf '\n== %s ==\n' "$*"; }

log "1) install host-sudo-broker on the host"
install -m 0755 "$RT/install/host-sudo-broker" "$BROKER"

log "2) NOPASSWD sudo + login shell for $U"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$U" > "$SUDOERS"; chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null || { rm -f "$SUDOERS"; echo "sudoers validate FAILED"; exit 1; }
# A forced-command still needs a working login shell; tenants default to nologin
# (that's what keeps non-admin pods from using the bridge even if they reach :22).
usermod -s /bin/bash "$U"
id -nG "$U" | grep -qw audit || usermod -aG audit "$U" 2>/dev/null || true  # broker writes WORM socket

log "3) ssh bridge key (pod private half + host authorized_keys forced-command)"
install -d -m 700 -o "$U" -g "$U" "$SSH_DIR"
[ -f "$KEY" ] || runuser -u "$U" -- ssh-keygen -t ed25519 -N '' -f "$KEY" -C "host-admin-$U" >/dev/null
SUBNET="$(podman network inspect cl-net 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[0]["subnets"][0]["subnet"])' 2>/dev/null || true)"
PUB="$(cat "$KEY.pub")"
# authorized_keys grammar: options are comma-joined, then ONE SPACE, then the key.
# (A comma before the key makes sshd parse "ssh-ed25519" as another option and the
#  bare blob as the key type -> "key is not allowed". Cost us a long debug session.)
OPTS="command=\"$BROKER\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty"
[ -n "$SUBNET" ] && OPTS="$OPTS,from=\"$SUBNET\""
LINE="$OPTS $PUB"
touch "$AUTHK"; chown "$U:$U" "$AUTHK"; chmod 600 "$AUTHK"
grep -qF "$PUB" "$AUTHK" || printf '%s\n' "$LINE" >> "$AUTHK"

log "4) allow pod subnet -> host :22 (scoped; ssh auth + nologin still gate non-admins)"
if [ -n "$SUBNET" ] && nft list table inet cl_egress >/dev/null 2>&1; then
  nft list chain inet cl_egress input 2>/dev/null | grep -q 'dport 22' \
    || nft insert rule inet cl_egress input index 0 ip saddr "$SUBNET" tcp dport 22 accept
  echo "  (also add this line to runtime/nftables/cl-egress.nft.tmpl for persistence — see M7.5)"
else
  echo "  WARN: cl_egress table not loaded — add the :22 input rule when egress is set"
fi

log "5) relax cross-tenant shellfirm guard (admin may read/list other homes via host-sudo)"
# An admin bot must be able to read/write tenants' home dirs to moderate them.
# Other homes aren't mounted in the pod, so this access flows ONLY through the
# audited host-sudo broker. We neutralize exactly two pod-side rules
# (read_other_bot_home + list_root_home). Secret-file guards (.ssh keys,
# */credentials, vault, /etc/shadow) and destructive rules stay live for admins.
# Reversible: unmake-admin.sh runs the same helper with `restore`.
SFPOL="/home/$U/work/.shellfirm.yaml"
if [ -f "$SFPOL" ]; then
  cp -a "$SFPOL" "$SFPOL.preadmin" 2>/dev/null || true
  python3 "$RT/install/admin-shellfirm-relax.py" "$SFPOL" relax | sed 's/^/  /'
else
  echo "  WARN: $SFPOL absent — relax skipped (tenant gets the default policy on next boot)"
fi

log "6) make the admin capability self-documenting in the tenant's CLAUDE.md"
# A fresh, zero-context session only knows what loads unconditionally at start.
# CLAUDE.md is injected in full every session, so this is how a brand-new session
# learns it has host-root. Marker-delimited + idempotent; unmake-admin strips it.
# The managed tenant guide lives at ~/.claude/CLAUDE.md (provision-tenant writes it
# there; it is the file Claude loads unconditionally). For an --role admin tenant,
# provision-tenant ALREADY appends host-admin.md.snippet inside its MANAGED markers,
# so this step is a no-op then — detect that ("## Host admin capability") instead of
# warning about a legacy ~/work/CLAUDE.md path that the current layout never creates.
CLAUDEMD="/home/$U/.claude/CLAUDE.md"
ADMARK="<!-- BEGIN ADMIN-CAPABILITY (managed by make-admin.sh) -->"
if [ ! -f "$CLAUDEMD" ]; then
  echo "  WARN: $CLAUDEMD absent — awareness block skipped"
elif grep -qF "## Host admin capability" "$CLAUDEMD"; then
  echo "  CLAUDE.md already documents the admin capability (provision-tenant managed block) — skip"
elif grep -qF "$ADMARK" "$CLAUDEMD"; then
  echo "  CLAUDE.md already documents the admin capability — skip"
else
  cat >> "$CLAUDEMD" <<'ADMINEOF'

<!-- BEGIN ADMIN-CAPABILITY (managed by make-admin.sh) -->
## Host admin capability (you are an admin bot)

You have **root on the host** through a controlled SSH bridge. Run a privileged
host command with:

    host-sudo <command...>

- It connects over an SSH key pinned to a forced-command broker; the command runs
  as **root on the host** and is **WORM-audited**. Your pod itself stays unprivileged.
- **Normal** commands run immediately. **Destructive** ones (`rm -rf`, `mkfs`, `dd`,
  `reboot`/`shutdown`, `authorized_keys`/`sudoers` edits, …) are **blocked** in
  phase 1 (Telegram approval comes in phase 2). Don't try to route around the block.
- As an admin you MAY **read and write other tenants' home dirs** (`/home/<user>/…`)
  to moderate and support them — but only via `host-sudo` (other homes aren't mounted
  in your pod, so every such access goes through the audited broker). Reading raw
  **secret files** (ssh keys, `*/credentials`, the OneCLI vault, `/etc/shadow`) stays
  blocked even for you — secrets live in the vault, not in files you read.
- Invoke any script through the broker by its **executable path**, not `sudo bash …`
  — the pod guard blocks `sudo`+shell as privilege escalation.
<!-- END ADMIN-CAPABILITY (managed by make-admin.sh) -->
ADMINEOF
  chown "$U:$U" "$CLAUDEMD" 2>/dev/null || true
  echo "  appended admin-capability block to $CLAUDEMD"
fi

log "7) is_admin=true in control-plane"
podman exec -i cp-postgres psql -U cplane -d control_plane -v ON_ERROR_STOP=1 \
  -c "update users set is_admin=true where os_username='$U';" 2>&1 | sed 's/^/  /' || echo "  (cp DB update skipped)"

cat <<EOF

make-admin DONE for $U.
Next: restart the pod so it mounts the new ~/.ssh key + has the host-sudo helper:
  systemctl restart claude-pod@$U
Then from the assistant:  host-sudo whoami   (expect: root)   and a destructive cmd
should be REFUSED (phase 1). Rollback: bash $RT/install/unmake-admin.sh $U
EOF
